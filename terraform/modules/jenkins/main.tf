# ════════════════════════════════════════════════════════════════════════════
# Module: jenkins
# Creates a persistent EC2 instance with Jenkins pre-installed via user_data.
# Also creates an Elastic IP so the public IP never changes between stop/start.
# ════════════════════════════════════════════════════════════════════════════

# ── Get the latest Ubuntu 22.04 AMI ──────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Canonical (Ubuntu official)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Security group: controls what traffic can reach Jenkins ──────────────────
resource "aws_security_group" "jenkins" {
  name        = "jenkins-sg"
  description = "Security group for Jenkins EC2 instance"
  vpc_id      = var.vpc_id

  # SSH — your laptop only (Terraform will use your current public IP)
  ingress {
    description = "SSH from anywhere restrict to your IP in production"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Restrict to your IP for better security
  }

  # Jenkins web UI — open to all so GitHub webhooks can reach it
  ingress {
    description = "Jenkins UI and GitHub webhooks"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins JNLP agent port — for build agents connecting to controller
  ingress {
    description = "Jenkins JNLP agent port"
    from_port   = 50000
    to_port     = 50000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All outbound traffic allowed — Jenkins needs to reach GitHub, ECR, EKS
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "jenkins-sg" }
}

# ── IAM role for Jenkins EC2 ──────────────────────────────────────────────────
# This role allows Jenkins to push to ECR and interact with EKS
# WITHOUT needing to store AWS credentials on the instance
resource "aws_iam_role" "jenkins" {
  name = "jenkins-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_permissions" {
  name = "jenkins-permissions"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR permissions — push and pull images
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:DescribeImages",
          "ecr:ListImages"
        ]
        Resource = "*"
      },
      {
        # EKS permissions — describe cluster and update kubeconfig
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      },
      {
        # Allow reading secrets from Secrets Manager (for app secrets)
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${var.account_id}:secret:cicd-demo/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}

# ── EC2 instance — Jenkins server ─────────────────────────────────────────────
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  root_block_device {
    volume_size           = 30    # GB — Docker images take space
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # user_data runs automatically when the instance first launches
  # It installs Java, Jenkins, Docker, kubectl, Helm, AWS CLI, Python, Trivy
  # This means you never need to SSH in and manually install anything
  user_data = templatefile("${path.module}/jenkins_install.sh.tpl", {
    aws_region   = var.aws_region
    ecr_registry = var.ecr_registry
    cluster_name = var.cluster_name
  })

  # Ensure instance is replaced (not just updated) if user_data changes
  user_data_replace_on_change = false   # Keep false — we don't want to lose Jenkins config

  tags = { Name = "jenkins-server" }

  lifecycle {
    # Prevent accidental destruction of the Jenkins instance
    # To destroy: first run 'terraform state rm module.jenkins.aws_instance.jenkins'
    # then terraform destroy, OR change this to false temporarily
    prevent_destroy = false   # Set to true once Jenkins is fully configured
  }
}

# ── Elastic IP — gives Jenkins a permanent public IP ─────────────────────────
# Without this, the IP changes every time you Stop/Start the EC2
# With this, the IP is always the same — GitHub webhook never needs updating
resource "aws_eip" "jenkins" {
  instance = aws_instance.jenkins.id
  domain   = "vpc"

  tags = { Name = "jenkins-eip" }
}
