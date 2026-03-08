#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# deploy.sh — Manual deployment helper script
#
# PURPOSE:  Deploy a specific image tag to a Kubernetes namespace.
#           Used by DevOps engineers when a manual deploy is needed outside
#           of Jenkins (e.g. emergency hotfix, rollback to specific version).
#
# USAGE:    ./scripts/bash/deploy.sh <image-tag> <environment>
# EXAMPLE:  ./scripts/bash/deploy.sh a3f8c12 production
#           ./scripts/bash/deploy.sh v1.2.0   staging
#
# REQUIRES: aws cli, kubectl, helm, AWS credentials in environment
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail   # Exit on error, undefined variable, or pipe failure
                    # This is production-grade bash — always use this

# ── Colour codes for readable output ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No colour

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Configuration — edit these for your environment ───────────────────────────
APP_NAME="cicd-demo"
AWS_REGION="${AWS_REGION:-eu-west-1}"
ECR_REGISTRY="${ECR_REGISTRY:-}"          # Set via environment or Jenkins credentials
EKS_CLUSTER="${EKS_CLUSTER:-cicd-demo-cluster}"
HELM_CHART_PATH="./k8s/helm"

# ── Input validation ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <image-tag> <environment>"
  echo "  image-tag:   Docker image tag to deploy (e.g. a3f8c12 or v1.2.0)"
  echo "  environment: Target environment (staging or production)"
  echo ""
  echo "Examples:"
  echo "  $0 a3f8c12 staging"
  echo "  $0 v1.2.0 production"
  exit 1
}

# Require exactly 2 arguments
[[ $# -ne 2 ]] && { log_error "Wrong number of arguments"; usage; }

IMAGE_TAG="$1"
ENVIRONMENT="$2"

# Validate environment
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
  log_error "Environment must be 'staging' or 'production'"
  exit 1
fi

# Require ECR_REGISTRY to be set
if [[ -z "$ECR_REGISTRY" ]]; then
  log_error "ECR_REGISTRY environment variable is not set"
  log_error "Example: export ECR_REGISTRY=123456789.dkr.ecr.eu-west-1.amazonaws.com"
  exit 1
fi

IMAGE_FULL="${ECR_REGISTRY}/${APP_NAME}:${IMAGE_TAG}"

# ── Production safety check ───────────────────────────────────────────────────
if [[ "$ENVIRONMENT" == "production" ]]; then
  log_warn "You are about to deploy to PRODUCTION"
  log_warn "Image: ${IMAGE_FULL}"
  echo -n "Type 'yes' to confirm: "
  read -r CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Deployment cancelled"
    exit 0
  fi
fi

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log_info "Running pre-flight checks..."

# Check required tools
for tool in aws kubectl helm; do
  if ! command -v "$tool" &>/dev/null; then
    log_error "Required tool not found: $tool"
    exit 1
  fi
done
log_success "All required tools found"

# Check AWS credentials work
if ! aws sts get-caller-identity &>/dev/null; then
  log_error "AWS credentials are not configured or have expired"
  exit 1
fi
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
log_success "AWS authenticated (Account: ${AWS_ACCOUNT})"

# ── Verify the image exists in ECR before deploying ───────────────────────────
log_info "Verifying image exists in ECR: ${IMAGE_FULL}"
if ! aws ecr describe-images \
     --repository-name "${APP_NAME}" \
     --image-ids imageTag="${IMAGE_TAG}" \
     --region "${AWS_REGION}" &>/dev/null; then
  log_error "Image ${IMAGE_FULL} NOT FOUND in ECR"
  log_error "Available tags:"
  aws ecr list-images --repository-name "${APP_NAME}" \
    --region "${AWS_REGION}" \
    --filter tagStatus=TAGGED \
    --query 'imageIds[*].imageTag' \
    --output table
  exit 1
fi
log_success "Image confirmed in ECR"

# ── Configure kubectl ─────────────────────────────────────────────────────────
log_info "Configuring kubectl for EKS cluster: ${EKS_CLUSTER}"
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  --alias "${EKS_CLUSTER}"
log_success "kubectl configured"

# ── Record current running version (for rollback reference) ───────────────────
CURRENT_TAG=$(kubectl get deployment "${APP_NAME}" \
  -n "${ENVIRONMENT}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
  | cut -d: -f2 || echo "none")
log_info "Current running version: ${CURRENT_TAG}"
log_info "Deploying new version:   ${IMAGE_TAG}"

# ── Deploy with Helm ──────────────────────────────────────────────────────────
log_info "Deploying with Helm..."

REPLICA_COUNT=1
if [[ "$ENVIRONMENT" == "production" ]]; then
  REPLICA_COUNT=3
fi

helm upgrade --install "${APP_NAME}" "${HELM_CHART_PATH}" \
  --namespace "${ENVIRONMENT}" \
  --create-namespace \
  --set image.repository="${ECR_REGISTRY}/${APP_NAME}" \
  --set image.tag="${IMAGE_TAG}" \
  --set environment="${ENVIRONMENT}" \
  --set replicaCount="${REPLICA_COUNT}" \
  --atomic \
  --timeout 5m \
  --wait

# ── Post-deploy verification ──────────────────────────────────────────────────
log_info "Verifying deployment..."

# Wait for rollout to complete
kubectl rollout status deployment/"${APP_NAME}" \
  -n "${ENVIRONMENT}" \
  --timeout=3m

# Show pod status
kubectl get pods -n "${ENVIRONMENT}" -l app="${APP_NAME}" \
  --sort-by='.status.startTime'

log_success "Deployment complete!"
log_success "  App:         ${APP_NAME}"
log_success "  Version:     ${IMAGE_TAG}"
log_success "  Environment: ${ENVIRONMENT}"
log_success "  Previous:    ${CURRENT_TAG}"
echo ""
log_info "To rollback: kubectl rollout undo deployment/${APP_NAME} -n ${ENVIRONMENT}"
