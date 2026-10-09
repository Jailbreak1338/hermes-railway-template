#!/usr/bin/env bash
# Exercises scripts/entrypoint.sh against a temporary HERMES_HOME with a stub
# `hermes` binary, so the bootstrap logic can be checked without Docker.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT}/scripts/entrypoint.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/hermes" <<'EOF'
#!/usr/bin/env bash
echo "stub-hermes $*"
echo "MESSAGING_CWD=${MESSAGING_CWD-<unset>}"
EOF
chmod +x "${WORK}/bin/hermes"

failures=0
case_dir=""

pass() { echo "  ok   - $*"; }
fail() { echo "  FAIL - $*"; failures=$((failures + 1)); }
check() {
  local msg="$1"
  shift
  if "$@"; then pass "$msg"; else fail "$msg"; fi
}

new_case() {
  echo "# $1"
  case_dir="$(mktemp -d "${WORK}/case.XXXXXX")"
  mkdir -p "${case_dir}/home"
}

run_entrypoint() {
  env -i \
    PATH="${WORK}/bin:/usr/bin:/bin" \
    HOME="${case_dir}" \
    HERMES_HOME="${case_dir}/home" \
    TERMINAL_CWD="${case_dir}/workspace" \
    OPENROUTER_API_KEY=sk-or-test \
    TELEGRAM_BOT_TOKEN=123:abc \
    TELEGRAM_ALLOWED_USERS=42 \
    "$@" \
    bash "$ENTRYPOINT" > "${case_dir}/out.log" 2>&1
}

assert_contains() {
  local file="$1" pattern="$2" msg="$3"
  if grep -qE -- "$pattern" "$file"; then pass "$msg"; else fail "$msg"; fi
}

assert_not_contains() {
  local file="$1" pattern="$2" msg="$3"
  if grep -qE -- "$pattern" "$file"; then fail "$msg"; else pass "$msg"; fi
}

count_matches() {
  grep -cE -- "$2" "$1" || true
}

# --- fresh volume -----------------------------------------------------------
new_case "fresh volume bootstraps config, env and marker"
if run_entrypoint; then pass "exits 0"; else fail "exits 0"; cat "${case_dir}/out.log"; fi
cfg="${case_dir}/home/config.yaml"
assert_contains "$cfg" "^terminal:$" "config.yaml has terminal section"
assert_contains "$cfg" "^  cwd: ${case_dir}/workspace$" "terminal.cwd uses TERMINAL_CWD"
assert_contains "${case_dir}/home/.env" "^OPENROUTER_API_KEY=sk-or-test$" ".env contains provider key"
assert_not_contains "${case_dir}/home/.env" "^MESSAGING_CWD=" ".env does not persist MESSAGING_CWD"
check "init marker written" test -f "${case_dir}/home/.initialized"
assert_contains "${case_dir}/out.log" "^stub-hermes gateway$" "execs hermes gateway"
perms="$(stat -c '%a' "${case_dir}/home/.env")"
check ".env is mode 600 (got ${perms})" test "$perms" = 600

# --- second boot ------------------------------------------------------------
echo "# second boot is idempotent"
cp "$cfg" "${case_dir}/config.before"
chmod 644 "${case_dir}/home/.env"
run_entrypoint
check "config.yaml unchanged" cmp -s "$cfg" "${case_dir}/config.before"
assert_contains "${case_dir}/out.log" "Skipping one-time init" "reports existing data"
perms="$(stat -c '%a' "${case_dir}/home/.env")"
check "existing .env tightened to 600 (got ${perms})" test "$perms" = 600

# --- legacy MESSAGING_CWD in persisted .env, terminal section without cwd ----
new_case "legacy MESSAGING_CWD is migrated into existing terminal section"
cat > "${case_dir}/home/config.yaml" <<'EOF'
model: foo
terminal:
  backend: local
  timeout: 60
compression:
  enabled: true
EOF
printf 'MESSAGING_CWD=/legacy/dir\n' > "${case_dir}/home/.env"
run_entrypoint
cfg="${case_dir}/home/config.yaml"
assert_contains "$cfg" "^  cwd: /legacy/dir$" "cwd inserted from persisted .env"
check "single terminal section" test "$(count_matches "$cfg" "^terminal:")" = 1
assert_contains "$cfg" "^model: foo$" "other keys preserved"
assert_not_contains "${case_dir}/home/.env" "^MESSAGING_CWD=" "MESSAGING_CWD removed from .env"
assert_contains "${case_dir}/out.log" "^MESSAGING_CWD=<unset>$" "MESSAGING_CWD unset for gateway"

# --- config without terminal section -----------------------------------------
new_case "MESSAGING_CWD env var appends terminal section when missing"
printf 'model: bar\n' > "${case_dir}/home/config.yaml"
run_entrypoint MESSAGING_CWD=/from/env
cfg="${case_dir}/home/config.yaml"
assert_contains "$cfg" "^terminal:$" "terminal section appended"
assert_contains "$cfg" "^  cwd: /from/env$" "cwd taken from MESSAGING_CWD"

# --- existing cwd is respected ------------------------------------------------
new_case "existing terminal.cwd is never overwritten"
printf 'terminal:\n  cwd: /keep/me\n' > "${case_dir}/home/config.yaml"
run_entrypoint MESSAGING_CWD=/other
assert_contains "${case_dir}/home/config.yaml" "^  cwd: /keep/me$" "cwd kept"
check "no duplicate cwd" test "$(count_matches "${case_dir}/home/config.yaml" "cwd:")" = 1

# --- validation failures ------------------------------------------------------
new_case "missing provider fails fast"
if run_entrypoint OPENROUTER_API_KEY=; then fail "exits non-zero"; else pass "exits non-zero"; fi
assert_contains "${case_dir}/out.log" "Configure a provider" "explains missing provider"

new_case "half-configured Slack fails fast"
if run_entrypoint TELEGRAM_BOT_TOKEN= SLACK_BOT_TOKEN=xoxb-1; then fail "exits non-zero"; else pass "exits non-zero"; fi
assert_contains "${case_dir}/out.log" "Slack requires both" "explains missing Slack token"

echo
if [[ "$failures" -gt 0 ]]; then
  echo "${failures} check(s) failed."
  exit 1
fi
echo "All checks passed."
