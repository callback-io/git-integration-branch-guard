#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/skills/git-integration-branch-guard/scripts/audit-branch-flow.sh"

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

assert_status() {
  local name="$1"
  local actual="$2"
  local expected="$3"

  if [ "$actual" -ne "$expected" ]; then
    fail "$name" "expected exit status $expected, got $actual"
    return 1
  fi
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"

  if ! grep -Fq "$needle" <<<"$haystack"; then
    fail "$name" "expected output to contain: $needle"
    return 1
  fi
}

with_git_repo() {
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
    "$@"
  )
  local status=$?

  rm -rf "$repo"
  return "$status"
}

run_script() {
  local output_file="$1"
  shift

  set +e
  "$SCRIPT" "$@" >"$output_file" 2>&1
  local status=$?
  set -e
  printf '%s' "$status"
}

scenario_clean_branch() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c feature/clean >/dev/null 2>&1
  printf 'clean\n' >> app.txt
  git commit -am 'feat: clean work' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_clean_branch_passes() {
  local name="clean branch exits 0"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_clean_branch "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
}

scenario_default_merge_message() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c dev >/dev/null 2>&1
  printf 'dev\n' > dev.txt
  git add dev.txt
  git commit -m 'feat: shared dev change' >/dev/null
  git switch -c feature/contaminated main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git merge --no-ff dev -m "Merge branch 'dev' into feature/contaminated" >/dev/null

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_default_merge_message_is_detected() {
  local name="default integration merge exits 1"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_default_merge_message "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 1 || return
  assert_contains "$name" "$output" "Result: possible shared-validation branch contamination detected." || return
  pass "$name"
}

test_missing_option_value_exits_2() {
  local name="missing option value exits 2 with usage"
  local output_file
  local status output

  output_file="$(mktemp)"
  status="$(run_script "$output_file" --production)"
  output="$(cat "$output_file")"
  rm -f "$output_file"

  assert_status "$name" "$status" 2 || return
  assert_contains "$name" "$output" "Missing value for --production." || return
  assert_contains "$name" "$output" "Usage:" || return
  pass "$name"
}

scenario_literal_integration_name() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c feature/literal >/dev/null 2>&1
  printf 'note\n' > note.txt
  git add note.txt
  git commit -m 'docs: mention devXv1 in text' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration "dev.v1" >"$output_file.status"
}

test_integration_name_is_matched_as_literal_text() {
  local name="integration branch names are literal grep patterns"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_literal_integration_name "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
}

scenario_substring_subject() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c feature/wording >/dev/null 2>&1
  printf 'note\n' > note.txt
  git add note.txt
  git commit -m 'docs: update developer guide' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_substring_inside_word_is_not_flagged() {
  local name="branch name inside a longer word exits 0"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_substring_subject "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
}

scenario_missing_integration_ref() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c feature/no-ref >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration nosuchbranch >"$output_file.status"
}

test_missing_integration_ref_is_reported() {
  local name="missing integration ref prints a skip notice"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_missing_integration_ref "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "note: no local ref found for nosuchbranch" || return
  assert_contains "$name" "$output" "skipped: none of the shared validation branch refs were found locally" || return
  pass "$name"
}

scenario_decorated_log() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git config log.decorate full
  git switch -c feature/decor >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration decor >"$output_file.status"
}

test_log_decorations_do_not_trigger_matches() {
  local name="log decorations from user config exit 0"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_decorated_log "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
}

scenario_custom_merge_message() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c dev >/dev/null 2>&1
  printf 'shared\n' > shared.txt
  git add shared.txt
  git commit -m 'feat: shared validation change' >/dev/null
  git switch -c feature/custom-message main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git merge --no-ff dev -m 'merge validation pool' >/dev/null

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_custom_merge_message_is_detected_by_graph() {
  local name="custom integration merge message exits 1"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_custom_merge_message "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 1 || return
  assert_contains "$name" "$output" "Merge commits whose non-first parent is reachable from shared validation branches:" || return
  assert_contains "$name" "$output" "Result: possible shared-validation branch contamination detected." || return
  pass "$name"
}

scenario_config_file_roles() {
  local output_file="$1"

  cat > .branch-guard.json <<'JSON'
{
  "production": ["main"],
  "integration": ["dev"],
  "enforcement": "deny"
}
JSON
  git switch -c dev >/dev/null 2>&1
  printf 'dev\n' > dev.txt
  git add dev.txt
  git commit -m 'feat: shared dev change' >/dev/null
  git switch -c feature/from-config main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git merge --no-ff dev -m 'absorb validation pool' >/dev/null

  run_script "$output_file" >"$output_file.status"
}

test_config_file_supplies_roles() {
  local name="config file supplies branch roles without arguments"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_config_file_roles "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 1 || return
  assert_contains "$name" "$output" "Branch roles loaded from .branch-guard.json" || return
  assert_contains "$name" "$output" "Result: possible shared-validation branch contamination detected." || return
  pass "$name"
}

scenario_args_override_config() {
  local output_file="$1"
  local main_ref

  cat > .branch-guard.json <<'JSON'
{
  "production": ["main"],
  "integration": ["staging"]
}
JSON
  main_ref="$(git rev-parse main)"
  git switch -c dev >/dev/null 2>&1
  printf 'dev\n' > dev.txt
  git add dev.txt
  git commit -m 'feat: shared dev change' >/dev/null
  git switch -c feature/override main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git merge --no-ff dev -m "Merge branch 'dev' into feature/override" >/dev/null

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_arguments_override_config_file() {
  local name="command-line options override the config file"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_args_override_config "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 1 || return
  assert_contains "$name" "$output" "  - dev" || return
  assert_contains "$name" "$output" "Result: possible shared-validation branch contamination detected." || return
  pass "$name"
}

scenario_config_without_roles() {
  local output_file="$1"

  cat > .branch-guard.json <<'JSON'
{
  "enforcement": "warn"
}
JSON

  run_script "$output_file" >"$output_file.status"
}

test_config_without_roles_still_requires_arguments() {
  local name="config file without branch roles exits 2"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_config_without_roles "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 2 || return
  assert_contains "$name" "$output" "Missing required arguments." || return
  assert_contains "$name" "$output" "No usable branch roles found in" || return
  pass "$name"
}

scenario_cherry_pick_reworded() {
  local output_file="$1"
  local main_ref
  local extra_arg="${2-}"

  main_ref="$(git rev-parse main)"
  git switch -c dev >/dev/null 2>&1
  printf 'dev\n' > dev.txt
  git add dev.txt
  git commit -m 'feat: shared dev change' >/dev/null
  git switch -c feature/picked main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git cherry-pick dev >/dev/null 2>&1
  git commit --amend -m 'feat: innocent looking change' >/dev/null

  if [ -n "$extra_arg" ]; then
    run_script "$output_file" --production "$main_ref" --integration dev "$extra_arg" >"$output_file.status"
  else
    run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
  fi
}

test_reworded_cherry_pick_is_reported_as_advisory() {
  local name="reworded cherry-pick from dev is reported as advisory"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_cherry_pick_reworded "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "same patch as" || return
  assert_contains "$name" "$output" "Result: advisory patch-id matches found" || return
  pass "$name"
}

scenario_cherry_pick_reworded_strict() {
  scenario_cherry_pick_reworded "$1" --strict
}

test_strict_mode_fails_on_advisory_matches() {
  local name="--strict fails on advisory patch-id matches"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_cherry_pick_reworded_strict "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 1 || return
  assert_contains "$name" "$output" "Result: advisory patch-id matches found" || return
  pass "$name"
}

scenario_cherry_pick_reworded_disabled() {
  scenario_cherry_pick_reworded "$1" --no-check-patch-id
}

test_patch_id_check_can_be_disabled() {
  local name="--no-check-patch-id skips the patch-id section"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_cherry_pick_reworded_disabled "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  if grep -Fq "same patch as" <<<"$output"; then
    fail "$name" "patch-id section should be skipped"
    return
  fi
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
}

scenario_own_commit_in_validation_pool() {
  local output_file="$1"
  local main_ref

  main_ref="$(git rev-parse main)"
  git switch -c dev >/dev/null 2>&1
  git switch -c feature/own main >/dev/null 2>&1
  printf 'work\n' > work.txt
  git add work.txt
  git commit -m 'feat: scoped work' >/dev/null
  git switch dev >/dev/null 2>&1
  git merge --no-ff feature/own -m 'collect for validation' >/dev/null
  git switch feature/own >/dev/null 2>&1

  run_script "$output_file" --production "$main_ref" --integration dev >"$output_file.status"
}

test_own_commits_in_validation_pool_are_not_flagged() {
  local name="own commits merged into dev are not flagged by patch-id"
  local output_file
  output_file="$(mktemp)"
  with_git_repo scenario_own_commit_in_validation_pool "$output_file"

  local status output
  status="$(cat "$output_file.status")"
  output="$(cat "$output_file")"
  rm -f "$output_file" "$output_file.status"

  assert_status "$name" "$status" 0 || return
  assert_contains "$name" "$output" "Result: no obvious shared-validation branch contamination found." || return
  pass "$name"
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

run_test test_clean_branch_passes
run_test test_default_merge_message_is_detected
run_test test_missing_option_value_exits_2
run_test test_integration_name_is_matched_as_literal_text
run_test test_substring_inside_word_is_not_flagged
run_test test_missing_integration_ref_is_reported
run_test test_log_decorations_do_not_trigger_matches
run_test test_custom_merge_message_is_detected_by_graph
run_test test_config_file_supplies_roles
run_test test_arguments_override_config_file
run_test test_config_without_roles_still_requires_arguments
run_test test_reworded_cherry_pick_is_reported_as_advisory
run_test test_strict_mode_fails_on_advisory_matches
run_test test_patch_id_check_can_be_disabled
run_test test_own_commits_in_validation_pool_are_not_flagged

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
