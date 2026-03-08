variable "vpc_id"        { type = string }
variable "subnet_id"     { type = string }
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "key_name"      { type = string }
variable "aws_region"    { type = string }
variable "ecr_registry"  { type = string }
variable "cluster_name"  { type = string }
variable "account_id"    { type = string }

output "elastic_ip"      { value = aws_eip.jenkins.public_ip }
output "instance_id"     { value = aws_instance.jenkins.id }
output "private_ip"      { value = aws_instance.jenkins.private_ip }
