# Three VMs for the self-hosted Neon lab: k3s + MinIO + neon-operator.
# Three because the operator's Cluster CRD requires a minimum of 3 safekeepers,
# which commit writes by Paxos majority — fewer nodes makes the quorum a fiction.
#
#   export TF_VAR_linode_token=...   (never written to disk)
#   terraform init && terraform apply
#   terraform destroy                 when the lab is finished
terraform {
  required_version = ">= 1.5"
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.13"
    }
  }
}

variable "linode_token" {
  type      = string
  sensitive = true
}

variable "region" {
  type        = string
  default     = "eu-central"
  description = "Frankfurt, matching the rest of our infrastructure. fr-par is the closest region to Dakar if latency matters."
}

variable "instance_type" {
  type        = string
  default     = "g6-standard-4"
  description = "4 vCPU, 8 GB RAM, 160 GB disk, $0.072/hr. g6-dedicated-4 is the upgrade when measuring pageserver IO."
}

variable "node_count" {
  type    = number
  default = 3
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/neon-lab.pub"
}

provider "linode" {
  token = var.linode_token
}

resource "linode_instance" "neon" {
  count  = var.node_count
  label  = "neon-lab-${count.index + 1}"
  region = var.region
  type   = var.instance_type
  image  = "linode/ubuntu24.04"

  authorized_keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]

  # k3s and the Neon components talk over the private network.
  private_ip = true

  tags = ["neon-lab"]
}

output "public_ips" {
  value = [for i in linode_instance.neon : i.ip_address]
}

output "private_ips" {
  value = [for i in linode_instance.neon : i.private_ip_address]
}

output "ssh_commands" {
  value = [for i in linode_instance.neon : "ssh -i ~/.ssh/neon-lab root@${i.ip_address}"]
}
