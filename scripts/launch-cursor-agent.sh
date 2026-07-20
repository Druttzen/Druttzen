#!/usr/bin/env bash
# Launch a Cursor Cloud Agent to fix a root cause on a PR branch.
#
# Usage:
#   ./scripts/launch-cursor-agent.sh --pr-url URL --branch BRANCH --prompt-file FILE
#   ./scripts/launch-cursor-agent.sh --pr-url URL --branch BRANCH --prompt "text..."
#
# Required env:
#   CURSOR_API_KEY  — from https://cursor.com/dashboard?tab=api-keys
#
# Optional env:
#   CURSOR_AGENT_MODEL   — model id (default: omit for account default)
#   GITHUB_REPOSITORY_URL — defaults to https://github.com/$GITHUB_REPOSITORY

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

: "${CURSOR_API_KEY:?Set CURSOR_API_KEY from https://cursor.com/dashboard?tab=api-keys}"

PR_URL=""
BRANCH=""
PROMPT=""
PROMPT_FILE=""
REPO_URL="${GITHUB_REPOSITORY_URL:-}"
NAME="Auto root-cause fix"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url) PR_URL="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --prompt) PROMPT="${2:-}"; shift 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 ;;
    --repo-url) REPO_URL="${2:-}"; shift 2 ;;
    --name) NAME="${2:-}"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT="$(cat "$PROMPT_FILE")"
fi

if [[ -z "$PROMPT" ]]; then
  echo "Usage: $0 --pr-url URL --branch BRANCH --prompt TEXT|--prompt-file FILE" >&2
  exit 1
fi

if [[ -z "$REPO_URL" ]]; then
  if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
    REPO_URL="https://github.com/${GITHUB_REPOSITORY}"
  else
    echo "Error: set --repo-url or GITHUB_REPOSITORY / GITHUB_REPOSITORY_URL" >&2
    exit 1
  fi
fi

payload="$(jq -n \
  --arg text "$PROMPT" \
  --arg name "$NAME" \
  --arg repo "$REPO_URL" \
  --arg branch "$BRANCH" \
  --arg pr "$PR_URL" \
  --arg model "${CURSOR_AGENT_MODEL:-}" \
  '
    {
      prompt: { text: $text },
      name: $name,
      workOnCurrentBranch: true,
      autoCreatePR: false,
      repos: [
        (
          { url: $repo }
          + (if $pr != "" then { prUrl: $pr } else {} end)
          + (if $branch != "" and $pr == "" then { startingRef: $branch } else {} end)
        )
      ]
    }
    + (if $model != "" then { model: { id: $model } } else {} end)
  ')"

response_file="$(mktemp)"
http_status="$(
  curl -sS \
    --connect-timeout "${CURSOR_AUTOMATION_CONNECT_TIMEOUT:-5}" \
    --max-time "${CURSOR_AUTOMATION_MAX_TIME:-30}" \
    -u "${CURSOR_API_KEY}:" \
    -w '%{http_code}' \
    -o "$response_file" \
    -X POST "https://api.cursor.com/v1/agents" \
    -H "Content-Type: application/json" \
    -d "$payload"
)"

if [[ "$http_status" -lt 200 || "$http_status" -ge 300 ]]; then
  echo "Error: Cursor Agents API returned HTTP $http_status" >&2
  cat "$response_file" >&2 || true
  rm -f "$response_file"
  exit 1
fi

agent_url="$(jq -r '.agent.url // empty' "$response_file")"
agent_id="$(jq -r '.agent.id // empty' "$response_file")"
echo "Launched Cursor agent: ${agent_url:-$agent_id}"
jq . "$response_file"
rm -f "$response_file"
