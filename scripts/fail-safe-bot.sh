#!/usr/bin/env bash
# Auto Fail-Safe Bot — retries, circuit breaker, and dead-letter logging.
#
# Usage:
#   ./scripts/fail-safe-bot.sh run <command> [args...]
#   ./scripts/fail-safe-bot.sh relay "<alert message>"
#   ./scripts/fail-safe-bot.sh relay --json <<'EOF'
#   {"message":"checkout timeout","severity":"critical"}
#   EOF
#   ./scripts/fail-safe-bot.sh status
#   ./scripts/fail-safe-bot.sh reset
#
# Environment:
#   FAILSAFE_MAX_RETRIES=3
#   FAILSAFE_RETRY_DELAY=2
#   FAILSAFE_CIRCUIT_THRESHOLD=5
#   FAILSAFE_STATE_DIR=.failsafe
#   FAILSAFE_FALLBACK_WEBHOOK_URL (optional secondary Cursor webhook)

set -euo pipefail

STATE_DIR="${FAILSAFE_STATE_DIR:-.failsafe}"
STATE_FILE="$STATE_DIR/state.json"
DEAD_LETTER_DIR="$STATE_DIR/dead-letter"
MAX_RETRIES="${FAILSAFE_MAX_RETRIES:-3}"
RETRY_DELAY="${FAILSAFE_RETRY_DELAY:-2}"
CIRCUIT_THRESHOLD="${FAILSAFE_CIRCUIT_THRESHOLD:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR" "$DEAD_LETTER_DIR"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

init_state() {
  if [[ ! -f "$STATE_FILE" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: jq is required but not installed." >&2
      exit 1
    fi
    jq -n '{failures: 0, circuit_open: false, last_failure: null, last_success: null}' >"$STATE_FILE"
  fi
}

read_state() {
  init_state
  cat "$STATE_FILE"
}

write_state() {
  jq -n \
    --argjson failures "$1" \
    --argjson circuit_open "$2" \
    --arg last_failure "${3:-}" \
    --arg last_success "${4:-}" \
    '{
      failures: $failures,
      circuit_open: $circuit_open,
      last_failure: (if $last_failure == "" then null else $last_failure end),
      last_success: (if $last_success == "" then null else $last_success end)
    }' >"$STATE_FILE"
}

record_success() {
  write_state 0 false "" "$(now_iso)"
}

record_failure() {
  local failures circuit_open
  failures="$(jq -r '.failures' "$STATE_FILE")"
  failures=$((failures + 1))
  circuit_open=false
  if [[ $failures -ge $CIRCUIT_THRESHOLD ]]; then
    circuit_open=true
  fi
  write_state "$failures" "$circuit_open" "$(now_iso)" "$(jq -r '.last_success // empty' "$STATE_FILE")"
}

circuit_is_open() {
  [[ "$(jq -r '.circuit_open' "$STATE_FILE")" == "true" ]]
}

dead_letter() {
  local kind="$1"
  local payload="$2"
  local file="$DEAD_LETTER_DIR/$(date -u +%Y%m%dT%H%M%SZ)-${kind}.json"
  jq -n \
    --arg kind "$kind" \
    --arg payload "$payload" \
    --arg timestamp "$(now_iso)" \
    '{kind: $kind, payload: $payload, timestamp: $timestamp}' >"$file"
  echo "Dead letter written: $file" >&2
}

retry_run() {
  local attempt=1
  local delay="$RETRY_DELAY"
  while [[ $attempt -le $MAX_RETRIES ]]; do
    echo "Fail-safe attempt $attempt/$MAX_RETRIES: $*" >&2
    if "$@"; then
      record_success
      return 0
    fi
    record_failure
    if circuit_is_open; then
      dead_letter "circuit-open" "$*"
      echo "Error: circuit breaker open after $CIRCUIT_THRESHOLD failures." >&2
      return 1
    fi
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  dead_letter "max-retries" "$*"
  return 1
}

relay_primary() {
  if [[ "${1:-}" == "--json" ]]; then
    "$SCRIPT_DIR/relay-slack-alert-to-cursor.sh" --json
  else
    "$SCRIPT_DIR/relay-slack-alert-to-cursor.sh" "$1"
  fi
}

relay_json() {
  printf '%s' "$1" | "$SCRIPT_DIR/relay-slack-alert-to-cursor.sh" --json
}

relay_fallback() {
  if [[ -z "${FAILSAFE_FALLBACK_WEBHOOK_URL:-}" || -z "${FAILSAFE_FALLBACK_API_KEY:-}" ]]; then
    return 1
  fi
  local message="${1:-}"
  if [[ "$message" == "--json" ]]; then
    message="$(cat)"
    CURSOR_AUTOMATION_WEBHOOK_URL="$FAILSAFE_FALLBACK_WEBHOOK_URL" \
      CURSOR_AUTOMATION_API_KEY="$FAILSAFE_FALLBACK_API_KEY" \
      "$SCRIPT_DIR/relay-slack-alert-to-cursor.sh" --json <<<"$message"
  else
    CURSOR_AUTOMATION_WEBHOOK_URL="$FAILSAFE_FALLBACK_WEBHOOK_URL" \
      CURSOR_AUTOMATION_API_KEY="$FAILSAFE_FALLBACK_API_KEY" \
      "$SCRIPT_DIR/relay-slack-alert-to-cursor.sh" "$message"
  fi
}

cmd_run() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: $0 run <command> [args...]" >&2
    exit 1
  fi
  if circuit_is_open; then
    dead_letter "circuit-open" "$*"
    echo "Error: circuit breaker is open. Run '$0 reset' after fixing the issue." >&2
    exit 1
  fi
  retry_run "$@"
}

cmd_relay() {
  if circuit_is_open; then
    dead_letter "circuit-open" "${1:-stdin-json}"
    echo "Error: circuit breaker is open. Run '$0 reset' after fixing the issue." >&2
    exit 1
  fi

  if [[ "${1:-}" == "--json" ]]; then
    local payload
    payload="$(cat)"
    if retry_run relay_json "$payload"; then
      return 0
    fi
    echo "Primary relay failed. Trying fallback webhook..." >&2
    relay_fallback --json <<<"$payload"
  else
    local message="${1:-}"
    if [[ -z "$message" ]]; then
      echo "Usage: $0 relay \"<alert message>\"" >&2
      exit 1
    fi
    if retry_run relay_primary "$message"; then
      return 0
    fi
    echo "Primary relay failed. Trying fallback webhook..." >&2
    relay_fallback "$message"
  fi
}

cmd_status() {
  init_state
  echo "Fail-safe state ($STATE_FILE):"
  jq . "$STATE_FILE"
  local count
  count="$(find "$DEAD_LETTER_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "Dead letters: $count"
}

cmd_reset() {
  write_state 0 false "" "$(jq -r '.last_success // empty' "$STATE_FILE" 2>/dev/null || true)"
  echo "Fail-safe circuit breaker reset."
}

init_state

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  relay) shift; cmd_relay "$@" ;;
  status) cmd_status ;;
  reset) cmd_reset ;;
  *)
    echo "Usage: $0 {run|relay|status|reset}" >&2
    exit 1
    ;;
esac
