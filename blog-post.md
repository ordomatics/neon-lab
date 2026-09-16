# Running Neon on your own hardware: a three-node deployment, honestly measured

Neon is Postgres with storage separated from compute: the database's pages live in an object
store, write-ahead log durability is handled by a replicated quorum, and the Postgres process
itself becomes a stateless thing you can restart, scale to zero, or branch in seconds. The managed
service is excellent. But if your data has to stay in a specific country — in a national or
regional datacentre such as Diamniadio, rather than in Frankfurt or Virginia — "managed" is not on
the menu, and the question becomes whether you can run the same architecture yourself.

We did. This is what it took, what broke, and what we measured when we deliberately broke it. Our
own test was concrete: take a real Odoo ERP deployment that currently runs on managed Neon, point
it at a self-hosted cluster, and see whether it behaves the same.

Short answer: **it works, and we have the numbers to show it — but the resilience story is weaker
than the three-node topology suggests, and the operator ecosystem is early.** Details below,
including the parts that cost us hours.

---

## What you are actually signing up for

The most useful thing to understand before starting: self-hosted Neon does **not** replace a
conventional Postgres operator. It needs one.

| | CloudNativePG | Self-hosted Neon |
|---|---|---|
| Pods to serve one database | 1 operator + 1 Postgres | operator, storage controller, storage broker, pageserver, 3 × safekeeper, 1 compute per branch |
| CRDs | 11 | 5 |
| Object storage | optional (backups) | **required** — pages live there |
| A separate Postgres | no | **yes** — the storage controller stores its own state in one |

So the real comparison is not "Neon *or* CloudNativePG". It is "CloudNativePG" versus
"CloudNativePG **plus** an object store **plus** eight Neon components". You buy branching,
scale-to-zero, and fast copy-on-write clones. You pay in moving parts.

Pick self-hosted Neon if you specifically need **branching** — for example a SaaS platform giving
each tenant or each CI run its own instant database copy. If you need "Postgres that stays up and
stays in-country", CloudNativePG is dramatically simpler and you should use it.

One correction to the obvious pitch, straight from the operator's own README: **scale-to-zero is
not included.** "Compute instances run persistently and do not scale to zero", and tenant sharding
is manual. So if idle-cost savings were your reason for self-hosting Neon, that reason does not
survive contact with the current operator — the compute Deployment runs until you delete it, the
same as any other Postgres pod. Branching is the feature you are actually buying.

### The components

- **Pageserver** — stores and serves pages, uploads layer files to object storage. In the setup
  below there is exactly one, and it is the single point of failure.
- **Safekeepers** — three of them, holding the WAL and committing by Paxos majority.
- **Storage broker** — the discovery bus the others gossip over.
- **Storage controller** — places tenants, tracks generations; keeps its state in its own Postgres.
- **Compute** — a real Postgres process per branch, created on demand.
- **Operator** — reconciles all of the above from five CRDs.

---

## The lab

Three VMs, 4 vCPU / 8 GB / 160 GB each, private networking between them, Ubuntu 24.04. Three
because the operator's compute spec hardcodes exactly three safekeepers — more on that below.

On top: k3s `v1.36.4`, CloudNativePG `v1.30.0`, MinIO as the S3 endpoint, and
[`neon-operator`](https://github.com/molnett/neon-operator) — originally from Molnett, now under
`lovablelabs` following an acquisition. It is the only Kubernetes operator for Neon we could find,
and it is young; the change of ownership probably explains both of the repository oddities we hit
below (a published image that predates its own manifests, and a directory of manifests from a
previous API generation). Plan accordingly.

### k3s, with one flag that matters

```bash
# server (node 1)
curl -sfL https://get.k3s.io | sh -s - server \
  --node-name neon-lab-1 --node-ip <private-ip> \
  --advertise-address <private-ip> --tls-san <public-ip>

# agents (nodes 2 and 3)
curl -sfL https://get.k3s.io | K3S_URL=https://<node1-private-ip>:6443 \
  K3S_TOKEN=<token> sh -s - agent --node-name neon-lab-2
```

`--node-name` is not optional. Without it, on a freshly provisioned image whose hostname has not
been set, nodes register as `localhost` and the second one silently fails to join. Set real
hostnames, or pass the flag, and save yourself the reinstall we did.

---

## Blocker 1: the published operator image does not match its own manifests

This is the one that will stop you dead, so it goes first.

The operator's deployment manifest passes `--controlplane-bind-address=:8082`. The published
image, built months earlier, has never heard of that flag:

```
flag provided but not defined: -controlplane-bind-address
```

CrashLoopBackOff. Worth knowing before you go looking for a better tag: the README never points at
a registry at all — the documented install is `make install` / `make deploy`, i.e. **build it
yourself**. The published image is a leftover, not the supported path, so treat the steps below as
the normal route rather than a workaround.

The tempting fix — delete the flag — is a trap. Those control-plane endpoints are load-bearing:

- the storage controller is started with `--control-plane-url http://neon-controlplane:8081`
- every compute is started with `-p http://neon-controlplane.neon:8081`

Remove the flag and the cluster comes up looking perfectly healthy, then never attaches a tenant.
Build from source instead, and import the result into every node's containerd — k3s does not read
Docker's local image store:

```bash
docker build -f Dockerfile.operator -t neon-operator:lab .
docker save neon-operator:lab -o img.tar            # ~35 MB
# on each node:
k3s ctr -n k8s.io images import img.tar
```

Then point the Deployment at `neon-operator:lab` with `imagePullPolicy: IfNotPresent`.

Verify it is actually serving before going further — a request to the controlplane port should
return `404` (listening, no route at `/`) rather than connection refused.

## Blocker 2: half the YAML in the repository is from a previous generation

`yaml/cluster.yaml` and its siblings declare `kind: NeonCluster`, API group
`oltp.molnett.org/v1`, snake_case fields like `num_pageservers`. The CRDs that actually install are
`neon.oltp.molnett.org/v1alpha1`, `kind: Cluster`, camelCase. The legacy files will fail or, worse,
mislead you about which fields exist. Treat `config/` and `api/v1alpha1` as the only truth.

## Blocker 3: the Cluster resource does not create your storage nodes

Applying a `Cluster` gives you a storage controller and a storage broker — and nothing else. The
pageserver and the safekeepers are separate CRs that you write yourself, one per instance.

A direct consequence: `Cluster.spec.numSafekeepers` is **required by the schema and read by
nothing** outside the project's own test fixtures. Setting it to 5 does not give you five
safekeepers. It gives you the three you wrote CRs for.

## Blocker 4: fields that look defaulted are actually required

Two Go markers in the source are missing their leading `+`, so they are ordinary comments that
never reached the generated CRDs:

- `storageConfig.size` on safekeepers and pageservers — **required**, no default
- `pgVersion` on branches — **required**, no default, despite appearing to default to 17

`tenantId` and `timelineID`, by contrast, really are optional; the operator generates them and
writes them back into your spec.

## Blocker 5: exactly three safekeepers, and the names are load-bearing

The compute spec builds its safekeeper list in code, with a comment that reads "always 3", as:

```
postgresql://postgres:@<cluster>-safekeeper-<0,1,2>.neon:5454
```

So the count is fixed at three, the names must be `<cluster>-safekeeper-0/1/2`, and they must live
in the `neon` namespace. Deviate and the compute simply will not find them.

Related, and confusing when you first see it: the storage controller will keep logging
`Heartbeat round complete for 0 safekeepers`. Nothing registers safekeepers with it, because
computes discover them by DNS convention instead. Pageservers *do* self-register (via an
`/upcall/v1/re-attach` call). The empty safekeeper list is cosmetic — ignore it.

## Blocker 6: nothing has resource requests

Every component the operator creates — pageserver, safekeepers, storage controller, broker, and
each compute — runs with no CPU or memory requests at all. That puts all of them in Kubernetes'
`BestEffort` class: first to be evicted under node pressure. On a dedicated lab that is survivable.
On a shared cluster, your database storage layer is the first thing the kubelet throws overboard.
Patch requests in after creation.

## Blocker 7: expect a burst of HTTP 500s on first branch creation

For roughly 25 seconds you will see:

```
Failed to find tenant deployments: no deployment available with the tenantID <id>
failed to call /configure for service <branch>-admin: dial ... connection refused
```

The tenant is attached before the compute exists, so the storage controller notifies something
that is not there yet. Its retries resolve it and the final call returns 200. Do not debug this.

---

## Bringing it up

With the operator running, the order is: secrets → `Cluster` → pageserver and safekeepers →
`Project` → `Branch`.

The bucket secret must carry exactly these keys — the pageserver reads them by name:

```
AWS_ACCESS_KEY_ID  AWS_SECRET_ACCESS_KEY  AWS_REGION  BUCKET_NAME  AWS_ENDPOINT_URL
```

The storage controller's database secret is a `{name, key}` pair injected as `DATABASE_URL`;
CloudNativePG's generated app secret has a `uri` key that fits directly. You will see the storage
controller log `ignoring db connection TLS validation error: InvalidCertificate(UnknownIssuer)`
against CNPG's self-signed certificate, and carry on.

Then:

```yaml
apiVersion: neon.oltp.molnett.org/v1alpha1
kind: Cluster
metadata: { name: neon-lab, namespace: neon }
spec:
  defaultPGVersion: 17
  numSafekeepers: 3           # required by the schema, read by nothing
  neonImage: neondatabase/neon:8463
  bucketCredentialsSecret: { name: bucket-credentials, namespace: neon }
  storageControllerDatabaseSecret: { name: storage-controller-pg-app, key: uri }
```

…followed by one `Pageserver` (`id: 0`) and three `Safekeeper` CRs (`id: 0,1,2`), each with an
explicit `storageConfig.size`, then a `Project` (needs only `cluster`) and a `Branch` (needs
`projectID` and `pgVersion`).

A `Branch` creates a compute Deployment and two Services. Your connection target is
`<branch>-postgres:55433` — note the port — as role `cloud_admin`, database `postgres`.

What you get:

```
PostgreSQL 17.5
extensions: neon 1.6, plpgsql 1.0, vector 0.8.0
show neon.safekeepers -> all three
```

pgvector is present and correct, which matters if you are running anything with embeddings.

---

## Does it actually work? The Odoo test

Compatibility claims are cheap, so we used a real workload: our production Odoo image, pointed at
the self-hosted compute instead of managed Neon, initialising a fresh database from scratch.

It connected with no special handling and built the schema:

- **526 tables, 105 modules installed**
- `/web/health` → `200 {"status": "pass"}`, and the login page renders
- logical size 31 MB → 83 MB; object storage 4 objects/24 MiB → 8 objects/259 MiB

Only two differences from our managed-Neon configuration, both environmental rather than
behavioural: the port is `55433` instead of `5432`, and this compute serves plain TCP, so
`sslmode=disable` where managed Neon requires TLS. If you expose it beyond the cluster, put TLS in
front of it.

One trap worth knowing if you run Odoo specifically: the module installer wraps itself in
`timeout`, defaulting to 900 s, and a 105-module install exceeds that on 4 vCPU. The first attempt
died with exit code 124 — not an out-of-memory, as we first assumed. Raise the timeout, and keep a
retry available: the installer is idempotent, and the retry resumed and finished in 340 s.

---

## Breaking it on purpose

This is the part most write-ups skip. Numbers below are what we observed, including the tests that
failed to prove anything the first time.

### Kill one safekeeper — writes continue

The write committed immediately, Odoo never noticed, the pod returned with no restarts, data
intact. Two of three is a majority. As designed.

### Kill two safekeepers — writes block, and that is correct

With one safekeeper left, the `INSERT` hung and never returned. The quorum is real.

Two things we learned the hard way here:

**Naive fault injection produces false passes.** Deleting pods proves nothing — the StatefulSet
recreates them in seconds and your write lands after they are back. `kubectl scale --replicas=0`
proves nothing either: the operator pins replicas and reconciles the scale away almost instantly.
To hold a component down you must scale the **operator** to zero first, then the target. Our first
two "quorum enforced" results were artefacts of a window that never existed.

**`statement_timeout` will not save you.** With `statement_timeout='25s'` set, the statement was
still hanging at 70 seconds. The commit-time wait for safekeeper acknowledgement is not
interruptible by `statement_timeout`. Any automation talking to Neon needs its own outer timeout.

And the good news: **the blocked write was not lost.** It committed once the majority returned,
even though the client had long since been killed. A quorum stall is back-pressure, not data loss.

### Kill the pageserver — total outage

This is the headline, and it deserves to be stated plainly. With all three safekeepers healthy and
only the pageserver down:

| operation | result |
|---|---|
| read of recent rows | hung |
| read of a cold 20,000-row table | hung |
| write | hung |
| Odoo `/web/health` | timed out — the application was down |

Not degraded. Down. Safekeeper redundancy buys nothing, because every page request goes to the
pageserver. And unlike the quorum case, **the in-flight write was lost** — it never appeared after
recovery.

Recovery itself was clean: the pageserver re-registered, generations were incremented, the tenant
returned to active, and all data was intact.

One detail for your runbook: immediately after recovery, `remote_consistent_lsn` reads `0/0` while
the pageserver ingests normally. For a window, object storage is *behind* and the only durable copy
of recent writes is the safekeepers' WAL. It does catch up on its own — we confirmed it fully
caught up later — but a second pageserver loss inside that window would be a far worse event than
the first.

### Lose a node — and the storage does not follow

Rebooting a node that hosted one safekeeper was a non-event: writes continued on the remaining two,
Odoo stayed up, everything came back.

But that is not the interesting question. The interesting question is whether a component can move
to a healthy node, and with k3s' default `local-path` storage the answer is no. The volumes say so
directly:

```
safekeeper-1 PV  nodeAffinity: kubernetes.io/hostname In ["neon-lab-3"]
pageserver-0 PV  nodeAffinity: kubernetes.io/hostname In ["neon-lab-2"]
storageclass     rancher.io/local-path, WaitForFirstConsumer, reclaimPolicy=Delete
```

Each volume exists on exactly one machine's disk. A pod whose node is gone cannot be scheduled
anywhere else.

We checked what actually happens by stopping the kubelet on one node and leaving it down for seven
minutes, well past Kubernetes' five-minute eviction tolerance:

```
t+80s    node NotReady   pod Running
t+360s   node NotReady   pod Terminating     <- eviction fires
t+420s   node NotReady   pod Terminating     <- still stuck
```

The pod never reaches `Pending`. It sticks in `Terminating` for as long as the node is unreachable,
because Kubernetes cannot confirm the original pod is gone — and a StatefulSet will not create a
replacement while that is true. So the failure mode is not "the replacement can't find its volume".
It is that **no replacement is attempted at all**, and clearing it takes a force-delete or removing
the node from the cluster.

Throughout that outage, writes kept committing on the remaining two safekeepers and the application
stayed up. When the node came back it recovered on its own, though not instantly: the node went
`Ready` in about twenty seconds while the safekeeper was still in a non-ready state, and the
StatefulSet replaced the pod a couple of minutes later without intervention.

The lesson there is about observability rather than repair. For that entire window — node down,
eviction, stuck termination, recovery — every query succeeded, because two of three is still a
quorum. Your application cannot tell you whether it is running on three safekeepers or two. Monitor
safekeeper readiness directly; a degraded quorum stays invisible until the *next* failure, which is
when you find out you had two copies instead of three.

So:

- **a safekeeper's node dying** is survivable — 2 of 3 still commits — but you are one node away
  from a write stall until that specific machine returns
- **the pageserver's node dying** is a total outage that cannot be resolved by rescheduling; you
  wait for that machine

`reclaimPolicy=Delete` closes the obvious escape hatch too: deleting and recreating the PVC throws
the local data away.

For anything past a lab, this is the first thing to change: replicated storage (Longhorn, Ceph via
Rook) or a second pageserver — the `Pageserver` CR takes an `id`, so more than one is expressible.
Three nodes and three safekeepers imply a resilience that a single pageserver on local disk does
not deliver.

---

## Reaching it from outside — the part that actually matters

Everything above proves the storage engine works. It does not prove the thing you are actually
buying by self-hosting: a database reachable from outside the cluster that runs it, by an
application that has no special network relationship with it. That is the entire premise of "run it
yourself, in-country" — a Postgres only reachable from inside its own Kubernetes cluster is not
sovereign infrastructure, it is a demo that happens to be technically impressive.

The compute cannot be exposed as it stands. It is `trust` auth on loopback and offers no TLS at all
off it — fine for pods that share its cluster, disqualifying for anything on the public internet.
The fix is not specific to self-hosted Neon: put **PgBouncer in front, terminating real TLS and real
password authentication**, and keep the plaintext hop from PgBouncer to the compute inside the
cluster's private pod network. This is not a workaround. It is architecturally the same thing
managed Neon's own "pooled" endpoint already does — you are building the piece hosted Neon gives you
for free, not inventing something extra.

Concretely: `edoburu/pgbouncer`, a self-signed certificate, and a `userlist.txt` carrying md5 hashes
of the same passwords that already work on the compute — so PgBouncer's client-facing auth and its
backend auth are the same credential, no extra plumbing required. `client_tls_sslmode = require`
forces TLS; `server_tls_sslmode = disable` is fine because that hop never leaves the cluster.
`pool_mode = session`, not transaction — transaction pooling breaks advisory locks, `LISTEN`/`NOTIFY`
and `SET` in ways that show up as confusing application bugs mid-demo rather than errors at setup.
Exposed through the same node-IP `LoadBalancer` pattern already used for Odoo and MinIO's console.

Then, from a laptop with no relationship to the cluster beyond its public IP:

```
psql "host=<node-ip> port=5432 dbname=odoo user=odoo sslmode=require"
  SSL Connection : true
  SSL Protocol   : TLSv1.3
  SSL Cipher     : TLS_AES_256_GCM_SHA384
  -> 528 tables
```

A wrong password gets `FATAL: password authentication failed`. A plaintext attempt gets `FATAL: SSL
required`. Both are what you want to see — refusal, not a silent downgrade. Writes succeed through
the same connection.

This is also the detail that turns "self-hosted Neon" from an interesting exercise into something a
platform can actually provision *for* a client: once the endpoint is reachable like this, standing up
a client's Odoo against their own self-hosted Neon is exactly as easy as standing it up against
managed Neon — same coordinates, same TLS, same password auth, just a different `host`. The
distinction that mattered all the way through this exercise — "can a database that lives on someone
else's server, in someone else's building, actually serve a real application over the network it
will really be used on" — is the one every other section in this post assumed and this one is the
one that tests.

---

## So should you run this?

**If you need data residency and ordinary Postgres reliability:** use CloudNativePG. One operator,
one CRD family, replicas and backups that work today, far less to understand. This is the right
answer for most teams, including most of the ones asking about sovereignty.

**If you specifically need Neon's branching** — per-tenant instant database copies, throwaway
branches per CI run — then self-hosting is viable, with conditions (and note again that
scale-to-zero, the other headline reason people want Neon, is not implemented in this operator):

1. Build the operator from source and pin your own image.
2. Do not run a single pageserver in production. It is the single point of failure, and we measured
   it taking the whole application down.
3. Do not use `local-path`. Use replicated storage.
4. Add resource requests to every component, or the cluster will evict your storage layer first.
5. Put PgBouncer in front of the compute before anything outside the cluster touches it — real TLS,
   real password auth. The compute's own auth is loopback-only trust; treat that as internal
   plumbing, never as the edge.
6. Budget real time for the operator's rough edges — the ones above cost us most of a day.

For a datacentre in Dakar or Abidjan, the architecture holds up: it ran on three ordinary VMs, the
storage layer behaved correctly under deliberate failure, our production ERP could not tell the
difference, every byte stayed where we put it, and — the part that actually matters for "in-country
for sovereignty" rather than "in-country as a curiosity" — it answered a real TLS-encrypted, password-
authenticated connection from a machine on the other side of the internet that had never heard of the
cluster before. The honest caveat is that the operator around it is young, and you will be reading Go
source to answer questions the documentation does not.

That is a real cost. It is also, for data that legally cannot leave the country, sometimes the only
option — and it is a cost you can plan for, which is why we wrote down the numbers rather than the
impressions.
