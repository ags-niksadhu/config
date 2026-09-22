#!/usr/bin/env bash
# CPMS Cloud Armor — final setup script (gcloud only, no Terraform required).
# Run this directly on any machine with gcloud authenticated to your project
# (your GCP VM, Cloud Shell, or your laptop).
#
# Usage:
#   1. Fill in the CONFIG section below.
#   2. chmod +x setup-cloud-armor.sh
#   3. ./setup-cloud-armor.sh
#
# Requires:
#   - gcloud CLI authenticated (`gcloud auth login`)
#   - roles/compute.admin (compute.projects.setCloudArmorTier, backend service updates)
#   - roles/billing.admin on the billing account backing this project (for Enterprise enrollment)

set -euo pipefail

# ============================================================================
# CONFIG — edit this section
# ============================================================================
PROJECT_ID="your-cpms-project-id"

# MODE="split"  -> you have TWO backend services behind one LB/URL map:
#                  one for the NestJS API VM, one for the Next.js frontend VM,
#                  routed by path (e.g. /api/*) or host.
# MODE="single" -> you have ONE backend service, with both VMs sitting behind
#                  it (e.g. for HA/scaling of a single combined deployment).
MODE="split"

# --- used when MODE="split" ---
API_POLICY="cpms-api-policy"
FRONTEND_POLICY="cpms-frontend-policy"
API_BACKEND_SERVICE="cpms-api-backend"           # run: gcloud compute backend-services list
FRONTEND_BACKEND_SERVICE="cpms-frontend-backend" # run: gcloud compute backend-services list

# --- used when MODE="single" ---
UNIFIED_POLICY="cpms-policy"
UNIFIED_BACKEND_SERVICE="cpms-backend"           # run: gcloud compute backend-services list

# Set --global below to match your LB. If your backend service is regional
# (e.g. behind a regional LB in front of Cloud Run/VMs in one region), change
# BACKEND_SCOPE_FLAG to: --region=YOUR_REGION
BACKEND_SCOPE_FLAG="--global"

# true = WAF rules only log matches (safe for first rollout)
# false = WAF rules actually block matching requests
PREVIEW_MODE=true

# ============================================================================
# Nothing below this line should need editing
# ============================================================================

gcloud config set project "$PROJECT_ID"

# ---------------------------------------------------------------------------
# 0. Enroll the project in Cloud Armor Enterprise (Paygo)
#    ~$200/month per project (first 2 protected resources included, then
#    per-resource charges) — confirm current pricing before relying on this.
# ---------------------------------------------------------------------------
gcloud compute project-info update \
  --cloud-armor-tier=CA_ENTERPRISE_PAYGO \
  --project="$PROJECT_ID"

gcloud compute project-info describe \
  --project="$PROJECT_ID" \
  --format="value(cloudArmorTier)"

# ---------------------------------------------------------------------------
# Reusable function: build one full policy (adaptive protection + rate limit
# + WAF rules) given a policy name and rate-limit thresholds.
# ---------------------------------------------------------------------------
create_policy() {
  local POLICY="$1"
  local DESC="$2"
  local RATE_COUNT="$3"
  local RATE_INTERVAL="$4"
  local BAN_COUNT="$5"
  local BAN_INTERVAL="$6"
  local BAN_DURATION="$7"

  gcloud compute security-policies create "$POLICY" \
    --description="$DESC" \
    --type=CLOUD_ARMOR

  gcloud compute security-policies update "$POLICY" \
    --enable-layer7-ddos-defense

  gcloud compute security-policies rules create 1000 \
    --security-policy="$POLICY" \
    --description="Rate limit + ban per IP" \
    --src-ip-ranges="*" \
    --action="rate-based-ban" \
    --rate-limit-threshold-count="$RATE_COUNT" \
    --rate-limit-threshold-interval-sec="$RATE_INTERVAL" \
    --ban-duration-sec="$BAN_DURATION" \
    --ban-threshold-count="$BAN_COUNT" \
    --ban-threshold-interval-sec="$BAN_INTERVAL" \
    --conform-action="allow" \
    --exceed-action="deny-429" \
    --enforce-on-key="IP"

  local PREVIEW_FLAG=""
  if [ "$PREVIEW_MODE" = "true" ]; then
    PREVIEW_FLAG="--preview"
  fi

  declare -A WAF_RULES=(
    [1100]="sqli-v33-stable:SQL injection"
    [1200]="xss-v33-stable:Cross-site scripting"
    [1300]="lfi-v33-stable:Local file inclusion"
    [1400]="rfi-v33-stable:Remote file inclusion"
    [1500]="rce-v33-stable:Remote code execution"
    [1600]="scannerdetection-v33-stable:Scanner detection"
    [1700]="protocolattack-v33-stable:Protocol attacks"
    [1800]="sessionfixation-v33-stable:Session fixation"
    [1900]="nodejs-v33-stable:Node.js injection patterns"
  )

  for PRIORITY in "${!WAF_RULES[@]}"; do
    IFS=":" read -r RULE_ID RULE_DESC <<< "${WAF_RULES[$PRIORITY]}"
    gcloud compute security-policies rules create "$PRIORITY" \
      --security-policy="$POLICY" \
      --description="$RULE_DESC" \
      --expression="evaluatePreconfiguredWaf('${RULE_ID}')" \
      --action="deny-403" \
      $PREVIEW_FLAG
  done
}

# ---------------------------------------------------------------------------
# Build and attach policies based on MODE
# ---------------------------------------------------------------------------
if [ "$MODE" = "split" ]; then

  create_policy "$API_POLICY" "Cloud Armor policy for CPMS NestJS API" \
    100 60 300 300 600

  create_policy "$FRONTEND_POLICY" "Cloud Armor policy for CPMS Next.js frontend" \
    300 60 900 300 300

  gcloud compute backend-services update "$API_BACKEND_SERVICE" \
    --security-policy="$API_POLICY" \
    $BACKEND_SCOPE_FLAG

  gcloud compute backend-services update "$FRONTEND_BACKEND_SERVICE" \
    --security-policy="$FRONTEND_POLICY" \
    $BACKEND_SCOPE_FLAG

  echo "Done. '$API_POLICY' -> $API_BACKEND_SERVICE, '$FRONTEND_POLICY' -> $FRONTEND_BACKEND_SERVICE"

elif [ "$MODE" = "single" ]; then

  create_policy "$UNIFIED_POLICY" "Cloud Armor policy for CPMS (single backend, two VMs)" \
    200 60 600 300 300

  gcloud compute backend-services update "$UNIFIED_BACKEND_SERVICE" \
    --security-policy="$UNIFIED_POLICY" \
    $BACKEND_SCOPE_FLAG

  echo "Done. '$UNIFIED_POLICY' -> $UNIFIED_BACKEND_SERVICE"

else
  echo "ERROR: MODE must be 'split' or 'single'. Got: $MODE" >&2
  exit 1
fi

if [ "$PREVIEW_MODE" = "true" ]; then
  echo ""
  echo "NOTE: WAF rules are in PREVIEW mode (logging only, not blocking)."
  echo "Check Cloud Logging (resource.type=\"http_load_balancer\") for a few days,"
  echo "then set PREVIEW_MODE=false above and re-run to start enforcing."
fi
