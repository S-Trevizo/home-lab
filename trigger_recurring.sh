#!/bin/bash
# trigger_recurring.sh
# Creates Firefly III recurring transactions for a target month by reading
# recurrences directly from the API and posting transactions for each occurrence.
#
# Usage:
#   ./trigger_recurring.sh              # current month
#   ./trigger_recurring.sh 2026-04      # specific month (YYYY-MM)
#   ./trigger_recurring.sh 2026-04 --dry-run  # preview without creating
#
# Infisical config overrides (optional env vars):
#   AUTH_FILE, INFISICAL_API_URL, PROJECT_ID, INFISICAL_ENV, FIREFLY_URL

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
FIREFLY_URL="${FIREFLY_URL:-http://localhost:8282}"

# Infisical config — mirrors manage.sh
AUTH_FILE="${AUTH_FILE:-/docker/infisical-auth}"
INFISICAL_API_URL="${INFISICAL_API_URL:-http://192.168.1.49:8085/api}"
PROJECT_ID="${PROJECT_ID:-c518f78a-d755-43fa-8d01-44cddeaeb8b8}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

# ── Parse args ────────────────────────────────────────────────────────────────
DRY_RUN=false
TARGET_MONTH=""

for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
    elif [[ -z "$TARGET_MONTH" ]]; then
        TARGET_MONTH="$arg"
    fi
done

# ── Determine target month ────────────────────────────────────────────────────
if [[ -n "$TARGET_MONTH" ]]; then
    if ! [[ "$TARGET_MONTH" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "ERROR: Month must be in YYYY-MM format (e.g. 2026-04)"
        exit 1
    fi
else
    TARGET_MONTH=$(date +%Y-%m)
fi

# Compute start/end dates for the month
MONTH_START="${TARGET_MONTH}-01"
MONTH_END=$(date -d "${TARGET_MONTH}-01 +1 month -1 day" +%Y-%m-%d)

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
    --silent \
    --plain)

if [[ -z "$INFISICAL_TOKEN" ]]; then
    echo "ERROR: Failed to obtain access token from Infisical"
    exit 1
fi

echo "  Fetching FIREFLY_API_KEY from Infisical..."
API_KEY=$(infisical secrets get "FIREFLY_API_KEY" \
    --token="$INFISICAL_TOKEN" \
    --domain="$INFISICAL_API_URL" \
    --projectId="$PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --silent \
    --plain 2>&1)

if [[ -z "$API_KEY" ]]; then
    echo "ERROR: FIREFLY_API_KEY returned empty from Infisical"
    exit 1
fi

# ── Helper: Firefly API calls ─────────────────────────────────────────────────
firefly_get() {
    curl -sf \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json" \
        "${FIREFLY_URL}$1"
}

firefly_post() {
    curl -sf \
        -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -d "$2" \
        "${FIREFLY_URL}$1"
}

# ── Fetch all recurrences ─────────────────────────────────────────────────────
echo "  Fetching recurrences from Firefly..."
RECURRENCES=$(firefly_get "/api/v1/recurrences?limit=100&page=1")

if [[ -z "$RECURRENCES" ]]; then
    echo "ERROR: Failed to fetch recurrences from Firefly"
    exit 1
fi

# ── Fetch existing transactions for the month (for duplicate detection) ───────
echo "  Fetching existing transactions for $TARGET_MONTH..."
EXISTING=$(firefly_get "/api/v1/transactions?start=${MONTH_START}&end=${MONTH_END}&limit=500&page=1")

if [[ -z "$EXISTING" ]]; then
    echo "ERROR: Failed to fetch existing transactions from Firefly"
    exit 1
fi

# Build a lookup of "date|description|amount" for existing transactions
EXISTING_KEYS=$(echo "$EXISTING" | jq -r '
    .data[].attributes.transactions[] |
    "\(.date | split("T")[0])|\(.description)|\(.amount | tonumber | . * 100 | round | . / 100)"
' 2>/dev/null || true)

TOTAL=$(echo "$RECURRENCES" | jq -r '.meta.pagination.total')
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Firefly III Recurring Transaction Trigger"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Target month  : $TARGET_MONTH ($MONTH_START → $MONTH_END)"
echo "  Recurrences   : $TOTAL"
echo "  Firefly URL   : $FIREFLY_URL"
[[ "$DRY_RUN" == true ]] && echo "  Mode          : DRY RUN (no transactions will be created)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

CREATED_COUNT=0
DUPLICATE_COUNT=0
FAILED_COUNT=0

# Arrays to collect skip summaries
declare -a SKIPPED_INACTIVE=()
declare -a SKIPPED_NO_OCCURRENCE=()
declare -a SKIPPED_DUPLICATE=()

# ── Process each recurrence ───────────────────────────────────────────────────
while IFS= read -r recurrence; do
    TITLE=$(echo "$recurrence" | jq -r '.attributes.title')
    TYPE=$(echo "$recurrence" | jq -r '.attributes.type')
    ACTIVE=$(echo "$recurrence" | jq -r '.attributes.active')

    if [[ "$ACTIVE" != "true" ]]; then
        SKIPPED_INACTIVE+=("$TITLE")
        continue
    fi

    # Get transaction details
    TX=$(echo "$recurrence" | jq -r '.attributes.transactions[0]')
    AMOUNT=$(echo "$TX" | jq -r '.amount | tonumber | . * 100 | round | . / 100')
    DESCRIPTION=$(echo "$TX" | jq -r '.description')
    SOURCE_ID=$(echo "$TX" | jq -r '.source_id')
    DESTINATION_ID=$(echo "$TX" | jq -r '.destination_id')
    CURRENCY_ID=$(echo "$TX" | jq -r '.currency_id')
    CATEGORY_ID=$(echo "$TX" | jq -r '.category_id // empty')
    BUDGET_ID=$(echo "$TX" | jq -r '.budget_id // empty')
    PIGGY_BANK_ID=$(echo "$TX" | jq -r '.piggy_bank_id // empty')
    TAGS=$(echo "$TX" | jq -c '.tags // []')

    # Find occurrences in target month
    OCCURRENCES=$(echo "$recurrence" | jq -r \
        ".attributes.repetitions[].occurrences[] | select(startswith(\"$TARGET_MONTH\"))" \
        2>/dev/null || true)

    if [[ -z "$OCCURRENCES" ]]; then
        SKIPPED_NO_OCCURRENCE+=("$TITLE")
        continue
    fi

    while IFS= read -r occurrence_dt; do
        DATE=$(echo "$occurrence_dt" | cut -dT -f1)

        # Duplicate check: date|description|amount
        LOOKUP_KEY="${DATE}|${DESCRIPTION}|${AMOUNT}"
        if echo "$EXISTING_KEYS" | grep -qF "$LOOKUP_KEY"; then
            echo "  [$DATE] $TITLE ($TYPE, \$$AMOUNT) ... ⟳ duplicate, skipping"
            SKIPPED_DUPLICATE+=("$DATE | $TITLE (\$$AMOUNT)")
            ((DUPLICATE_COUNT++)) || true
            continue
        fi

        echo -n "  [$DATE] $TITLE ($TYPE, \$$AMOUNT) ... "

        if [[ "$DRY_RUN" == true ]]; then
            echo "DRY RUN"
            ((CREATED_COUNT++)) || true
            continue
        fi

        # Build transaction JSON
        TX_JSON=$(jq -n \
            --arg type "$TYPE" \
            --arg date "$DATE" \
            --arg amount "$AMOUNT" \
            --arg description "$DESCRIPTION" \
            --arg source_id "$SOURCE_ID" \
            --arg destination_id "$DESTINATION_ID" \
            --arg currency_id "$CURRENCY_ID" \
            --argjson tags "$TAGS" \
            --arg category_id "$CATEGORY_ID" \
            --arg budget_id "$BUDGET_ID" \
            --arg piggy_bank_id "$PIGGY_BANK_ID" \
            '{
                transactions: [{
                    type: $type,
                    date: $date,
                    amount: $amount,
                    description: $description,
                    source_id: ($source_id | if . == "" then null else . end),
                    destination_id: ($destination_id | if . == "" then null else . end),
                    currency_id: ($currency_id | if . == "" then null else . end),
                    tags: $tags,
                    category_id: ($category_id | if . == "" then null else . end),
                    budget_id: ($budget_id | if . == "" then null else . end),
                    piggy_bank_id: ($piggy_bank_id | if . == "" then null else . end),
                    notes: "Created by trigger_recurring.sh"
                }]
            }')

        RESPONSE=$(firefly_post "/api/v1/transactions" "$TX_JSON" 2>&1)
        TX_ID=$(echo "$RESPONSE" | jq -r '.data.id // empty' 2>/dev/null || true)

        if [[ -n "$TX_ID" ]]; then
            echo "✓ created (id: $TX_ID)"
            ((CREATED_COUNT++)) || true
        else
            echo "✗ FAILED"
            echo "    Response: $(echo "$RESPONSE" | jq -r '.message // .' 2>/dev/null || echo "$RESPONSE")"
            ((FAILED_COUNT++)) || true
        fi

    done <<< "$OCCURRENCES"

done < <(echo "$RECURRENCES" | jq -c '.data[]')

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done."
echo ""
[[ "$DRY_RUN" == true ]] && echo "  Would create : $CREATED_COUNT transaction(s)" || echo "  Created      : $CREATED_COUNT transaction(s)"
echo "  Duplicates   : $DUPLICATE_COUNT (skipped)"
echo "  Failed       : $FAILED_COUNT"
echo ""

if [[ ${#SKIPPED_NO_OCCURRENCE[@]} -gt 0 ]]; then
    echo "  Not due in $TARGET_MONTH:"
    for title in "${SKIPPED_NO_OCCURRENCE[@]}"; do
        echo "    • $title"
    done
    echo ""
fi

if [[ ${#SKIPPED_INACTIVE[@]} -gt 0 ]]; then
    echo "  Inactive recurrences:"
    for title in "${SKIPPED_INACTIVE[@]}"; do
        echo "    • $title"
    done
    echo ""
fi

if [[ ${#SKIPPED_DUPLICATE[@]} -gt 0 ]]; then
    echo "  Duplicates skipped:"
    for entry in "${SKIPPED_DUPLICATE[@]}"; do
        echo "    • $entry"
    done
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
    exit 1
fi