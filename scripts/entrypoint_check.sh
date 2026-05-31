#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "[entrypoint-check] ERROR: $*" >&2
  exit 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "${name} is required."
  fi
}

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

require_one_provider() {
  if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${OPENAI_BASE_URL:-}" && -n "${OPENAI_API_KEY:-}" ]]; then
    return 0
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    return 0
  fi

  fail "Set OPENROUTER_API_KEY, or OPENAI_BASE_URL+OPENAI_API_KEY, or ANTHROPIC_API_KEY."
}

require_one_messaging_platform() {
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    return 0
  fi

  if [[ -n "${DISCORD_BOT_TOKEN:-}" ]]; then
    return 0
  fi

  if [[ -n "${SLACK_BOT_TOKEN:-}" || -n "${SLACK_APP_TOKEN:-}" ]]; then
    [[ -n "${SLACK_BOT_TOKEN:-}" ]] || fail "SLACK_BOT_TOKEN is required when Slack is configured."
    [[ -n "${SLACK_APP_TOKEN:-}" ]] || fail "SLACK_APP_TOKEN is required when Slack is configured."
    return 0
  fi

  fail "Configure at least one messaging platform: TELEGRAM_BOT_TOKEN, DISCORD_BOT_TOKEN, or Slack tokens."
}

require_allowlist_or_explicit_open_access() {
  if [[ -n "${TELEGRAM_ALLOWED_USERS:-}${DISCORD_ALLOWED_USERS:-}${SLACK_ALLOWED_USERS:-}${WHATSAPP_ALLOWED_USERS:-}" ]]; then
    return 0
  fi

  if is_true "${GATEWAY_ALLOW_ALL_USERS:-}" || is_true "${TELEGRAM_ALLOW_ALL_USERS:-}" || is_true "${DISCORD_ALLOW_ALL_USERS:-}" || is_true "${SLACK_ALLOW_ALL_USERS:-}"; then
    fail "Open access flags are not allowed in this hardened template. Set *_ALLOWED_USERS instead."
  fi

  fail "Set at least one *_ALLOWED_USERS allowlist."
}

require_writable_dir() {
  local path="$1"
  mkdir -p "$path"
  [[ -w "$path" ]] || fail "${path} is not writable by $(id -un)."
}

require_one_provider
require_one_messaging_platform
require_allowlist_or_explicit_open_access
require_writable_dir "${HERMES_HOME:-/data/.hermes}"
require_writable_dir "${MESSAGING_CWD:-/data/workspace}"

if [[ -n "${GOOGLE_CLIENT_ID:-}${GOOGLE_CLIENT_SECRET:-}${GOOGLE_REFRESH_TOKEN:-}" ]]; then
  require_env GOOGLE_CLIENT_ID
  require_env GOOGLE_CLIENT_SECRET
  require_env GOOGLE_REFRESH_TOKEN
fi

if [[ -n "${SUPABASE_URL:-}${SUPABASE_KEY:-}" ]]; then
  require_env SUPABASE_URL
  require_env SUPABASE_KEY
fi

echo "[entrypoint-check] Environment validated."
exec /app/scripts/entrypoint.sh
