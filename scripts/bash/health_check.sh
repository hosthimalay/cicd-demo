#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════
# health_check.sh — Cluster and application health checker
#
# PURPOSE:  Run every 5 minutes via cron (or Jenkins scheduled pipeline).
#           Checks pods, nodes, deployment status, and HTTP endpoints.
#           Sends Slack alert if anything is unhealthy.
#
# USAGE:    ./scripts/bash/health_check.sh [environment]
# EXAMPLE:  ./scripts/bash/health_check.sh production
#
# CRON:     */5 * * * * /opt/scripts/health_check.sh production >> /var/log/health_check.log 2>&1
# ════════════════════════════════════════════════════════════════════════════
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Configuration ─────────────────────────────────────────────────────────────
APP_NAME="cicd-demo"
ENVIRONMENT="${1:-production}"
AWS_REGION="${AWS_REGION:-eu-west-1}"
EKS_CLUSTER="${EKS_CLUSTER:-cicd-demo-cluster}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"  # Set in environment or Jenkins credentials
APP_URL="https://${ENVIRONMENT}.cicd-demo.example.com"
EXPECTED_MIN_PODS=2
HEALTH_LOG="/tmp/health_check_${ENVIRONMENT}.log"

# ── Tracking ──────────────────────────────────────────────────────────────────
ISSUES=()
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

log()         { echo "[$(date -u '+%H:%M:%S')] $*" | tee -a "$HEALTH_LOG"; }
log_ok()      { echo -e "${GREEN}✓${NC} $*"; }
log_fail()    { echo -e "${RED}✗${NC} $*"; ISSUES+=("$*"); }
log_warn()    { echo -e "${YELLOW}!${NC} $*"; }

# ── Slack notification ────────────────────────────────────────────────────────
send_slack_alert() {
  local message="$1"
  local color="${2:-danger}"

  if [[ -z "$SLACK_WEBHOOK" ]]; then
    log "Slack webhook not configured — skipping notification"
    return
  fi

  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-type: application/json' \
    -d "{
      \"attachments\": [{
        \"color\": \"${color}\",
        \"title\": \"Health Check Alert — ${APP_NAME} [${ENVIRONMENT}]\",
        \"text\": \"${message}\",
        \"footer\": \"health_check.sh | ${TIMESTAMP}\"
      }]
    }" > /dev/null
}

# ── Configure kubectl ─────────────────────────────────────────────────────────
log "Configuring kubectl for ${EKS_CLUSTER}..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$EKS_CLUSTER" \
  --alias "$EKS_CLUSTER" 2>/dev/null

# ── Check 1: Node health ──────────────────────────────────────────────────────
log "Checking node health..."
NOT_READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null \
  | grep -v " Ready " | wc -l | tr -d ' ')

if [[ "$NOT_READY_NODES" -gt 0 ]]; then
  log_fail "NODES: ${NOT_READY_NODES} node(s) are NOT Ready"
  kubectl get nodes --no-headers | grep -v " Ready " | tee -a "$HEALTH_LOG" || true
else
  log_ok "NODES: All nodes are Ready"
fi

# ── Check 2: Pod count ────────────────────────────────────────────────────────
log "Checking pod health for ${APP_NAME} in ${ENVIRONMENT}..."
RUNNING_PODS=$(kubectl get pods -n "$ENVIRONMENT" -l app="$APP_NAME" \
  --field-selector=status.phase=Running \
  --no-headers 2>/dev/null | wc -l | tr -d ' ')

CRASH_PODS=$(kubectl get pods -n "$ENVIRONMENT" -l app="$APP_NAME" \
  --no-headers 2>/dev/null | grep -c "CrashLoop\|Error\|OOMKilled" || echo 0)

if [[ "$RUNNING_PODS" -lt "$EXPECTED_MIN_PODS" ]]; then
  log_fail "PODS: Only ${RUNNING_PODS}/${EXPECTED_MIN_PODS} pods running"
else
  log_ok "PODS: ${RUNNING_PODS} pods running (minimum: ${EXPECTED_MIN_PODS})"
fi

if [[ "$CRASH_PODS" -gt 0 ]]; then
  log_fail "PODS: ${CRASH_PODS} pod(s) in crash/error state"
  kubectl get pods -n "$ENVIRONMENT" -l app="$APP_NAME" --no-headers \
    | tee -a "$HEALTH_LOG"
fi

# ── Check 3: HTTP health endpoint ─────────────────────────────────────────────
log "Checking HTTP health endpoint: ${APP_URL}/health"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 \
  --retry 2 \
  --retry-delay 3 \
  "${APP_URL}/health" 2>/dev/null || echo "000")

RESPONSE_TIME=$(curl -s -o /dev/null -w "%{time_total}" \
  --max-time 10 \
  "${APP_URL}/health" 2>/dev/null || echo "0")

if [[ "$HTTP_STATUS" == "200" ]]; then
  log_ok "HTTP: ${APP_URL}/health returned ${HTTP_STATUS} (${RESPONSE_TIME}s)"
  # Warn if response time is slow
  if (( $(echo "$RESPONSE_TIME > 2.0" | bc -l 2>/dev/null || echo 0) )); then
    log_warn "HTTP: Response time ${RESPONSE_TIME}s is slow (>2s threshold)"
  fi
else
  log_fail "HTTP: ${APP_URL}/health returned ${HTTP_STATUS} (expected 200)"
fi

# ── Check 4: Deployment rollout status ───────────────────────────────────────
log "Checking deployment rollout status..."
DESIRED=$(kubectl get deployment "$APP_NAME" -n "$ENVIRONMENT" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
AVAILABLE=$(kubectl get deployment "$APP_NAME" -n "$ENVIRONMENT" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")

if [[ "$AVAILABLE" == "$DESIRED" ]] && [[ "$DESIRED" -gt 0 ]]; then
  log_ok "DEPLOY: ${AVAILABLE}/${DESIRED} replicas available"
else
  log_fail "DEPLOY: Only ${AVAILABLE}/${DESIRED} replicas available"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
log "Health check complete — ${TIMESTAMP}"
echo "=========================================="

if [[ "${#ISSUES[@]}" -gt 0 ]]; then
  echo -e "${RED}UNHEALTHY — ${#ISSUES[@]} issue(s) found:${NC}"
  for issue in "${ISSUES[@]}"; do
    echo "  - $issue"
  done

  # Send Slack alert
  ALERT_MSG=$(printf '%s\n' "${ISSUES[@]}" | head -5)
  send_slack_alert "Health check failed:\n${ALERT_MSG}" "danger"

  exit 1
else
  echo -e "${GREEN}HEALTHY — All checks passed${NC}"
  exit 0
fi
