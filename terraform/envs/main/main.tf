terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — create the S3 bucket manually once before running terraform init
  # Command: aws s3 mb s3://cicd-demo-tfstate-YOUR-ACCOUNT-ID --region eu-west-1
  backend "s3" {
    bucket         = "cicd-demo-tfstate-344887510222"
    key            = "cicd-demo/terraform.tfstate"
    region         = "eu-west-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "cicd-demo"
      ManagedBy = "terraform"
    }
  }
}

# ── Data sources ──────────────────────────────────────────────────────────────
data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}

# ── Shared VPC ────────────────────────────────────────────────────────────────
# One VPC used by both Jenkins EC2 and EKS cluster
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "cicd-demo-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.11.0/24", "10.0.12.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # One NAT saves cost — fine for learning
  enable_dns_hostnames = true

  # Tags required by EKS to discover subnets for load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# ── Module: Jenkins EC2 (persistent — never destroyed) ───────────────────────
module "jenkins" {
  source = "../../modules/jenkins"

  vpc_id            = module.vpc.vpc_id
  subnet_id         = module.vpc.public_subnets[0]
  instance_type     = var.jenkins_instance_type
  key_name          = var.key_pair_name
  aws_region        = var.aws_region
  ecr_registry      = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  cluster_name      = var.cluster_name
  account_id        = data.aws_caller_identity.current.account_id
}

# ── Module: ECR repository (persistent — costs pennies) ──────────────────────
module "ecr" {
  source   = "../../modules/ecr"
  app_name = var.app_name
}

# ── Module: EKS cluster (ephemeral — destroy after each session) ─────────────
module "eks" {
  source = "../../modules/eks"

  cluster_name    = var.cluster_name
  aws_region      = var.aws_region
  vpc_id          = module.vpc.vpc_id
  private_subnets = module.vpc.private_subnets
  node_type       = var.node_instance_type
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "jenkins_public_ip" {
  description = "Jenkins EC2 Elastic IP — use this for the GitHub webhook and browser access"
  value       = module.jenkins.elastic_ip
}

output "jenkins_url" {
  description = "Jenkins web UI URL"
  value       = "http://${module.jenkins.elastic_ip}:8080"
}

output "ecr_repository_url" {
  description = "ECR repository URL — paste into Jenkins ECR_REGISTRY credential"
  value       = module.ecr.repository_url
}

output "ecr_registry" {
  description = "ECR registry URL (account.dkr.ecr.region.amazonaws.com)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "eks_cluster_name" {
  description = "EKS cluster name — used in aws eks update-kubeconfig"
  value       = module.eks.cluster_name
}

output "ssh_command" {
  description = "Command to SSH into the Jenkins EC2"
  value       = "ssh -i ${var.key_pair_name}.pem ubuntu@${module.jenkins.elastic_ip}"
}

output "kubectl_config_command" {
  description = "Run this after terraform apply to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}"
}
