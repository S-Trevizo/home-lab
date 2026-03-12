#!/bin/bash
# trigger_recurring.sh
# Triggers Firefly III recurring transactions for every day in the current month.
# Useful for front-loading all expected transactions at the start of the month.
#
# Usage:
#   ./trigger_recurring.sh              # triggers today through end of current month
#   ./trigger_recurring.sh 2026-04      # triggers today through end of a specific month (YYYY-MM)
#   ./trigger_recurring.sh 2026-04 --force  # triggers ALL days in month, ignoring today's date
#                                           # WARNING: --force will create duplicates if transactions
#                                           # have already been triggered for past days this month
#
# Infisical config overrides (optional env vars):
#   AUTH_FILE, INFISICAL_API_URL, PROJECT_ID, INFISICAL_ENV, FIREFLY_URL
#
# The Firefly cron endpoint: GET /api/v1/cron/{token}?date=YYYY-MM-DD

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
FIREFLY_URL="${FIREFLY_URL:-http://localhost:8282}"
DELAY_SECONDS="${DELAY_SECONDS:-1}"  # delay between requests to avoid hammering

# Infisical config — mirrors manage.sh
AUTH_FILE="${AUTH_FILE:-/docker/infisical-auth}"
INFISICAL_API_URL="${INFISICAL_API_URL:-http://192.168.1.49:8085/api}"
PROJECT_ID="${PROJECT_ID:-c518f78a-d755-43fa-8d01-44cddeaeb8b8}"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

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

echo "  Fetching FIREFLY_CRON_TOKEN from Infisical..."
CRON_TOKEN=$(infisical secrets get "FIREFLY_CRON_TOKEN" \
    --token="$INFISICAL_TOKEN" \
    --domain="$INFISICAL_API_URL" \
    --projectId="$PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --silent \
    --plain 2>&1)

if [[ -z "$CRON_TOKEN" ]]; then
    echo "ERROR: FIREFLY_CRON_TOKEN returned empty from Infisical"
    exit 1
fi

# ── Parse args ────────────────────────────────────────────────────────────────
FORCE=false
TARGET_MONTH=""

for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE=true
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

YEAR="${TARGET_MONTH%-*}"
MONTH="${TARGET_MONTH#*-}"

# Number of days in target month
DAYS_IN_MONTH=$(cal "$MONTH" "$YEAR" | awk 'NF{last=$NF} END{print last}')

# ── Determine start day ───────────────────────────────────────────────────────
TODAY_MONTH=$(date +%Y-%m)

if [[ "$FORCE" == true ]]; then
    START_DAY=1
    START_NOTE="(--force: processing all days, duplicates possible)"
elif [[ "$TARGET_MONTH" == "$TODAY_MONTH" ]]; then
    START_DAY=$(date +%-d)
    START_NOTE="(starting from today to avoid duplicates)"
else
    START_DAY=1
    START_NOTE="(future month, starting from day 1)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Firefly III Recurring Transaction Trigger"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Target month   : $TARGET_MONTH"
echo "  Processing days: $START_DAY → $DAYS_IN_MONTH $START_NOTE"
echo "  Firefly URL    : $FIREFLY_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for DAY in $(seq -w "$START_DAY" "$DAYS_IN_MONTH"); do
    DATE="${TARGET_MONTH}-${DAY}"
    URL="${FIREFLY_URL}/api/v1/cron/${CRON_TOKEN}?date=${DATE}"

    HTTP_STATUS=$(curl -s -o /tmp/firefly_cron_response.json -w "%{http_code}" "$URL")

    if [[ "$HTTP_STATUS" == "200" ]]; then
        if command -v jq &>/dev/null; then
            CREATED=$(jq -r '.data.recurring_transactions.created // 0' /tmp/firefly_cron_response.json 2>/dev/null || echo "?")
            if [[ "$CREATED" == "0" ]]; then
                echo "  [$DATE] ✓ No recurring transactions due"
                ((SKIP_COUNT++)) || true
            else
                echo "  [$DATE] ✓ Created $CREATED transaction(s)"
                ((SUCCESS_COUNT++)) || true
            fi
        else
            echo "  [$DATE] ✓ OK (install jq for transaction counts)"
            ((SUCCESS_COUNT++)) || true
        fi
    else
        echo "  [$DATE] ✗ FAILED (HTTP $HTTP_STATUS)"
        ((FAIL_COUNT++)) || true
    fi

    sleep "$DELAY_SECONDS"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done."
echo "  Days with new transactions : $SUCCESS_COUNT"
echo "  Days with nothing due      : $SKIP_COUNT"
echo "  Failures                   : $FAIL_COUNT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi