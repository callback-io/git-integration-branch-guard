#!/usr/bin/env bash
# Scenario snippets run via `bash -c '...'` on purpose, so expansion happens
# inside the test repository subshell, and `check && pass || fail` is the
# intended reporting pattern because pass/fail never themselves fail.
# shellcheck disable=SC2015,SC2016
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/guard-git-command.sh"

pass_count=0
fail_count=0

pass() {
  printf 'PASS %s\n' "$1"
  pass_count=$((pass_count + 1))
}

fail() {
  printf 'FAIL %s\n%s\n' "$1" "$2" >&2
  fail_count=$((fail_count + 1))
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    fail "$name" "expected output to contain: $needle
actual output: $haystack"
    return 1
  fi
}

assert_empty() {
  local name="$1"
  local output="$2"

  if [ -n "$output" ]; then
    fail "$name" "expected no output, got: $output"
    return 1
  fi
}

json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

# Runs the hook with a synthesized PreToolUse payload for the given command,
# using the current directory as cwd. Prints the hook's stdout.
run_hook() {
  local command="$1"

  printf '{"tool_name": "Bash", "tool_input": {"command": "%s"}, "cwd": "%s"}' \
    "$(json_escape "$command")" "$(json_escape "$PWD")" |
    "$SCRIPT"
}

# Creates a repository with main, a dev integration branch, and a checked-out
# feature branch, then runs the supplied scenario inside it.
with_guard_repo() {
  local repo
  repo="$(mktemp -d)"

  (
    cd "$repo"
    git init -b main >/dev/null
    git config user.email test@example.com
    git config user.name Tester
    printf 'base\n' > app.txt
    git add app.txt
    git commit -m 'base' >/dev/null
    git switch -c dev >/dev/null 2>&1
    printf 'dev\n' > dev.txt
    git add dev.txt
    git commit -m 'feat: shared dev change' >/dev/null
    git switch -c feature/scoped main >/dev/null 2>&1
    "$@"
  )
  local status=$?

  rm -rf "$repo"
  return "$status"
}

test_merge_integration_into_work_is_denied() {
  local name="merge dev into work branch is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output" &&
      grep -Fq "one-way collection pools" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_merge_production_into_work_is_allowed() {
  local name="merge main into work branch produces no output"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git merge main\"}, \"cwd\": \"$PWD\"}" | "$1")"
    [ -z "$output" ]
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected silence"
}

test_rebase_onto_integration_is_denied() {
  local name="rebase onto dev is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git rebase origin/dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_pull_integration_is_denied() {
  local name="pull origin dev is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git pull origin dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_new_branch_from_integration_is_denied() {
  local name="switch -c from dev is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git switch -c feat/new dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output" &&
      grep -Fq "Create work branches from the production branch" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_compound_command_is_inspected() {
  local name="git merge dev behind && is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git fetch origin && git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_commit_message_mentioning_dev_is_allowed() {
  local name="commit message mentioning dev produces no output"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git commit -m %s\"}, \"cwd\": \"$PWD\"}" "\\\"merge dev follow-up\\\"" | "$1")"
    [ -z "$output" ]
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected silence"
}

test_push_integration_to_production_is_denied() {
  local name="push dev:main is denied"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git push origin dev:main\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"deny\"" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected deny decision"
}

test_merge_integration_while_on_it_is_allowed() {
  local name="merge dev while on dev produces no output"
  with_guard_repo bash -c '
    git switch dev >/dev/null 2>&1
    output="$(printf "{\"tool_input\": {\"command\": \"git merge origin/dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    [ -z "$output" ]
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected silence"
}

test_enforcement_ask_downgrades_decision() {
  local name="enforcement ask produces ask decision"
  with_guard_repo bash -c '
    printf "{\"integration\": [\"dev\"], \"enforcement\": \"ask\"}" > "$(git rev-parse --show-toplevel)/.branch-guard.json"
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"ask\"" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected ask decision"
}

test_enforcement_warn_allows_with_message() {
  local name="enforcement warn allows with a system message"
  with_guard_repo bash -c '
    printf "{\"integration\": [\"dev\"], \"enforcement\": \"warn\"}" > "$(git rev-parse --show-toplevel)/.branch-guard.json"
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"allow\"" <<<"$output" &&
      grep -Fq "Branch guard warning" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected allow with warning"
}

test_declared_promotion_is_allowed() {
  local name="declared promotion dev->staging produces no output"
  with_guard_repo bash -c '
    printf "{\"integration\": [\"dev\", \"staging\"], \"promotionPaths\": [\"dev->staging\"]}" > "$(git rev-parse --show-toplevel)/.branch-guard.json"
    git switch -c staging main >/dev/null 2>&1
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    [ -z "$output" ]
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected silence"
}

test_undeclared_promotion_is_denied() {
  local name="undeclared promotion dev->staging is denied"
  with_guard_repo bash -c '
    printf "{\"integration\": [\"dev\", \"staging\"]}" > "$(git rev-parse --show-toplevel)/.branch-guard.json"
    git switch -c staging main >/dev/null 2>&1
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "not declared in promotionPaths" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected promotion denial"
}

test_cherry_pick_of_integration_only_commit_asks() {
  local name="cherry-pick of a dev-only commit asks for confirmation"
  with_guard_repo bash -c '
    dev_commit="$(git rev-parse dev)"
    output="$(printf "{\"tool_input\": {\"command\": \"git cherry-pick $dev_commit\"}, \"cwd\": \"$PWD\"}" | "$1")"
    grep -Fq "\"permissionDecision\": \"ask\"" <<<"$output" &&
      grep -Fq "confirm its origin before cherry-picking" <<<"$output"
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected ask decision"
}

test_non_git_command_is_ignored() {
  local name="non-git command produces no output"
  local output

  output="$(printf '{"tool_input": {"command": "ls -la"}, "cwd": "/tmp"}' | "$SCRIPT")"
  assert_empty "$name" "$output" || return
  pass "$name"
}

test_disable_flag_skips_guard() {
  local name="BRANCH_GUARD_DISABLE=1 skips the guard"
  with_guard_repo bash -c '
    output="$(printf "{\"tool_input\": {\"command\": \"git merge dev\"}, \"cwd\": \"$PWD\"}" | BRANCH_GUARD_DISABLE=1 "$1")"
    [ -z "$output" ]
  ' _ "$SCRIPT" && pass "$name" || fail "$name" "expected silence"
}

run_test() {
  local test_name="$1"

  set +e
  "$test_name"
  local status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    return 0
  fi
}

run_test test_merge_integration_into_work_is_denied
run_test test_merge_production_into_work_is_allowed
run_test test_rebase_onto_integration_is_denied
run_test test_pull_integration_is_denied
run_test test_new_branch_from_integration_is_denied
run_test test_compound_command_is_inspected
run_test test_commit_message_mentioning_dev_is_allowed
run_test test_push_integration_to_production_is_denied
run_test test_merge_integration_while_on_it_is_allowed
run_test test_enforcement_ask_downgrades_decision
run_test test_enforcement_warn_allows_with_message
run_test test_declared_promotion_is_allowed
run_test test_undeclared_promotion_is_denied
run_test test_cherry_pick_of_integration_only_commit_asks
run_test test_non_git_command_is_ignored
run_test test_disable_flag_skips_guard

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
