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
# Structured alert (JSON file or stdin with --json):
#   ./scripts/relay-slack-alert-to-cursor.sh --json <<'EOF'
#   {"message":"checkout timeout","severity":"critical","service":"payments","environment":"production"}
#   EOF
#
# Optional metadata via environment variables (merged with JSON when both are set):
#   ALERT_SEVERITY=critical ALERT_SERVICE=payments ALERT_ENVIRONMENT=production \
#     ./scripts/relay-slack-alert-to-cursor.sh "checkout timeout"
#
# Optional timeout overrides (seconds):
#   CURSOR_AUTOMATION_CONNECT_TIMEOUT=5
#   CURSOR_AUTOMATION_MAX_TIME=15
#
# Get the webhook URL and API key from cursor.com/automations after saving a Webhook trigger.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Install jq and retry." >&2
  echo "  Debian/Ubuntu: sudo apt install jq" >&2
  echo "  macOS: brew install jq" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

: "${CURSOR_AUTOMATION_WEBHOOK_URL:?Set CURSOR_AUTOMATION_WEBHOOK_URL}"
: "${CURSOR_AUTOMATION_API_KEY:?Set CURSOR_AUTOMATION_API_KEY}"

build_prompt() {
  local message severity service environment
  message="$1"
  severity="${2:-}"
  service="${3:-}"
  environment="${4:-}"

  jq -nr \
    --arg message "$message" \
    --arg severity "$severity" \
    --arg service "$service" \
    --arg environment "$environment" \
    '
      "Investigate this alert and fix if needed:\n\n" +
      (if $message != "" then "Message: " + $message + "\n" else "" end) +
      (if $severity != "" then "Severity: " + $severity + "\n" else "" end) +
      (if $service != "" then "Service: " + $service + "\n" else "" end) +
      (if $environment != "" then "Environment: " + $environment + "\n" else "" end)
    '
}

parse_json_alert() {
  local input="$1"
  local message severity service environment

  message="$(jq -r '.message // .alert // .text // empty' <<<"$input")"
  severity="$(jq -r '.severity // empty' <<<"$input")"
  service="$(jq -r '.service // empty' <<<"$input")"
  environment="$(jq -r '.environment // empty' <<<"$input")"

  if [[ -z "$message" ]]; then
    echo "Error: JSON input must include a message field (message, alert, or text)." >&2
    exit 1
  fi

  severity="${ALERT_SEVERITY:-$severity}"
  service="${ALERT_SERVICE:-$service}"
  environment="${ALERT_ENVIRONMENT:-$environment}"

  build_prompt "$message" "$severity" "$service" "$environment"
}

if [[ "${1:-}" == "--json" ]]; then
  json_input="$(cat)"
  if [[ -z "$json_input" ]]; then
    echo "Usage: $0 --json <<'EOF'" >&2
    echo '{"message":"...", "severity":"...", "service":"...", "environment":"..."}' >&2
    echo "EOF" >&2
    exit 1
  fi
  prompt="$(parse_json_alert "$json_input")"
elif [[ -n "${1:-}" ]]; then
  prompt="$(build_prompt "$1" "${ALERT_SEVERITY:-}" "${ALERT_SERVICE:-}" "${ALERT_ENVIRONMENT:-}")"
else
  echo "Usage: $0 <alert-message>" >&2
  echo "       $0 --json  # read structured alert JSON from stdin" >&2
  exit 1
fi

payload="$(jq -n --arg prompt "$prompt" '{prompt: $prompt}')"

http_status="$(
  curl -sS \
    --connect-timeout "${CURSOR_AUTOMATION_CONNECT_TIMEOUT:-5}" \
    --max-time "${CURSOR_AUTOMATION_MAX_TIME:-15}" \
    -w '%{http_code}' \
    -o /dev/null \
    -X POST "$CURSOR_AUTOMATION_WEBHOOK_URL" \
    -H "Authorization: Bearer $CURSOR_AUTOMATION_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload"
)"
curl_exit_code=$?

if [[ $curl_exit_code -ne 0 ]]; then
  echo "Error: Failed to relay alert to Cursor automation webhook (curl exit code: $curl_exit_code)." >&2
  exit 1
fi

if [[ "$http_status" -lt 200 || "$http_status" -ge 300 ]]; then
  echo "Error: Cursor automation webhook returned non-success HTTP status: $http_status." >&2
  exit 1
fi

echo "Relayed alert to Cursor automation webhook (HTTP $http_status)."
