#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# rollback.sh — Emergency rollback script
#
# PURPOSE:  Immediately roll back a Kubernetes deployment to the previous
#           version. Used during P1/P2 incidents when a bad deploy is
#           causing production issues.
#
# USAGE:    ./scripts/bash/rollback.sh <environment> [revision-number]
# EXAMPLE:  ./scripts/bash/rollback.sh production          # Rolls back 1 step
#           ./scripts/bash/rollback.sh production 3        # Rolls back to revision 3
#
# REQUIRES: kubectl, AWS credentials (to authenticate to EKS)
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

APP_NAME="cicd-demo"
AWS_REGION="${AWS_REGION:-eu-west-1}"
EKS_CLUSTER="${EKS_CLUSTER:-cicd-demo-cluster}"

# ── Input validation ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 <environment> [revision-number]"
  echo "  environment:     staging or production"
  echo "  revision-number: (optional) specific Helm revision to roll back to"
  echo ""
  echo "Examples:"
  echo "  $0 production              # Immediate rollback to previous version"
  echo "  $0 staging 3               # Rollback to revision 3"
  exit 1
}

[[ $# -lt 1 ]] && { log_error "Missing arguments"; usage; }

ENVIRONMENT="$1"
REVISION="${2:-}"

[[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]] && {
  log_error "Environment must be staging or production"
  exit 1
}

# ── Show current state before rollback ───────────────────────────────────────
log_info "====== EMERGENCY ROLLBACK INITIATED ======"
log_info "Environment: ${ENVIRONMENT}"
log_info "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# Configure kubectl
log_info "Configuring kubectl..."
aws eks update-kubeconfig \
  --region "${AWS_REGION}" \
  --name "${EKS_CLUSTER}" \
  --alias "${EKS_CLUSTER}" 2>/dev/null

# Show what is currently running
log_info "Current pod state:"
kubectl get pods -n "${ENVIRONMENT}" -l app="${APP_NAME}" 2>/dev/null || \
  log_warn "Could not get pods — namespace may not exist"

CURRENT_IMAGE=$(kubectl get deployment "${APP_NAME}" \
  -n "${ENVIRONMENT}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
log_info "Currently deployed image: ${CURRENT_IMAGE}"

# Show rollout history so the engineer can see available revisions
log_info "Rollout history:"
kubectl rollout history deployment/"${APP_NAME}" -n "${ENVIRONMENT}" 2>/dev/null || \
  log_warn "Could not get rollout history"

echo ""

# ── Perform rollback ──────────────────────────────────────────────────────────
if [[ -n "$REVISION" ]]; then
  log_warn "Rolling back to specific revision: ${REVISION}"
  kubectl rollout undo deployment/"${APP_NAME}" \
    -n "${ENVIRONMENT}" \
    --to-revision="${REVISION}"
else
  log_warn "Rolling back to previous version..."
  kubectl rollout undo deployment/"${APP_NAME}" \
    -n "${ENVIRONMENT}"
fi

# ── Wait for rollback to complete ─────────────────────────────────────────────
log_info "Waiting for rollback to complete..."
if kubectl rollout status deployment/"${APP_NAME}" \
   -n "${ENVIRONMENT}" \
   --timeout=3m; then
  log_success "Rollback complete"
else
  log_error "Rollback timed out — check pod status manually"
  kubectl describe deployment "${APP_NAME}" -n "${ENVIRONMENT}"
  exit 1
fi

# ── Verify after rollback ─────────────────────────────────────────────────────
NEW_IMAGE=$(kubectl get deployment "${APP_NAME}" \
  -n "${ENVIRONMENT}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

echo ""
log_success "====== ROLLBACK COMPLETE ======"
log_success "  Environment: ${ENVIRONMENT}"
log_success "  Rolled back from: ${CURRENT_IMAGE}"
log_success "  Now running:      ${NEW_IMAGE}"
echo ""

# Show final pod state
kubectl get pods -n "${ENVIRONMENT}" -l app="${APP_NAME}"

echo ""
log_info "Next steps:"
log_info "  1. Verify the service is healthy: curl https://${ENVIRONMENT}.cicd-demo.example.com/health"
log_info "  2. Check logs: kubectl logs -n ${ENVIRONMENT} -l app=${APP_NAME} --tail=50"
log_info "  3. Open a postmortem ticket for the failed deploy"
log_info "  4. Notify stakeholders in Slack #incidents"
