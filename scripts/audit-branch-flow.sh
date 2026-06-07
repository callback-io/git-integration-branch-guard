#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  audit-branch-flow.sh --production <base-ref> --integration <branch-name-or-ref> [--integration <branch-name-or-ref> ...] [--head <ref>]

Examples:
  audit-branch-flow.sh --production origin/main --integration dev
  audit-branch-flow.sh --production origin/main --integration dev --integration test --integration uat
  audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/staging --head feature/example

Purpose:
  Audit the commits between the production base and a work branch for signs
  that shared validation branches were merged, pulled, rebased, or cherry-picked
  into the work branch before release.
USAGE
}

require_option_value() {
  local option="$1"
  local value="${2:-}"

  case "$value" in
    ""|-*)
      echo "Missing value for $option." >&2
      usage >&2
      exit 2
      ;;
  esac

  printf '%s' "$value"
}

short_integration_name() {
  local integration="$1"
  printf '%s' "${integration#origin/}"
}

resolve_integration_ref() {
  local integration="$1"
  local integration_short
  integration_short="$(short_integration_name "$integration")"

  if git rev-parse --verify "$integration" >/dev/null 2>&1; then
    printf '%s' "$integration"
    return 0
  fi

  if [ "$integration" != "$integration_short" ] && git rev-parse --verify "$integration_short" >/dev/null 2>&1; then
    printf '%s' "$integration_short"
    return 0
  fi

  if git rev-parse --verify "origin/$integration_short" >/dev/null 2>&1; then
    printf '%s' "origin/$integration_short"
    return 0
  fi

  return 1
}

log_matches_fixed() {
  local range="$1"
  local pattern="$2"
  local merge_only="$3"

  if [ "$merge_only" = "yes" ]; then
    git log --no-decorate --no-show-signature --merges --oneline "$range" | grep -Fiw -- "$pattern" || true
  else
    git log --no-decorate --no-show-signature --oneline "$range" | grep -Fiw -- "$pattern" || true
  fi
}

integration_hits() {
  local range="$1"
  local integration="$2"
  local merge_only="$3"
  local integration_short
  integration_short="$(short_integration_name "$integration")"

  if [ "$integration" = "$integration_short" ]; then
    log_matches_fixed "$range" "$integration" "$merge_only"
  else
    {
      log_matches_fixed "$range" "$integration" "$merge_only"
      log_matches_fixed "$range" "$integration_short" "$merge_only"
    } | awk '!seen[$0]++'
  fi
}

report_mention_section() {
  local header="$1"
  local merge_only="$2"
  local section_found=0
  local integration hits

  echo "$header"
  for integration in "${integrations[@]}"; do
    hits="$(integration_hits "$range" "$integration" "$merge_only")"
    if [ -n "$hits" ]; then
      echo "$hits"
      found=1
      section_found=1
    fi
  done
  if [ "$section_found" -eq 0 ]; then
    echo "  none found"
  fi
  echo
}

production=""
integrations=()
head_ref="HEAD"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --production)
      production="$(require_option_value "$1" "${2-}")"
      shift 2
      ;;
    --integration)
      integrations+=("$(require_option_value "$1" "${2-}")")
      shift 2
      ;;
    --head)
      head_ref="$(require_option_value "$1" "${2-}")"
      shift 2
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

if [ -z "$production" ] || [ "${#integrations[@]}" -eq 0 ]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a Git work tree." >&2
  exit 2
fi

if ! git rev-parse --verify "$production" >/dev/null 2>&1; then
  echo "Production ref not found: $production" >&2
  exit 2
fi

if ! git rev-parse --verify "$head_ref" >/dev/null 2>&1; then
  echo "Head ref not found: $head_ref" >&2
  exit 2
fi

range="$production..$head_ref"

echo "Auditing range: $range"
echo "Shared validation branches:"
for integration in "${integrations[@]}"; do
  integration_short="$(short_integration_name "$integration")"
  if [ "$integration" = "$integration_short" ]; then
    echo "  - $integration"
  else
    echo "  - $integration ($integration_short)"
  fi
done
echo

found=0

report_mention_section "Merge commits that mention shared validation branches:" yes

echo "Merge commits whose non-first parent is reachable from shared validation branches:"
graph_found=0
resolved_refs=()
for integration in "${integrations[@]}"; do
  if integration_ref="$(resolve_integration_ref "$integration")"; then
    resolved_refs+=("$integration_ref")
  else
    echo "  note: no local ref found for $integration; merge-graph check skipped for it"
  fi
done
if [ "${#resolved_refs[@]}" -gt 0 ]; then
  while IFS= read -r merge_commit; do
    [ -n "$merge_commit" ] || continue

    parents="$(git rev-list --parents -n 1 "$merge_commit")"
    # shellcheck disable=SC2086
    set -- $parents
    [ "$#" -gt 2 ] || continue
    shift 2

    for parent in "$@"; do
      for integration_ref in "${resolved_refs[@]}"; do
        if git merge-base --is-ancestor "$parent" "$integration_ref" &&
          ! git merge-base --is-ancestor "$parent" "$production"; then
          echo "  $(git log -1 --no-decorate --no-show-signature --oneline "$merge_commit")"
          echo "    parent $(git rev-parse --short "$parent") is reachable from $integration_ref"
          found=1
          graph_found=1
          break 2
        fi
      done
    done
  done < <(git rev-list --merges "$range")
fi
if [ "${#resolved_refs[@]}" -eq 0 ]; then
  echo "  skipped: none of the shared validation branch refs were found locally"
elif [ "$graph_found" -eq 0 ]; then
  echo "  none found"
fi
echo

report_mention_section "Commit subjects that mention shared validation branches:" no

echo "Commits in release range:"
git log --no-show-signature --no-merges --format='  %h %an %s' "$range" || true
echo

if [ "$found" -ne 0 ]; then
  cat <<'WARNING'
Result: possible shared-validation branch contamination detected.

Review the commits above before releasing. If the work branch absorbed a shared
validation branch, releasing it may ship unrelated in-flight work. Prefer a
clean branch from production unless every included commit is intentionally in
scope for this release.
WARNING
  exit 1
fi

echo "Result: no obvious shared-validation branch contamination found."
