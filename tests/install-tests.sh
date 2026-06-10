#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/install.sh"

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

test_explicit_target_installs_skill() {
  local name="explicit target installs the skill"
  local target output
  target="$(mktemp -d)"

  output="$("$SCRIPT" --target "$target" 2>&1)" || {
    fail "$name" "installer exited non-zero: $output"
    rm -rf "$target"
    return
  }

  if [ -f "$target/git-integration-branch-guard/SKILL.md" ] &&
    [ -f "$target/git-integration-branch-guard/scripts/audit-branch-flow.sh" ] &&
    grep -Fq 'installed' <<<"$output"; then
    pass "$name"
  else
    fail "$name" "expected skill files in $target, got: $output"
  fi
  rm -rf "$target"
}

test_reinstall_is_idempotent() {
  local name="reinstalling the same version reports up to date"
  local target output
  target="$(mktemp -d)"

  "$SCRIPT" --target "$target" >/dev/null 2>&1
  output="$("$SCRIPT" --target "$target" 2>&1)" || {
    fail "$name" "second install exited non-zero: $output"
    rm -rf "$target"
    return
  }

  if grep -Fq 'up to date' <<<"$output"; then
    pass "$name"
  else
    fail "$name" "expected up-to-date notice, got: $output"
  fi
  rm -rf "$target"
}

test_stale_copy_requires_update_flag() {
  local name="stale copy is skipped without --update and replaced with it"
  local target output
  target="$(mktemp -d)"

  "$SCRIPT" --target "$target" >/dev/null 2>&1
  printf '0.0.1' > "$target/git-integration-branch-guard/.installed-version"

  output="$("$SCRIPT" --target "$target" 2>&1)"
  if ! grep -Fq 'rerun with --update' <<<"$output"; then
    fail "$name" "expected skip notice, got: $output"
    rm -rf "$target"
    return
  fi

  output="$("$SCRIPT" --target "$target" --update 2>&1)"
  if grep -Fq 'installed' <<<"$output" &&
    ! grep -Fq '0.0.1' <<<"$(cat "$target/git-integration-branch-guard/.installed-version")"; then
    pass "$name"
  else
    fail "$name" "expected updated install, got: $output"
  fi
  rm -rf "$target"
}

test_list_detects_runtimes_in_fake_home() {
  local name="--list reports runtimes found in HOME"
  local fake_home output
  fake_home="$(mktemp -d)"
  mkdir -p "$fake_home/.claude" "$fake_home/.codex"

  output="$(HOME="$fake_home" CODEX_HOME="" "$SCRIPT" --list 2>&1)" || {
    fail "$name" "--list exited non-zero: $output"
    rm -rf "$fake_home"
    return
  }

  if grep -Fq "$fake_home/.claude/skills" <<<"$output" &&
    grep -Fq "$fake_home/.codex/skills" <<<"$output"; then
    pass "$name"
  else
    fail "$name" "expected both runtimes listed, got: $output"
  fi
  rm -rf "$fake_home"
}

test_no_runtime_detected_fails_with_hint() {
  local name="no detected runtime exits 2 with a hint"
  local fake_home status output
  fake_home="$(mktemp -d)"

  set +e
  output="$(HOME="$fake_home" CODEX_HOME="" "$SCRIPT" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 2 ] && grep -Fq -- '--target' <<<"$output"; then
    pass "$name"
  else
    fail "$name" "expected exit 2 with --target hint, got status $status: $output"
  fi
  rm -rf "$fake_home"
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

run_test test_explicit_target_installs_skill
run_test test_reinstall_is_idempotent
run_test test_stale_copy_requires_update_flag
run_test test_list_detects_runtimes_in_fake_home
run_test test_no_runtime_detected_fails_with_hint

printf '\n%d passed, %d failed\n' "$pass_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
