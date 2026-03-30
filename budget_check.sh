#!/bin/bash
# budget_check.sh
# Calculates available budget for a target month.
#
# Formula:
#   Checking balance (end of prev month)
#   + Income into checking (target month)
#   - Sum of all active budget limits
#   - Sum of transfers out of checking (target month)
#   - Checking Account Buffer piggy bank target
#   = Leftover (should be >= 0)
#
# Usage:
#   ./budget_check.sh              # current month
#   ./budget_check.sh 2026-04      # specific month (YYYY-MM)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
FIREFLY_URL="${FIREFLY_URL:-http://localhost:8282}"
CHECKING_ACCOUNT_ID="1"
BUFFER_PIGGY_BANK_ID="8"

AUTH_FILE="${AUTH_FILE:-/docker/infisical-auth}"
INFISICAL_API_URL="${INFISICAL_API_URL:-http://192.168.1.49:8085/api}"
PROJECT_ID="${PROJECT_ID:-c518f78a-d755-43fa-8d01-44cddeaeb8b8}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET_MONTH=""
for arg in "$@"; do
    if [[ -z "$TARGET_MONTH" ]]; then
        TARGET_MONTH="$arg"
    fi
done

if [[ -n "$TARGET_MONTH" ]]; then
    if ! [[ "$TARGET_MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "ERROR: Month must be in YYYY-MM format (e.g. 2026-04)"
        exit 1
    fi
else
    TARGET_MONTH=$(date +%Y-%m)
fi

MONTH_START="${TARGET_MONTH}-01"
MONTH_END=$(date -d "${TARGET_MONTH}-01 +1 month -1 day" +%Y-%m-%d)
PREV_MONTH_END=$(date -d "${TARGET_MONTH}-01 -1 day" +%Y-%m-%d)

# ── Infisical auth ────────────────────────────────────────────────────────────
if [[ ! -f "$AUTH_FILE" ]]; then
    echo "ERROR: Auth file not found at $AUTH_FILE"
    exit 1
fi

source "$AUTH_FILE"

if [[ -z "${CLIENT_ID:-}" || -z "${CLIENT_SECRET:-}" ]]; then
    echo "ERROR: CLIENT_ID and CLIENT_SECRET must be set in $AUTH_FILE"
    exit 1
fi

echo "  Authenticating with Infisical..."
INFISICAL_TOKEN=$(INFISICAL_API_URL="$INFISICAL_API_URL" infisical login \
    --method=universal-auth \
    --client-id="$CLIENT_ID" \
    --client-secret="$CLIENT_SECRET" \
    --silent --plain)

if [[ -z "$INFISICAL_TOKEN" ]]; then
    echo "ERROR: Failed to obtain Infisical token"
    exit 1
fi

echo "  Fetching FIREFLY_API_KEY from Infisical..."
API_KEY=$(infisical secrets get "FIREFLY_API_KEY" \
    --token="$INFISICAL_TOKEN" \
    --domain="$INFISICAL_API_URL" \
    --projectId="$PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --silent --plain 2>&1)

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: FIREFLY_API_KEY returned empty"
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
firefly_get() {
    curl -sf \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json" \
        "${FIREFLY_URL}$1"
}

round2() { printf "%.2f" "$1"; }

# ── Fetch data ────────────────────────────────────────────────────────────────
echo "  Fetching checking balance as of $PREV_MONTH_END..."
CHECKING_DATA=$(firefly_get "/api/v1/accounts/${CHECKING_ACCOUNT_ID}?date=${PREV_MONTH_END}")
CHECKING_BALANCE=$(round2 "$(echo "$CHECKING_DATA" | jq -r '.data.attributes.current_balance | tonumber')")

echo "  Fetching income into checking for $TARGET_MONTH..."
INCOME_DATA=$(firefly_get "/api/v1/accounts/${CHECKING_ACCOUNT_ID}/transactions?start=${MONTH_START}&end=${MONTH_END}&limit=500&type=deposit")
INCOME_TOTAL=$(round2 "$(echo "$INCOME_DATA" | jq '[.data[].attributes.transactions[] | select(.destination_id == "'$CHECKING_ACCOUNT_ID'") | .amount | tonumber] | add // 0')")

echo "  Fetching budget limits for $TARGET_MONTH..."
BUDGETS_DATA=$(firefly_get "/api/v1/budgets?limit=100")
BUDGET_ID_NAME_MAP=$(echo "$BUDGETS_DATA" | jq -c '[.data[] | {id: .id, name: .attributes.name}]')

BUDGET_LIMITS_DATA=$(firefly_get "/api/v1/budget-limits?start=${MONTH_START}&end=${MONTH_END}&limit=100")
BUDGET_TOTAL=$(round2 "$(echo "$BUDGET_LIMITS_DATA" | jq '[.data[] | select(.attributes.budget_id != "2") | .attributes.amount | tonumber] | add // 0')")

BUDGET_DETAILS=$(echo "$BUDGET_LIMITS_DATA" | jq -r \
    --argjson names "$BUDGET_ID_NAME_MAP" \
    '.data[] | select(.attributes.budget_id != "2" and .attributes.budget_id != "16") | .attributes.budget_id as $bid | (.attributes.amount | tonumber) as $amt |
     ($names[] | select(.id == $bid) | .name) as $name |
     "\($name)|\($amt)"')

echo "  Fetching transfers out of checking for $TARGET_MONTH..."
TRANSFER_DATA=$(firefly_get "/api/v1/accounts/${CHECKING_ACCOUNT_ID}/transactions?start=${MONTH_START}&end=${MONTH_END}&limit=500&type=transfer")
TRANSFER_TOTAL=$(round2 "$(echo "$TRANSFER_DATA" | jq '[.data[].attributes.transactions[] | select(.source_id == "'$CHECKING_ACCOUNT_ID'" and .type == "transfer") | .amount | tonumber] | add // 0')")
TRANSFER_DETAILS=$(echo "$TRANSFER_DATA" | jq -r '.data[].attributes.transactions[] | select(.source_id == "'$CHECKING_ACCOUNT_ID'" and .type == "transfer") | "\(.description)|\(.amount | tonumber)"')

echo "  Fetching Checking Account Buffer target..."
PBANK_DATA=$(firefly_get "/api/v1/piggy-banks")
PBANK_TOTAL=$(round2 "$(echo "$PBANK_DATA" | jq '[.data[].attributes | select(any(.accounts[]; .name == "Discover Checking")) | .target_amount | tonumber] | add // 0')")
PBANK_DETAILS=$(echo "$PBANK_DATA" | jq -r '.data[].attributes| select(any(.accounts[]; .name == "Discover Checking")) | "\(.name)|\(.target_amount | tonumber)"')

# ── Math ──────────────────────────────────────────────────────────────────────
SUBTOTAL=$(round2 "$(echo "$CHECKING_BALANCE + $INCOME_TOTAL" | bc)")
LEFTOVER=$(round2 "$(echo "$SUBTOTAL - $BUDGET_TOTAL - $TRANSFER_TOTAL - $PBANK_TOTAL" | bc)")

# ── Output ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Budget Check — $TARGET_MONTH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-38s \$%s\n" "Checking balance ($PREV_MONTH_END):" "$CHECKING_BALANCE"
printf "  %-38s +\$%s\n" "Income into checking:" "$INCOME_TOTAL"
echo "  ──────────────────────────────────────"
printf "  %-38s \$%s\n" "Subtotal:" "$SUBTOTAL"
echo ""

echo "  Budget limits:"
while IFS='|' read -r name amount; do
    [[ -z "$name" ]] && continue
    printf "    %-36s -\$%s\n" "$name" "$(round2 "$amount")"
done <<< "$BUDGET_DETAILS"
printf "  %-38s -\$%s\n" "Total budget limits:" "$BUDGET_TOTAL"
echo ""

echo "  Transfers out of checking:"
if [[ -z "$TRANSFER_DETAILS" ]]; then
    echo "    (none)"
else
    while IFS='|' read -r desc amount; do
        [[ -z "$desc" ]] && continue
        printf "    %-36s -\$%s\n" "$desc" "$(round2 "$amount")"
    done <<< "$TRANSFER_DETAILS"
fi
printf "  %-38s -\$%s\n" "Total transfers:" "$TRANSFER_TOTAL"
echo ""

echo "  Piggy Banks:"
if [[ -z "$PBANK_DETAILS" ]]; then
    echo "    (none)"
else
    while IFS='|' read -r name target_amount; do
        [[ -z "$name" ]] && continue
        printf "    %-36s -\$%s\n" "$name" "$(round2 "$target_amount")"
    done <<< "$PBANK_DETAILS"
fi
printf "  %-38s -\$%s\n" "Total Piggy Banks:" "$PBANK_TOTAL"
echo ""
echo "  ──────────────────────────────────────"

if (( $(echo "$LEFTOVER >= 0" | bc -l) )); then
    printf "  %-38s \033[32m\$%s\033[0m\n" "Leftover:" "$LEFTOVER"
else
    printf "  %-38s \033[31m\$%s\033[0m\n" "OVER BUDGET:" "$LEFTOVER"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"