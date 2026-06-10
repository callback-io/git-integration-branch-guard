#!/usr/bin/env bash
# Installs the git-integration-branch-guard skill into agent runtime skill
# directories. The installer copies the skill only; it never edits agent
# settings, never registers hooks, and never touches files outside the chosen
# skills directories. Hook enforcement is available separately through the
# Claude Code plugin install flow, which has its own user consent step.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_NAME="git-integration-branch-guard"
SKILL_SOURCE="$ROOT_DIR/skills/$SKILL_NAME"
VERSION_MARKER=".installed-version"

usage() {
  cat <<'USAGE'
Usage:
  install.sh [--list] [--update] [--target <skills-dir>] [--project]

Without options, the installer detects agent runtimes in the home directory
and copies the skill into each runtime's skills directory:

  ~/.claude/skills    Claude Code
  ~/.codex/skills     OpenAI Codex CLI (honors $CODEX_HOME)
  ~/.gemini/skills    Gemini CLI
  ~/.qwen/skills      Qwen Code

Options:
  --list      Show the detected install targets and versions, change nothing.
  --update    Overwrite targets that already contain an older or unknown copy.
  --target    Install into one explicit skills directory instead of detecting.
  --project   Install into .claude/skills of the current Git repository.

The installer copies the skill files only. It never modifies agent settings
or hook configuration; install the Claude Code plugin if you want the
PreToolUse command guard as well.
USAGE
}

skill_version() {
  tr '\n' ' ' < "$ROOT_DIR/.claude-plugin/plugin.json" |
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

installed_version() {
  local target="$1"

  if [ -f "$target/$VERSION_MARKER" ]; then
    cat "$target/$VERSION_MARKER"
  else
    printf 'unknown'
  fi
}

detect_targets() {
  local home_dir="${HOME:-}"
  local codex_home="${CODEX_HOME:-$home_dir/.codex}"
  local runtime_root

  for runtime_root in "$home_dir/.claude" "$codex_home" "$home_dir/.gemini" "$home_dir/.qwen"; do
    [ -n "$runtime_root" ] && [ -d "$runtime_root" ] || continue
    printf '%s/skills\n' "$runtime_root"
  done
}

install_into() {
  local skills_dir="$1"
  local update="$2"
  local target="$skills_dir/$SKILL_NAME"
  local current version

  version="$(skill_version)"

  if [ -d "$target" ]; then
    current="$(installed_version "$target")"
    if [ "$current" = "$version" ]; then
      printf 'up to date  %s (%s)\n' "$target" "$version"
      return 0
    fi
    if [ "$update" -ne 1 ]; then
      printf 'skipped     %s (installed: %s, available: %s; rerun with --update)\n' \
        "$target" "$current" "$version"
      return 0
    fi
    rm -rf "$target"
  fi

  mkdir -p "$target"
  cp -R "$SKILL_SOURCE/." "$target/"
  printf '%s' "$version" > "$target/$VERSION_MARKER"
  printf 'installed   %s (%s)\n' "$target" "$version"
}

list_targets() {
  local skills_dir target version found=0

  version="$(skill_version)"
  printf 'available version: %s\n' "$version"
  while IFS= read -r skills_dir; do
    [ -n "$skills_dir" ] || continue
    found=1
    target="$skills_dir/$SKILL_NAME"
    if [ -d "$target" ]; then
      printf 'target %s (installed: %s)\n' "$skills_dir" "$(installed_version "$target")"
    else
      printf 'target %s (not installed)\n' "$skills_dir"
    fi
  done <<EOF
$(detect_targets)
EOF
  if [ "$found" -eq 0 ]; then
    echo 'no agent runtimes detected; use --target <skills-dir>'
  fi
}

mode_list=0
update=0
explicit_target=""
project=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      mode_list=1
      shift
      ;;
    --update)
      update=1
      shift
      ;;
    --target)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Missing value for --target." >&2
        usage >&2
        exit 2
      fi
      explicit_target="$2"
      shift 2
      ;;
    --project)
      project=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$SKILL_SOURCE" ]; then
  echo "Skill source not found: $SKILL_SOURCE" >&2
  exit 2
fi

if [ "$mode_list" -eq 1 ]; then
  list_targets
  exit 0
fi

if [ -n "$explicit_target" ]; then
  install_into "$explicit_target" "$update"
  exit 0
fi

if [ "$project" -eq 1 ]; then
  if ! toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "Not inside a Git work tree; --project needs one." >&2
    exit 2
  fi
  install_into "$toplevel/.claude/skills" "$update"
  exit 0
fi

installed_any=0
while IFS= read -r skills_dir; do
  [ -n "$skills_dir" ] || continue
  installed_any=1
  install_into "$skills_dir" "$update"
done <<EOF
$(detect_targets)
EOF

if [ "$installed_any" -eq 0 ]; then
  echo 'no agent runtimes detected; use --target <skills-dir>' >&2
  exit 2
fi
