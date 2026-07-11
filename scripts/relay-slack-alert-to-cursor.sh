#!/usr/bin/env bash
# Workaround for Cursor Slack automations not firing on bot messages (known regression).
# Point your alert system at this script (or equivalent) instead of relying on the
# Slack "New message" trigger for bot-authored posts.
#
# Usage:
#   export CURSOR_AUTOMATION_WEBHOOK_URL="https://api.cursor.com/automations/webhook/..."
#   export CURSOR_AUTOMATION_API_KEY="your-api-key"
#   ./scripts/relay-slack-alert-to-cursor.sh "Alert text from monitoring system"
#
# Get the webhook URL and API key from cursor.com/automations after saving a Webhook trigger.

set -euo pipefail

MESSAGE="${1:-}"
if [[ -z "$MESSAGE" ]]; then
  echo "Usage: $0 <alert-message>" >&2
  exit 1
fi

: "${CURSOR_AUTOMATION_WEBHOOK_URL:?Set CURSOR_AUTOMATION_WEBHOOK_URL}"
: "${CURSOR_AUTOMATION_API_KEY:?Set CURSOR_AUTOMATION_API_KEY}"

curl -fsS -X POST "$CURSOR_AUTOMATION_WEBHOOK_URL" \
  -H "Authorization: Bearer $CURSOR_AUTOMATION_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg msg "$MESSAGE" '{prompt: ("Investigate this alert and fix if needed:\n\n" + $msg)}')"

echo "Relayed alert to Cursor automation webhook."
