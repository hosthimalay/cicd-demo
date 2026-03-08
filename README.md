# CI/CD Demo Project

Production-grade CI/CD pipeline using Jenkins, GitHub, Docker, AWS ECR, and Kubernetes (EKS).

## Architecture

```
Developer pushes code
        │
        ▼
    GitHub
    ├── PR opened → GitHub Actions (pr-checks.yml)
    │               ├── Lint
    │               ├── Unit Tests
    │               ├── Security Scan
    │               └── Docker Build Validation
    │
    └── Merge to main → GitHub webhook → Jenkins
                        Jenkinsfile Pipeline:
                        ├── Checkout
                        ├── Install Dependencies
                        ├── Lint
                        ├── Unit Tests (JUnit report)
                        ├── Security Scan (npm audit)
                        ├── Build Docker Image
                        ├── Image CVE Scan (Trivy)
                        ├── Push to AWS ECR
                        ├── Deploy to Staging (Helm → EKS)
                        ├── Smoke Tests (smoke_test.py)
                        ├── Manual Approval Gate
                        ├── Deploy to Production (Helm → EKS)
                        └── Production Smoke Tests
```

## Project Structure

```
.
├── app/                        # Node.js application
│   ├── server.js               # Express app with health/ready/api endpoints
│   ├── server.test.js          # Jest unit tests
│   ├── package.json
│   ├── Dockerfile              # Multi-stage production build
│   └── .dockerignore
│
├── k8s/                        # Kubernetes manifests
│   ├── deployment.yaml         # Deployment with resource limits, probes, HPA
│   ├── service.yaml            # Service + ConfigMap + HPA + PodDisruptionBudget
│   └── ingress.yaml            # ALB Ingress for HTTPS
│
├── terraform/                  # Infrastructure as Code
│   ├── main.tf                 # EKS cluster, ECR, VPC, IAM roles
│   └── variables.tf
│
├── scripts/
│   ├── bash/
│   │   ├── deploy.sh           # Manual deploy helper with safety checks
│   │   ├── rollback.sh         # Emergency rollback script
│   │   └── health_check.sh     # Cluster + HTTP health checker (runs via cron)
│   └── python/
│       ├── smoke_test.py       # Post-deploy smoke tests (runs in Jenkins)
│       ├── ecr_cleanup.py      # Weekly ECR image cleanup
│       └── pipeline_monitor.py # DORA metrics + Slack digest
│
├── .github/
│   └── workflows/
│       ├── pr-checks.yml       # Fast PR feedback (lint, test, docker validate)
│       └── pipeline-health.yml # Weekly Jenkins health report
│
├── Jenkinsfile                 # Full CI/CD pipeline definition
└── docker-compose.yml          # Local development environment
```

## Quick Start (Local)

```bash
# 1. Start app and Jenkins locally
docker-compose up -d

# 2. App running at: http://localhost:3000
# 3. Jenkins running at: http://localhost:8080
# 4. Get Jenkins admin password:
docker exec cicd-jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## Running Tests

```bash
cd app
npm ci
npm test
```

## Deploying Manually

```bash
# Set environment variables
export ECR_REGISTRY=123456789.dkr.ecr.eu-west-1.amazonaws.com
export AWS_REGION=eu-west-1
export EKS_CLUSTER=cicd-demo-cluster

# Deploy specific version to staging
./scripts/bash/deploy.sh a3f8c12 staging

# Emergency rollback
./scripts/bash/rollback.sh production

# Health check
./scripts/bash/health_check.sh production
```

## AWS Infrastructure

Provisioned with Terraform:
- **VPC** — 3 AZs, public/private subnets, NAT Gateway
- **EKS cluster** — managed node group (t3.medium), spot instances in staging
- **ECR repository** — image scanning on push, lifecycle policy
- **IAM roles** — least-privilege for Jenkins and EKS nodes

```bash
cd terraform
terraform init
terraform workspace new staging
terraform apply -var="environment=staging"
```

## Scripts Reference

| Script | When it runs | Purpose |
|--------|-------------|---------|
| `scripts/bash/deploy.sh` | Manual / emergency | Deploy specific image tag to environment |
| `scripts/bash/rollback.sh` | P1/P2 incident | Immediate rollback to previous version |
| `scripts/bash/health_check.sh` | Cron every 5 min | Cluster and HTTP health monitoring |
| `scripts/python/smoke_test.py` | Jenkins post-deploy | Verify app is serving correctly |
| `scripts/python/ecr_cleanup.py` | Jenkins weekly cron | Clean old ECR images to control costs |
| `scripts/python/pipeline_monitor.py` | Jenkins daily cron | DORA metrics + Slack digest |
