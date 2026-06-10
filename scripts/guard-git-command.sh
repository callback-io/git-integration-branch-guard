#!/usr/bin/env bash
# PreToolUse hook for Claude Code. Reads the hook payload from stdin, inspects
# the Bash command for git operations that would pull a shared validation
# branch into a work or production branch, and blocks them according to the
# enforcement level in .branch-guard.json.
#
# The hook fails open by design: when the payload cannot be parsed, the
# directory is not a git work tree, or no JSON parser is available, it exits 0
# without output so normal work is never blocked by guard infrastructure.
set -uo pipefail

if [ "${BRANCH_GUARD_DISABLE:-0}" = "1" ]; then
  exit 0
fi

DEFAULT_PRODUCTION="main master trunk prod production release"
DEFAULT_INTEGRATION="dev develop test qa uat stage staging preprod integration"

input="$(cat)" || exit 0

json_string_field() {
  local path="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r "$path // empty" <<<"$input" 2>/dev/null
    return
  fi

  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin=python3
  elif command -v python >/dev/null 2>&1; then
    python_bin=python
  else
    return 0
  fi

  "$python_bin" -c '
import json
import sys

path = sys.argv[1].lstrip(".").split(".")
try:
    value = json.loads(sys.stdin.read() or "{}")
except ValueError:
    sys.exit(0)
for part in path:
    if not isinstance(value, dict) or part not in value:
        sys.exit(0)
    value = value[part]
if isinstance(value, str):
    sys.stdout.write(value)
' "$path" <<<"$input" 2>/dev/null
}

command_text="$(json_string_field .tool_input.command)"
case "$command_text" in
  *git*) ;;
  *) exit 0 ;;
esac

work_dir="$(json_string_field .cwd)"
if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
  cd "$work_dir" 2>/dev/null || exit 0
fi

# --- configuration -----------------------------------------------------------

json_array_values() {
  local key="$1"
  local file="$2"

  tr '\n' ' ' < "$file" |
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' |
    tr ',' '\n' |
    awk -F'"' 'NF >= 3 { print $2 }'
}

json_scalar_value() {
  local key="$1"
  local file="$2"

  tr '\n' ' ' < "$file" |
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

production_patterns="$DEFAULT_PRODUCTION"
integration_patterns="$DEFAULT_INTEGRATION"
promotion_paths=""
enforcement="deny"

load_config() {
  local toplevel config_file values

  toplevel="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  config_file="$toplevel/.branch-guard.json"
  [ -f "$config_file" ] || return 0

  values="$(json_array_values production "$config_file" | tr '\n' ' ')"
  [ -n "${values// /}" ] && production_patterns="$values"

  values="$(json_array_values integration "$config_file" | tr '\n' ' ')"
  [ -n "${values// /}" ] && integration_patterns="$values"

  promotion_paths="$(json_array_values promotionPaths "$config_file" | tr '\n' ' ')"

  values="$(json_scalar_value enforcement "$config_file")"
  case "$values" in
    deny|ask|warn) enforcement="$values" ;;
  esac
}

# --- classification ----------------------------------------------------------

matches_any() {
  local name="$1"
  local patterns="$2"
  local pattern

  for pattern in $patterns; do
    # shellcheck disable=SC2254
    case "$name" in
      $pattern) return 0 ;;
    esac
  done
  return 1
}

normalize_ref() {
  local ref="$1"

  ref="${ref%%@\{*}"
  ref="${ref%%[~^]*}"
  case "$ref" in
    origin/*) ref="${ref#origin/}" ;;
    upstream/*) ref="${ref#upstream/}" ;;
  esac
  printf '%s' "$ref"
}

# Prints integration, production, or work.
classify_ref() {
  local name
  name="$(normalize_ref "$1")"

  if matches_any "$name" "$integration_patterns"; then
    printf 'integration'
  elif matches_any "$name" "$production_patterns"; then
    printf 'production'
  else
    printf 'work'
  fi
}

promotion_allowed() {
  local source="$1"
  local target="$2"

  matches_any "$source->$target" "$promotion_paths"
}

# --- decision output ---------------------------------------------------------

sanitize_text() {
  # shellcheck disable=SC1003
  printf '%s' "$1" | tr -d '"\\' | tr '\n\t' '  '
}

emit_decision() {
  local decision="$1"
  local reason
  reason="$(sanitize_text "$2")"

  if [ "$decision" = "warn" ]; then
    printf '{"systemMessage": "Branch guard warning: %s", "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "%s"}}\n' \
      "$reason" "$reason"
  else
    printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "%s", "permissionDecisionReason": "%s"}}\n' \
      "$decision" "$reason"
  fi
  exit 0
}

report_violation() {
  local reason="$1"

  case "$enforcement" in
    ask) emit_decision ask "$reason" ;;
    warn) emit_decision warn "$reason" ;;
    *) emit_decision deny "$reason" ;;
  esac
}

report_suspicion() {
  local reason="$1"

  case "$enforcement" in
    warn) emit_decision warn "$reason" ;;
    *) emit_decision ask "$reason" ;;
  esac
}

git_in_ctx() {
  local ctx="$1"
  shift

  if [ -n "$ctx" ]; then
    git -C "$ctx" "$@"
  else
    git "$@"
  fi
}

current_branch_for() {
  git_in_ctx "$1" branch --show-current 2>/dev/null
}

# --- flow checks -------------------------------------------------------------

flow_message() {
  local action="$1"
  local source="$2"
  local target="$3"
  local target_role="$4"

  if [ "$target_role" = "production" ]; then
    printf '%s from shared validation branch %s into production branch %s would release a mixed pool of in-flight work. Release reviewed work branches individually instead.' \
      "$action" "$source" "$target"
  else
    printf '%s from shared validation branch %s into %s would absorb unrelated in-flight work. Shared validation branches are one-way collection pools; sync from the production branch instead.' \
      "$action" "$source" "$target"
  fi
}

# Called once per incoming source ref for merge/rebase/pull/reset flows.
check_incoming_source() {
  local action="$1"
  local source="$2"
  local ctx="$3"
  local source_role target target_role source_name target_name

  source_role="$(classify_ref "$source")"
  [ "$source_role" = "integration" ] || return 0

  target="$(current_branch_for "$ctx")"
  [ -n "$target" ] || target="(detached HEAD)"
  target_role="$(classify_ref "$target")"
  source_name="$(normalize_ref "$source")"
  target_name="$(normalize_ref "$target")"

  if [ "$target_role" = "integration" ]; then
    if [ "$source_name" = "$target_name" ]; then
      return 0
    fi
    if promotion_allowed "$source_name" "$target_name"; then
      return 0
    fi
    report_violation "Promotion $source_name->$target_name is not declared in promotionPaths of .branch-guard.json. Declare it there if this environment promotion is intentional."
  fi

  report_violation "$(flow_message "$action" "$source" "$target" "$target_role")"
}

check_new_branch_source() {
  local start_point="$1"
  local new_branch="$2"

  [ "$(classify_ref "$start_point")" = "integration" ] || return 0
  report_violation "Creating branch $new_branch from shared validation branch $start_point would seed it with unreleased in-flight work. Create work branches from the production branch."
}

resolve_existing_ref() {
  local ctx="$1"
  local name="$2"
  local candidate

  for candidate in "$name" "origin/$name"; do
    if git_in_ctx "$ctx" rev-parse --verify --quiet "$candidate" >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

check_cherry_pick_commit() {
  local token="$1"
  local ctx="$2"
  local pattern ref commit

  if [ "$(classify_ref "$token")" = "integration" ]; then
    check_incoming_source "Cherry-picking" "$token" "$ctx"
    return 0
  fi

  commit="$(git_in_ctx "$ctx" rev-parse --verify --quiet "$token^{commit}" 2>/dev/null)" || return 0

  for pattern in $integration_patterns; do
    case "$pattern" in
      *[\*\?\[]*) continue ;;
    esac
    ref="$(resolve_existing_ref "$ctx" "$pattern")" || continue
    if git_in_ctx "$ctx" merge-base --is-ancestor "$commit" "$ref" 2>/dev/null; then
      local production_ref=""
      local production_name
      for production_name in $production_patterns; do
        case "$production_name" in
          *[\*\?\[]*) continue ;;
        esac
        production_ref="$(resolve_existing_ref "$ctx" "$production_name")" && break
        production_ref=""
      done
      if [ -n "$production_ref" ] && git_in_ctx "$ctx" merge-base --is-ancestor "$commit" "$production_ref" 2>/dev/null; then
        continue
      fi
      report_suspicion "Commit $token is reachable from shared validation branch $ref but not from production. It may carry unreleased in-flight work; confirm its origin before cherry-picking."
    fi
  done
}

# --- git command parsing -----------------------------------------------------

# Receives one already-tokenized command segment as positional parameters.
inspect_git_segment() {
  local ctx=""
  local ctx_candidate

  # Skip env assignments and benign wrappers before the git executable.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      env|command|exec|nohup|sudo) shift ;;
      git|*/git) shift; break ;;
      *) return 0 ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0

  # Global git options that may appear before the subcommand.
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C|-c|--exec-path|--namespace)
        ctx_candidate="$1"
        shift
        if [ "$ctx_candidate" = "-C" ] && [ "$#" -gt 0 ]; then
          ctx="$1"
        fi
        [ "$#" -gt 0 ] && shift
        ;;
      --git-dir=*|--work-tree=*|--exec-path=*|--namespace=*|-p|--paginate|--no-pager|--no-replace-objects|--bare|--literal-pathspecs)
        shift
        ;;
      -*)
        return 0
        ;;
      *)
        break
        ;;
    esac
  done
  [ "$#" -gt 0 ] || return 0

  local subcommand="$1"
  shift

  case "$subcommand" in
    merge)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -m|-F|-S|-X|-s|--message|--file|--strategy|--strategy-option|--cleanup|--gpg-sign|--into-name)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            check_incoming_source "Merging" "$1" "$ctx"
            shift ;;
        esac
      done
      ;;
    rebase)
      local saw_upstream=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --onto)
            shift
            if [ "$#" -gt 0 ]; then
              check_incoming_source "Rebasing onto" "$1" "$ctx"
              shift
            fi
            ;;
          -X|-s|-x|-S|-C|--exec|--strategy|--strategy-option|--whitespace|--gpg-sign|--empty)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            if [ "$saw_upstream" -eq 0 ]; then
              check_incoming_source "Rebasing onto" "$1" "$ctx"
              saw_upstream=1
            fi
            shift ;;
        esac
      done
      ;;
    pull)
      local saw_remote=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -X|-s|-S|--strategy|--strategy-option|--cleanup|--gpg-sign)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            if [ "$saw_remote" -eq 0 ]; then
              saw_remote=1
            else
              check_incoming_source "Pulling" "${1%%:*}" "$ctx"
            fi
            shift ;;
        esac
      done
      ;;
    cherry-pick)
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -m|-X|-s|-S|--mainline|--strategy|--strategy-option|--gpg-sign)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            check_cherry_pick_commit "$1" "$ctx"
            shift ;;
        esac
      done
      ;;
    reset)
      local hard_mode=0
      local first_ref=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --hard|--merge|--keep) hard_mode=1; shift ;;
          --) break ;;
          -*) shift ;;
          *)
            [ -n "$first_ref" ] || first_ref="$1"
            shift ;;
        esac
      done
      if [ "$hard_mode" -eq 1 ] && [ -n "$first_ref" ]; then
        check_incoming_source "Resetting" "$first_ref" "$ctx"
      fi
      ;;
    switch|checkout)
      local new_branch=""
      local start_point=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -c|-C|-b|-B|--orphan)
            shift
            if [ "$#" -gt 0 ]; then
              new_branch="$1"
              shift
            fi
            ;;
          --) break ;;
          -*) shift ;;
          *)
            if [ -n "$new_branch" ] && [ -z "$start_point" ]; then
              start_point="$1"
            fi
            shift ;;
        esac
      done
      if [ -n "$new_branch" ] && [ -n "$start_point" ]; then
        check_new_branch_source "$start_point" "$new_branch"
      fi
      ;;
    branch)
      local positional_count=0
      local new_branch=""
      local start_point=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -u|--set-upstream-to|-t|--track|--sort|--contains|--no-contains|--merged|--no-merged|--points-at|--format)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            positional_count=$((positional_count + 1))
            if [ "$positional_count" -eq 1 ]; then
              new_branch="$1"
            elif [ "$positional_count" -eq 2 ]; then
              start_point="$1"
            fi
            shift ;;
        esac
      done
      if [ -n "$new_branch" ] && [ -n "$start_point" ]; then
        check_new_branch_source "$start_point" "$new_branch"
      fi
      ;;
    push)
      local saw_remote=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          -o|--push-option|--repo|--receive-pack|--exec)
            shift; [ "$#" -gt 0 ] && shift ;;
          --) break ;;
          -*) shift ;;
          *)
            if [ "$saw_remote" -eq 0 ]; then
              saw_remote=1
            else
              case "$1" in
                *:*)
                  local push_source="${1%%:*}"
                  local push_target="${1#*:}"
                  push_target="${push_target#refs/heads/}"
                  if [ "$(classify_ref "$push_source")" = "integration" ] &&
                    [ "$(classify_ref "$push_target")" = "production" ]; then
                    report_violation "Pushing shared validation branch $push_source onto production branch $push_target would release a mixed pool of in-flight work. Release reviewed work branches individually instead."
                  fi
                  ;;
              esac
            fi
            shift ;;
        esac
      done
      ;;
  esac
}

# Removes quoted strings that contain whitespace (commit messages and similar
# free text must not be parsed as refs), then drops remaining quote characters
# so simple quoted branch names stay visible.
strip_quoted_text() {
  sed -e "s/'[^']*[[:space:]][^']*'/ /g" \
    -e 's/"[^"]*[[:space:]][^"]*"/ /g' \
    -e "s/'//g" \
    -e 's/"//g'
}

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
load_config

while IFS= read -r segment; do
  case "$segment" in
    *git*) ;;
    *) continue ;;
  esac
  segment="$(printf '%s' "$segment" | strip_quoted_text)"
  # shellcheck disable=SC2086
  inspect_git_segment $segment
done <<EOF
$(printf '%s\n' "$command_text" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')
EOF

exit 0
