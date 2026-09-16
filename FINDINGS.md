# Self-hosted Neon on Kubernetes — verified findings

Notes taken while standing the lab up, for the blog post. Everything here was observed on
the running lab, not read from documentation. Figures are exact.

## Lab topology

- 3 × Linode `g6-standard-4` (4 vCPU, 8 GB, 160 GB), region `eu-central`, Ubuntu 24.04
- k3s `v1.36.4+k3s1`, nodes `neon-lab-1/2/3`, all Ready, private-network interconnect
- CloudNativePG v1.30.0 → `storage-controller-pg` (the storage controller's own Postgres)
- MinIO as the S3 backend, bucket `neon`
- `molnett/neon-operator` at commit `8f516af`, **built from source** (see below)
- Storage layer: 1 pageserver, 3 safekeepers, storage broker, storage controller
- Per branch: one compute Deployment, `<branch>-compute-node`

## Blockers hit, and what they actually were

### 1. The published operator image does not match the published manifests

`quay.io/molnett/neon-operator:latest` was built 2025-10-12; `config/default` at HEAD passes
`--controlplane-bind-address=:8082`. The older binary rejects it:

```
flag provided but not defined: -controlplane-bind-address
```

The pod CrashLoopBackOffs. Dropping the flag is **not** a valid workaround, because the
controlplane endpoints are load-bearing:

- `specs/storagecontroller/deployment.go:54` hardcodes `--control-plane-url http://neon-controlplane:8081`
- `specs/compute/deployment.go:68` gives every compute `-p http://neon-controlplane.neon:8081`
- the `neon-controlplane` Service maps 8081 → targetPort `controlplane` = containerPort 8082

Without it the cluster comes up looking healthy and then never attaches a tenant. Fix: build
`Dockerfile.operator` (Go 1.24, distroless) and import into every node's containerd —
k3s does not read the Docker image store:

```
docker save neon-operator:lab -o img.tar     # 35 MB
k3s ctr -n k8s.io images import img.tar      # on each node
```
Then set the image and `imagePullPolicy: IfNotPresent`.

### 2. The repo's `yaml/` directory is legacy and will not work

`yaml/cluster.yaml` and friends declare `kind: NeonCluster`, `apiVersion: oltp.molnett.org/v1`,
snake_case fields (`num_pageservers`, `storage_controller_database_url`), and pin the untagged
`molnett/neon-operator`. The CRDs that actually install are
`neon.oltp.molnett.org/v1alpha1`, `kind: Cluster`, camelCase. Use `config/` + `api/v1alpha1`.

### 3. The Cluster controller does not create pageservers or safekeepers

It reconciles **only** the storage controller and the storage broker — `updateStatus` checks
exactly those two Deployments. `Pageserver` and `Safekeeper` CRs are yours to create, one per
instance. Consequently `Cluster.spec.numSafekeepers` is **required but inert**: it is read
nowhere outside `test/fixtures`.

### 4. Two broken kubebuilder markers make "defaulted" fields required

- `api/v1alpha1/safekeeper_types.go:29` — `// kubebuilder:default:=10Gi` is missing its leading
  `+`, so it never reached the CRD. `storageConfig.size` is in `required` with no default, and a
  CR without it is rejected.
- `api/v1alpha1/branch_types.go:31-32` — same bug for `pgVersion` (`Enum` and `default:=17`), so
  `pgVersion` is effectively required on every Branch.

`Project.tenantId` and `Branch.timelineID`, by contrast, are genuinely optional — the operator
generates them (`utils/ids.go`) and patches them back into the spec.

### 5. Safekeeper count and naming are hardcoded in the compute spec

`specs/compute/spec.go:318-322` builds the safekeeper list as `make([]string, 3)` — comment
"always 3" — formatted `postgresql://postgres:@%s-safekeeper-%d.neon:5454`, and line 616 builds
the `neon.safekeepers` GUC the same way. So:

- there must be exactly **3** safekeepers,
- named `<cluster>-safekeeper-{0,1,2}`, in namespace **`neon`**.

Related: the storage controller's safekeeper registry stays empty
(`Heartbeat round complete for 0 safekeepers`) because nothing registers them. This is
cosmetic for the data path — computes find safekeepers by DNS convention, not via storcon.
Pageservers *do* self-register, via `POST /upcall/v1/re-attach`.

### 6. A benign startup race produces HTTP 500s

On first branch creation, `/notify-attach` fails for ~25 s:

```
Failed to find tenant deployments: no deployment available with the tenantID <id>
failed to call /configure for service <branch>-admin: dial ... connection refused
```

The Project attaches the tenant before the Branch creates the compute, so storcon notifies
before there is anything to notify. Its retries heal it; the final request is a 200. Expect
the 500s, do not debug them.

## Secrets the CRs expect

- `bucketCredentialsSecret` → keys `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`,
  `BUCKET_NAME`, `AWS_ENDPOINT_URL`
- `storageControllerDatabaseSecret` → `{name, key}`, injected as `DATABASE_URL`; CNPG's
  app secret `uri` key fits directly
- The storage controller logs `ignoring db connection TLS validation error:
  InvalidCertificate(UnknownIssuer)` against CNPG's self-signed cert, and proceeds

## Verified working

- **PostgreSQL 17.5**, extensions `neon 1.6`, `plpgsql 1.0`, **`vector 0.8.0`**
- `show neon.safekeepers` → all three; `neon.tenant_id` / `neon.timeline_id` match the CRs
- pgvector round-trip correct: `'[1,2,3]' <-> '[3,2,1]'` = `2.8284271247461903`
- Connection: `<branch>-postgres:55433`, role `cloud_admin`, db `postgres` (no password);
  admin/configure API on `<branch>-admin:3080`
- `CREATE ROLE` / `CREATE DATABASE` out-of-band **survive a compute restart**: after
  `rollout restart`, the database, its row data, the role, and the installed extension were all
  intact — `compute_ctl`'s `DropInvalidDatabases` / `RenameAndDeleteDatabases` phases left them
  alone. (Data returned through safekeepers/pageserver, not local disk.)
- Object storage genuinely used — under `pageserver/tenants/<tenant>/`:
  `tenant-manifest`, `initdb.tar.zst`, a 22 MiB layer file, `index_part.json`

### 7. The operator sets no resource requests or limits

Every component it creates — pageserver, all three safekeepers, storage controller, storage
broker, and each compute — runs with `cpu=0 mem=0` requested. Nothing is declared, so they all
land in the `BestEffort` QoS class and are first in line for eviction under node pressure. On a
dedicated lab cluster that is survivable; on a shared cluster it is not, and it is the same
failure mode we fixed on our own clusters by raising requests. Patch the StatefulSets/Deployments
after creation, or expect pageserver and safekeeper pods to be evicted before anything else.

## What Neon costs next to CloudNativePG

To serve one database on this cluster:

| | CloudNativePG | Self-hosted Neon |
|---|---|---|
| Pods | 1 operator + 1 Postgres | operator, storage controller, storage broker, pageserver, 3 × safekeeper, 1 compute per branch |
| CRDs | 11 | 5 |
| Object storage | optional (backups) | **required** (pageserver layers) |
| Extra Postgres | none | **one, for the storage controller** |

The last row is the honest headline: self-hosted Neon does not replace CloudNativePG — it needs
a conventional Postgres (we used CNPG) to store the storage controller's own state. You take on
CNPG *plus* MinIO *plus* eight Neon components to get branching and scale-to-zero.

## Odoo acceptance test — image access gotcha

Not a Neon issue, but it cost a cycle: `registry.gitlab.com/ordomatics/helm/odoo` is private,
and **every** cluster `gitlab-registry` secret is a deploy token scoped to a single client
project (`clients/<slug>`), plus one CI job token. No namespace pulls `helm/odoo` at all — all
Odoo deployments pull per-client images. A registry secret is not host-wide.

Also note `docker manifest inspect` reports success using cached credentials in
`~/.docker/config.json`; check visibility with an empty `DOCKER_CONFIG` before concluding an
image is public.

The module set is read from `/tmp/modules.cfg` **baked into the image**, which is not the same as
`odoo/modules.cfg` in the repo working tree — the image is the pinned `:latest` build and predates
recent repo additions. The image installs `base web contacts product account mail queue_job
fastapi endpoint_route_handler`, the full LLM stack (`llm`, `llm_store`, `llm_tool`,
`llm_generate`, `llm_transcribe*`, `llm_assistant`, `llm_mcp_*`, provider modules incl.
`llm_fal_ai`), `fs_storage`/`fs_attachment*`, the payment and WhatsApp modules, and `ordomatics`.
The repo copy additionally lists `phone_validation`, `dms`, `sip_voip`, `asterisk`, `whatsapp_sip`,
`telnyx_base`, `sms_telnyx`, `backstage`, `saas`, `platform`. Good for this test either way: the
LLM modules are the ones that need pgvector.

## Odoo writing to the self-hosted compute — measured

Odoo connected over the lab's non-standard shape (`:55433`, `sslmode=disable`) with no special
handling: `Database ready` → `Fresh database — seeding with base module`. Image pull took 55.8 s.

Storage progression during the schema build, i.e. the WAL path working end to end:

| | baseline | during build |
|---|---|---|
| `last_record_lsn` | `0/231BF10` | `0/33D3AB8` |
| `remote_consistent_lsn` | `0/14E8F98` | `0/231C908` |
| logical size | 31,178,752 | 43,761,664 |
| tables in `public` | 0 | 104 and rising |

`remote_consistent_lsn` advancing is the part that matters: the pageserver is durably absorbing
WAL into object storage, not merely buffering it. All three safekeepers logged zero
errors/warnings under the write load.

## Acceptance test — PASSED

Our real Odoo image, serving entirely off the self-hosted Neon compute:

- `odoo-init` Job `Complete` in 31m → **526 tables, 105 modules installed**
- `/web/health` → `200 {"status": "pass"}` on localhost **and** through the cluster Service
- `/web/login` → `200`, 4917 bytes, real Odoo markup
- serving pod `1/1 Running`, 0 restarts

Storage after the build, from the 4-object/24 MiB baseline:

| | baseline | after init |
|---|---|---|
| `last_record_lsn` | `0/231BF10` | `0/CFD1630` |
| `remote_consistent_lsn` | `0/14E8F98` | `0/BA044A8` |
| logical / physical | 31.2 MB / 23.2 MB | 82.6 MB / 270.3 MB |
| MinIO | 4 objects, 24 MiB | 8 objects, 259 MiB |

The only errors in the whole run were `Failed to connect to Ollama` from `llm_knowledge`
embedding — no Ollama in this lab, unrelated to Neon. Everything else installed clean.

### The init timeout is a trap: use `ODOO_SETUP_TIMEOUT`

The first init pod died with **`exitCode=124`** — `timeout(1)`, not an OOM (no OOMKilled event, no
signal). `setup-odoo-modules.sh:17` reads `SETUP_TIMEOUT="${ODOO_SETUP_TIMEOUT:-900}"`, so an env
var named `SETUP_TIMEOUT` is silently ignored and each odoo invocation gets 900 s. The full
105-module init exceeds that on 4 vCPU. The Job's retry then *resumed* idempotently and finished in
340 s, so the Job reported `Complete` with `failed=1, succeeded=1`. Set `ODOO_SETUP_TIMEOUT`, and
keep `backoffLimit ≥ 1`.

## Failure tests

### 1. Kill one safekeeper — PASSED (writes continue)

Safekeepers sit one per node (`neon-lab-1/3/2`). With `safekeeper-0` deleted mid-flight:

- the write succeeded immediately (`INSERT 0 1`, exit 0) — 2 of 3 is a majority
- Odoo stayed healthy: `/web/health` → `200 {"status": "pass"}`
- the pod came back Ready with **0 restarts**, all three rows intact and ordered

### Fault injection: you must scale the operator down first

Two failed attempts before the test was valid, both worth repeating in the post because they
produce *false passes*:

1. **Deleting safekeeper pods proves nothing.** The StatefulSet recreates them in seconds (the
   image is already on the node), so the write lands after they are back. All three pods ended
   with `restarts=0` — they were new pods, not survivors.
2. **`kubectl scale sts --replicas=0` is reverted.** `specs/safekeeper/statefulset.go:49` pins
   `Replicas: ptr.To(int32(1))` and the controller reconciles continuously, so the scale is undone
   almost immediately — `kubectl wait --for=delete` times out while the pods sit `1/1 Running` and
   the StatefulSet reports `ready=1/1` again.

To hold a component down, scale `deploy/neon-controller-manager` to 0 **first**, then scale the
target StatefulSets. Restore in reverse. This applies to the pageserver too
(`specs/pageserver/statefulset.go:58` pins replicas the same way).

### Measurement pitfall

`cmd | sed` makes `$?` report *sed's* status, which is always 0. Any "exit=0" collected that way is
meaningless — capture into a variable first (`out=$(cmd); rc=$?`) before formatting. Two of this
lab's "successful" results were artefacts of exactly that mistake.

### 2. Kill two of three safekeepers — PASSED (writes block; the quorum is real)

Valid only on the third attempt, with the operator scaled to 0 and both StatefulSets confirmed at
`ready=0/0`, leaving one safekeeper Running:

- the `INSERT` **blocked**: psql printed `SET`, then nothing, until the outer `timeout 70` killed it
  → **`rc=124`**, no `INSERT 0 1`. One of three safekeepers cannot commit. The quorum is enforced.
- **`statement_timeout` does not bound this.** With `statement_timeout='25s'` set, the statement was
  still hanging at 70 s: the commit-time wait for safekeeper acks is not interruptible by
  `statement_timeout`. Any automation around Neon writes needs its own outer timeout — a
  `statement_timeout` alone will not save a stuck connection.
- after restoring the safekeepers and then the operator, writes resumed immediately and Odoo stayed
  `/web/health` 200 throughout the episode.

The read-during-quorum-loss probe was **inconclusive, not a failure**: it died with a kubectl
API-server connection reset (`read tcp ...:6443: connection reset by peer`) — the exec channel, not
Postgres. Read behaviour is covered by the pageserver test instead.

**The blocked write was not lost.** This is the best durability result of the lab: the row written
during quorum loss (`quorum truly lost`) *is present* afterwards, even though the client had already
been killed at `rc=124`. It committed once the majority returned rather than being discarded — so a
quorum stall is back-pressure, not data loss. All nine rows are intact and in order.

After two full failure cycles every pod was still `Running` with **0 restarts**, and
`remote_consistent_lsn` caught up to `0/D67BD40` against `last_record_lsn 0/D6976D8` — the
pageserver drained its backlog into object storage (10 objects, 293 MiB).

### 3. Kill the pageserver — TOTAL OUTAGE (the honest headline)

One pageserver is a hard single point of failure. Held down via the operator-first method
(`sts ready=0/0`), with **all three safekeepers healthy**:

| operation | result |
|---|---|
| read of already-written rows | **hung**, `rc=124` |
| read of a cold 20,000-row table | **hung**, `rc=124` |
| write | **hung**, `rc=124` |
| `GET /web/health` | **TimeoutError — Odoo stopped serving** |

Not "degraded but serving": a complete outage of reads, writes, and the application. Safekeeper
redundancy buys nothing here, because every page request goes to the pageserver. `statement_timeout`
again failed to bound the hang, same as the quorum case.

Recovery was clean: pageserver back Ready, `lab_failover` intact, `lab_cold` still 20,000 rows,
writes resumed, `/web/health` back to `200`.

For anyone running this in a local datacentre, this is the thing to plan for: three nodes and three
safekeepers imply resilience that the single pageserver does not actually deliver. Multiple
pageservers (the `Pageserver` CR takes an `id`, so more than one is expressible) or a fast
rebuild-from-object-storage runbook is mandatory before calling it production.

**The in-flight write was lost — unlike the quorum case.** `select count(*) ... where note like
'%PAGESERVER%'` returns **0**: the insert attempted during the outage never committed, whereas the
write blocked by safekeeper quorum loss *did* survive as row 8. So the two failures differ in kind,
and it is worth stating precisely:

| failure | in-flight write | application |
|---|---|---|
| safekeeper quorum lost (1 of 3 up) | **preserved** — commits when the majority returns | Odoo keeps serving |
| pageserver down | **lost** | Odoo down |

Recovery is driven by the pageserver's own upcall to the storage controller, *not* by the operator's
controlplane — the operator log showed **zero** controlplane requests afterwards, because it had
been restarted after the fact. The evidence is in the storage controller log:

```
POST /upcall/v1/re-attach → Node 0 re-registered with matching address
re_attach: Incremented 1 tenants' generations → 200 OK
Node 0 transition to active
```

### Durability regresses after a pageserver restart

Immediately after the pageserver returned: `last_record_lsn=0/E4BBAD8` but
**`remote_consistent_lsn=0/0`**. The generation bump means nothing is yet re-uploaded for this
timeline, so for a window the only durable copy is the safekeepers' WAL, not object storage. Worth
watching in any runbook: a second pageserver loss inside that window is a much worse event than the
first.

Observed while polling (`disk_consistent_lsn` was advancing the whole time, so the pageserver was
ingesting normally — only the *upload* had not resumed):

```
t+20s  last=0/E54B418  remote=0/0  disk=0/DFEE988
t+40s  last=0/E54D4A0  remote=0/0  disk=0/DFEE988
```

**It self-heals — the window is transient, not a standing hazard.** Re-measured later:

```
last_record_lsn   = 0/105385D8
remote_consistent = 0/10511E20   (caught up to disk_consistent_lsn)
disk_consistent   = 0/10511E20
```

MinIO went 10 → 11 objects, 293 → 346 MiB, with no upload errors in the pageserver log. Bounds only:
still `0/0` at t+40 s, fully caught up when re-checked ~7 h later — the exact recovery time was not
measured, so do not quote one. `disk_consistent_lsn` advanced throughout, so the pageserver kept
ingesting the whole time; only the upload had paused.

Unattended soak: after ~7 h idle every pod was still `Running` with **0 restarts**, all data intact
(`lab_failover`=10, `lab_cold`=20,000, 528 tables) and Odoo still answering `/web/health` `200`.

### 4. Reboot a whole node — writes survive (but this did NOT test PVC pinning)

Placement first: pageserver on `neon-lab-2`, safekeepers on `neon-lab-1/3/2`, compute on
`neon-lab-2`. Rebooted `neon-lab-3`, which hosts only `safekeeper-1` — never `neon-lab-1`, which
serves the API.

- write during the node loss **succeeded** (`INSERT 0 1`, `rc=0`) — 2 of 3 safekeepers commit
- Odoo stayed `/web/health` `200` throughout
- the node returned, `safekeeper-1-0` came back with `restarts=1`, data intact, writes resumed

**What this run did not prove.** The node was `NotReady` only briefly and was back within ~20 s —
far below the 300 s `node.kubernetes.io/unreachable` toleration — so the pod was never evicted and
never went `Pending`. A fast reboot therefore says nothing about whether a safekeeper can move to
another node. Tested separately (4b) by stopping `k3s-agent` for longer than the toleration.

Both tolerations are exactly 300 s, which is the reason:

```
node.kubernetes.io/not-ready     op=Exists effect=NoExecute seconds=300
node.kubernetes.io/unreachable   op=Exists effect=NoExecute seconds=300
```

### `local-path` pins every component to one node — provable without any outage

No fault injection needed; the PVs say it outright:

```
safekeeper-1 PV  nodeAffinity: kubernetes.io/hostname In ["neon-lab-3"]
pageserver-0 PV  nodeAffinity: kubernetes.io/hostname In ["neon-lab-2"]
storageclass     rancher.io/local-path, WaitForFirstConsumer, reclaimPolicy=Delete
data             /var/lib/rancher/k3s/storage/<pvc>_neon_<name>  (that node's own disk)
```

So a pod whose node is gone **cannot** be scheduled elsewhere — its volume only exists on that
host. The consequences are asymmetric, and this is the part that matters for a three-VM deployment
in a local datacentre:

- **losing a safekeeper's node** is survivable — the remaining 2 of 3 still form a majority, so
  writes continue (demonstrated above), but you are one node from a write stall until it returns
- **losing the pageserver's node** is a total outage (test 3), and `local-path` means it cannot be
  rescheduled onto a healthy node — recovery waits for that specific machine

And `reclaimPolicy=Delete` means "just recreate the PVC" is not an escape hatch: deleting it
discards the local data. For anything beyond a lab, use replicated storage (Longhorn, Ceph/Rook) or
run multiple pageservers — otherwise the three-node topology buys less resilience than it appears to.

### 4b. Node down longer than the toleration — the pod is never replaced

Stopped `k3s-agent` on `neon-lab-3` (reversible, no Linode API needed) and held it down ~7 minutes:

```
t+80s    node=NotReady   pod=Running
t+340s   node=NotReady   pod=Running        (still tolerating)
t+360s   node=NotReady   pod=Terminating    (eviction fired, ~300s after NotReady)
t+420s   node=NotReady   pod=Terminating    (still stuck)
```

**The pod never reached `Pending`** — it stuck in `Terminating` for the rest of the outage. That is
the StatefulSet-on-unreachable-node case: the API server cannot confirm the original pod is gone, so
no replacement is created at all. Worse than "cannot schedule elsewhere": nothing is even attempted.
Freeing it needs a force-delete or node removal. The pinning evidence therefore remains the static
PV `nodeAffinity` above, not a `FailedScheduling` event.

Throughout the full outage: writes kept committing (`INSERT 0 1`, `rc=0`) on the remaining 2 of 3
safekeepers, and Odoo stayed `/web/health` `200`.

**Recovery is automatic, but not instant.** After `k3s-agent` restarted, the node was `Ready` in
~20 s while `safekeeper-1-0` was still `ready=0/1 Completed restarts=1` — the container had exited
during the stuck termination. Left alone it resolved itself: the StatefulSet replaced the pod once
the node was reachable again, and a check a few minutes later showed `1/1 Running restarts=0` with
no manual action taken. (An earlier draft of this file said it had to be recreated by hand — it did
not; the repair script found it already healthy and did nothing.)

The real lesson is the observability one: throughout the whole episode every query succeeded,
because 2 of 3 is a quorum. The application cannot tell you whether you have three safekeepers or
two. Monitor safekeeper readiness directly — a silently degraded quorum only reveals itself at the
*next* failure.

## The provisioning DDL works on a self-hosted compute

Before building any Crossplane on top of it, the exact statements the
`database-external-tf` Composition issues were run against `odoo-main-postgres.neon:55433`:

```
CREATE ROLE prov_probe LOGIN PASSWORD '...'   -> CREATE ROLE
CREATE DATABASE prov_probe OWNER prov_probe   -> CREATE DATABASE
select datname, pg_get_userbyid(datdba)       -> prov_probe|prov_probe
DROP DATABASE / DROP ROLE                     -> cleaned up
```

Two things this settles:

- **`cloud_admin` is a usable provisioning identity**: `rolcreaterole|rolcreatedb|rolsuper` all `t`.
- **Trust auth applies to LOOPBACK ONLY — corrected.** An earlier version of this note said the
  compute ignores the password outright, because `psql` inside the pod authenticated `cloud_admin`
  with the literal string `totally-wrong-password`. That is true over `127.0.0.1` and false over the
  network. A Terraform run from another pod in the same cluster got:

  ```
  pq: password authentication failed for user "cloud_admin" (28P01)
  ```

  So `pg_hba` trusts local connections and demands a real password for `host` connections. Anything
  provisioning this endpoint from outside the pod — which is every real caller — needs genuine
  credentials. The dummy-password shortcut only ever worked for a loopback probe.

## The external Composition's module works; the credential design was wrong

The Composition's Terraform module was run against `odoo-main-postgres.neon:55433` in the lab, using
HCL extracted from the committed YAML rather than retyped. Terraform resolved all three resources and
computed every one of the eight connection outputs:

```
host       = odoo-main-postgres.neon.svc.cluster.local
hostDirect = odoo-main-postgres.neon.svc.cluster.local   (falls back to host, as designed)
port       = "55433"
sslmode    = "disable"
dbname     = "byotest"
username   = "odoo"
password   = (sensitive)   uri = (sensitive)
Plan: 3 to add, 0 to change, 0 to destroy.
```

`random_password.owner` created successfully; `postgresql_role.owner` then failed on the auth error
above, so nothing was left behind (`byotest` role and database both absent afterwards, verified).

### It works: a database provisioned on self-hosted Neon

With the `provisioner` role and a non-colliding owning role, the apply **succeeded** and emitted the
full eight-key contract:

```
username   = byotest
dbname     = byotest
host       = odoo-main-postgres.neon.svc.cluster.local
hostDirect = odoo-main-postgres.neon.svc.cluster.local   (falls back to host — no pooler, as designed)
port       = "55433"
sslmode    = "disable"
password   = (32 chars, alphanumeric)
uri        = postgresql://byotest:...@odoo-main-postgres.neon.svc.cluster.local:55433/byotest?sslmode=disable
```

So the platform's provisioning logic does create a usable database on a self-hosted Neon compute.

What this proves and does not prove:

- **Proven**: the module's HCL, its variable wiring, the `hostDirect` fallback, the eight-key output
  contract, and the actual creation of a role and database on a real self-hosted Neon compute.
- **Not proven**: Crossplane's own layer — the patches from claim fields into `vars[]`/`env[]`, and the
  connection Secret it writes. Those are validated structurally (server-side dry-run, plus a
  mechanical index→key check of all eleven vars) but have never reconciled, because Crossplane is not
  installed in the lab and the platform cluster cannot reach this ClusterIP endpoint.
- **Corrected along the way**: `plan §4`'s assumption that a placeholder admin secret suffices was
  wrong (`pg_hba` requires md5 off-loopback), and the Composition cannot adopt a pre-existing owning
  role (`42710`).

### The `pg_hba` rules, which settle it

```
local {all} {all}             trust
host  {all} {all} 127.0.0.1   trust
host  {all} {all} ::1         trust
host  {all} {all} all         md5     <-- every non-loopback caller
```

`password_encryption` is `md5` (`specs/compute/spec.go:611`), which is what makes that last line work.
A loopback probe therefore proves nothing about a network caller.

### A dedicated provisioning role, not the superuser

Created on the lab compute and verified over TCP, not loopback:

```
provisioner | login=t | createrole=t | createdb=t
psql postgresql://provisioner:...@odoo-main-postgres.neon.svc.cluster.local:55433/postgres?sslmode=disable
  -> TCP auth OK as provisioner
```

Preferred over `ALTER ROLE cloud_admin PASSWORD` because `compute_ctl` rewrites roles on reconfigure:
`specs/compute/spec.go:389-396` declares `Roles` as an **exhaustive** list of one role (`postgres`)
and `Databases` as empty, and the reconfigure phases include `CreateAndAlterRoles`, `RenameRoles`,
`DropInvalidDatabases` and `RenameAndDeleteDatabases`. In practice a compute restart left the
out-of-band `odoo` role and database intact, so it is not pruning aggressively — but nothing in the
spec guarantees that, so treat any hand-made role on a self-hosted compute as re-creatable rather
than permanent.

## Working against a lossy control path

Measured, after repeatedly mistaking flakiness for breakage:

```
node1  0% packet loss, 75ms rtt   API answered 4/6   ssh 2/3
node2  100% ICMP loss but :8069 serves 200           ssh 1/3
node3  0% packet loss, 73ms rtt                      ssh 2/3
controls (1.1.1.1, Linode API, platform cluster, lab Odoo) all fine
```

So the path is roughly two-thirds reliable, not down. Three attempts at the same test failed anyway,
and every one was a scripting fault rather than infrastructure:

- **A timed-out `kubectl` was treated as data.** `get pod … | wc -l` counts an error message as `0`,
  so "unreachable" read as "absent" and a delete-then-apply raced itself. Only accept output when the
  command exits 0, and report unreachable distinctly from absent.
- **A stale pod was read as the new run.** After a failed `apply`, `get pod -l job-name=…` returns the
  *previous* pod, whose logs then look like a fresh failure. Capture the pod name from the run you
  just created, or name the Job uniquely.
- **`Job.spec.template` is immutable**, so recreating a Job requires a *completed* delete. On a lossy
  API that delete is exactly what fails. Use a unique Job name per run and never delete at all.

None of this is specific to Neon, but it is specific to driving a single-server k3s over the public
internet, which is what a lab in a remote datacentre is.

## Upstream context (checked against the repo, not assumed)

- The operator is now **`lovablelabs/neon-operator`** — "(Part of acquisition of Molnett)". The
  change of ownership is the likely reason for both the stale published image and the legacy
  `yaml/` directory.
- **The README documents no registry at all**: install is `make install` + `make deploy`, i.e. build
  from source. `quay.io/molnett/neon-operator:latest` is a leftover, not the supported path — so
  building the image is the normal route, not a workaround.
- Upstream's own stated limitations, which matter for the "why self-host Neon" argument:
  - **"Compute instances run persistently and do not scale to zero"** — scale-to-zero is *not*
    implemented. Branching is the real reason to choose this.
  - Tenant sharding is manual.
  - Day-2 operations and performance tuning "still in development"; described as functional for
    development and testing environments.
- No competing Kubernetes operator for Neon turned up in search (unrelated hits only — Neon EVM is
  a different product).

## External reachability — the actual point of self-hosting

Everything above proved the storage engine works. None of it proved the thing a self-hosted database
is *for*: being reachable from outside the cluster that runs it, by a client that has no special
network relationship with it — the whole premise of "deploy it in your own datacentre for data
sovereignty." A database only reachable from inside its own Kubernetes cluster isn't sovereign
infrastructure, it's a demo.

The compute itself cannot be exposed as-is: `pg_hba` is `trust` on loopback and, more to the point,
offers no TLS at all off it — see the credential-design section above. So the fix is the standard one,
not a self-hosted-Neon-specific one: **PgBouncer in front, terminating real TLS and real password
auth**, with the plaintext hop to the compute staying inside the cluster's private pod network. This
is architecturally identical to what managed Neon's own "pooled" endpoint does — it is not a
workaround, it is the missing production layer.

### What was built

- `edoburu/pgbouncer:v1.25.2-p0` (the `1.20.1-p2` tag guessed from memory doesn't exist — checked
  Docker Hub's tag API this time rather than repeating the earlier MinIO mistake)
- A self-signed cert (`openssl req -x509`, 825 days, SAN covering all three node IPs)
- `userlist.txt` with real md5 hashes of the compute's own working per-role passwords (not written
  here — this file is published alongside the blog post, and these are live credentials against a
  now internet-reachable database) — PgBouncer's client-facing auth and its backend auth are the
  *same* credential here, which is what makes the pass-through work with no extra plumbing
- `client_tls_sslmode = require`, `server_tls_sslmode = disable`, `pool_mode = session` (not
  transaction — this fronts a general Odoo/psql client, and transaction pooling breaks advisory
  locks, LISTEN/NOTIFY and SET in ways that surface as confusing bugs mid-demo, not at setup time)
- Exposed via the same ServiceLB `LoadBalancer` pattern already proven for Odoo (:8069) and the MinIO
  console (:9001) — confirmed live: it binds on every node's public IP via klipper's iptables DNAT

One real bug on the way: the image's own `entrypoint.sh` tries to *generate* `pgbouncer.ini` and
`userlist.txt` from `DB_*` env vars, and fails with `Permission denied` writing over the Secret-mounted
files at those same paths (Secret volumes are read-only). Fixed by overriding `command`/`args` to exec
`pgbouncer` directly against the mounted config, skipping the image's entrypoint entirely.

### Verified from this laptop, over the public internet, against the lab's public IP

```
psql "host=172.104.146.201 port=5432 dbname=odoo user=odoo sslmode=require"
  SSL Connection : true
  SSL Protocol   : TLSv1.3
  SSL Cipher     : TLS_AES_256_GCM_SHA384
  -> select count(*) from information_schema.tables where table_schema='public'
  -> 528
```

- **Wrong password → rejected**: `FATAL: password authentication failed` (real auth, not trust)
- **Plaintext attempt → rejected**: `FATAL: SSL required` (TLS is mandatory, not opportunistic)
- **Write path works**: `CREATE TABLE` / `INSERT` / `SELECT` all succeed through the external
  connection, on all three node IPs (two confirmed directly; the third timed out on the lab's own
  flaky link, not on pgbouncer — consistent with the reachability numbers measured earlier)

### Side effect: this also closes the earlier BYO-provisioning blocker

`ordomatics-test` (the platform's own clients cluster) could not reach the lab's Postgres when it was
`ClusterIP`-only — that was the stated reason the BYO-database demo through the saas UI couldn't run
end-to-end. It reaches the public PgBouncer endpoint over the same TLS+auth path with no special
network configuration:

```
kubectl -n ordomatics-test exec <pod> -- psql "host=<node-ip> port=5432 ... sslmode=require"
  -> reachable from ordomatics-test as odoo
```

So a `saas.postgres` record pointing `externalHost` at the public PgBouncer address is now a
realistic BYO-database configuration, not a hypothetical one — closing the gap the previous session
left open.

## Teardown

`neon-lab/terraform` → `terraform destroy`. Also delete `gitlab-registry-local` from the lab: it
holds a personal registry credential rather than a project-scoped deploy token. The pgbouncer
secret (private key + password hashes) should be rotated or destroyed along with the rest of the lab
— it was never meant to outlive it.
