# ════════════════════════════════════════════════════════════════════════════
# Module: eks
# This is the EPHEMERAL part — destroy after each session to save cost.
# Command: terraform destroy -target=module.eks
# ════════════════════════════════════════════════════════════════════════════

variable "cluster_name"    { type = string }
variable "aws_region"      { type = string }
variable "vpc_id"          { type = string }
variable "private_subnets" { type = list(string) }
variable "node_type" {
  type    = string
  default = "t3.medium"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.29"

  vpc_id                         = var.vpc_id
  subnet_ids                     = var.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    general = {
      instance_types = [var.node_type]
      capacity_type  = "SPOT"     # Spot instances — ~70% cheaper, fine for learning
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_arn"      { value = module.eks.cluster_arn }
