variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-1"
}

variable "app_name" {
  description = "Application name — used for ECR repo name and Kubernetes labels"
  type        = string
  default     = "cicd-demo"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "cicd-demo-cluster"
}

variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins server"
  type        = string
  default     = "t3.medium"   # 2 vCPU, 4 GB RAM — minimum for Jenkins
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair for SSH access to Jenkins. Create in AWS Console first."
  type        = string
  default     = "cicd-demo-key"
}
