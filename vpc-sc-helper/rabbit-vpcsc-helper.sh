#!/usr/bin/env bash
# rabbit-vpcsc-helper — run INSIDE the customer organization.
#
# Given a VPC Service Controls violation id (the vpcServiceControlsUniqueIdentifier
# from an error message Rabbit reports, e.g. "D8Sdsrm..."), this script:
#   1. finds the matching policy-audit log entry in your logs,
#   2. identifies the exact perimeter that produced the denial,
#   3. prints the minimal ingress/egress rule needed for Rabbit's service account,
#   4. prints the exact gcloud commands (dry-run first) to apply it.
#
# It performs READ-ONLY operations. You review and run the printed commands.
#
# Required roles for the user running it:
#   - roles/logging.viewer on the org (or on the project named in the error)
#   - roles/accesscontextmanager.policyReader on the org
#
# Usage:
#   ./rabbit-vpcsc-helper.sh --org ORG_ID VIOLATION_ID [VIOLATION_ID...]
#   ./rabbit-vpcsc-helper.sh --project PROJECT_ID VIOLATION_ID  # if org-wide log read is not permitted
set -euo pipefail

SCOPE_FLAG="" SCOPE_VAL="" IDS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org) SCOPE_FLAG="--organization"; SCOPE_VAL="$2"; shift 2 ;;
    --project) SCOPE_FLAG="--project"; SCOPE_VAL="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) IDS+=("$1"); shift ;;
  esac
done
[[ -n "$SCOPE_VAL" && ${#IDS[@]} -gt 0 ]] || { echo "usage: $0 --org ORG_ID VIOLATION_ID..."; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

for VID in "${IDS[@]}"; do
  echo "==================================================================="
  echo "Violation: $VID"
  ENTRY=$(gcloud logging read \
    "protoPayload.metadata.vpcServiceControlsUniqueId=\"$VID\"" \
    "$SCOPE_FLAG=$SCOPE_VAL" --freshness=30d --limit=1 --format=json | jq '.[0] // empty')
  if [[ -z "$ENTRY" ]]; then
    echo "  Not found in logs (checked last 30 days at $SCOPE_FLAG=$SCOPE_VAL)."
    echo "  Try --org if you used --project, or verify the id."
    continue
  fi

  PERIMETER=$(jq -r '.protoPayload.metadata.securityPolicyInfo.servicePerimeterName' <<<"$ENTRY")
  POLICY=${PERIMETER%/servicePerimeters/*}       # accessPolicies/<id>
  PERIMETER_SHORT=${PERIMETER##*/}
  SERVICE=$(jq -r '.protoPayload.serviceName' <<<"$ENTRY")
  METHOD=$(jq -r '.protoPayload.methodName' <<<"$ENTRY")
  PRINCIPAL=$(jq -r '.protoPayload.authenticationInfo.principalEmail' <<<"$ENTRY")
  REASON=$(jq -r '.protoPayload.metadata.violationReason' <<<"$ENTRY")
  DRYRUN=$(jq -r '.protoPayload.metadata.dryRun // false' <<<"$ENTRY")
  N_INGRESS=$(jq '(.protoPayload.metadata.ingressViolations // []) | length' <<<"$ENTRY")
  N_EGRESS=$(jq '(.protoPayload.metadata.egressViolations // []) | length' <<<"$ENTRY")

  echo "  perimeter : $PERIMETER_SHORT   (policy: $POLICY, dry-run event: $DRYRUN)"
  echo "  service   : $SERVICE ($METHOD)"
  echo "  principal : $PRINCIPAL"
  echo "  reason    : $REASON"

  if [[ "$PRINCIPAL" != rabbit-*-sa@rbt-*.iam.gserviceaccount.com ]]; then
    echo "  NOTE: principal is not a Rabbit service account; this helper only generates rules for Rabbit SAs."
    continue
  fi

  if [[ "$N_INGRESS" -gt 0 ]]; then
    TARGETS=$(jq -r '[.protoPayload.metadata.ingressViolations[].targetResource] | unique | join(", ")' <<<"$ENTRY")
    echo "  direction : INGRESS (into $TARGETS)"
    cat <<EOF

  --- Add this INGRESS rule to perimeter '$PERIMETER_SHORT' ---
  # Sources must be 'Any': Rabbit's callers run on serverless infrastructure whose
  # requests cannot be attributed to a source project/network by VPC-SC. Access is
  # gated by the identity below - a dedicated, read-only service account.
- ingressFrom:
    identities:
    - serviceAccount:$PRINCIPAL
    sources:
    - accessLevel: '*'
  ingressTo:
    operations:
    - serviceName: $SERVICE
      methodSelectors:
      - method: '*'
    resources:
    - '*'
EOF
  fi

  if [[ "$N_EGRESS" -gt 0 ]]; then
    EG_TARGETS=$(jq -r '[.protoPayload.metadata.egressViolations[].targetResource] | unique | .[]' <<<"$ENTRY")
    echo "  direction : EGRESS (to: $(tr '\n' ' ' <<<"$EG_TARGETS"))"
    cat <<EOF

  --- Add this EGRESS rule to perimeter '$PERIMETER_SHORT' ---
  # Allows the Rabbit service account to move query/export results from your
  # perimeter into Rabbit's dedicated tenant project (the target below).
- egressFrom:
    identities:
    - serviceAccount:$PRINCIPAL
  egressTo:
    operations:
    - serviceName: $SERVICE
      methodSelectors:
      - method: '*'
    resources:
$(sed 's/^/    - /' <<<"$EG_TARGETS")
EOF
  fi

  cat <<EOF

  --- How to apply (review the YAML above, merge into files, then:) ---
  # 1. Export current rules so you APPEND rather than replace:
  gcloud access-context-manager perimeters describe $PERIMETER_SHORT \\
    --policy=${POLICY##*/} --format='yaml(status.ingressPolicies,status.egressPolicies)'
  # 2. Apply to the DRY-RUN config first and watch for violations to disappear:
  gcloud access-context-manager perimeters dry-run update $PERIMETER_SHORT \\
    --policy=${POLICY##*/} --set-ingress-policies=ingress.yaml --set-egress-policies=egress.yaml
  # 3. When clean, enforce:
  gcloud access-context-manager perimeters dry-run enforce $PERIMETER_SHORT --policy=${POLICY##*/}
EOF
done
