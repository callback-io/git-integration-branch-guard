#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  audit-branch-flow.sh [--production <base-ref>] [--integration <branch-name-or-ref> ...] [--head <ref>] [--strict] [--no-check-patch-id]

Examples:
  audit-branch-flow.sh --production origin/main --integration dev
  audit-branch-flow.sh --production origin/main --integration dev --integration test --integration uat
  audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/staging --head feature/example
  audit-branch-flow.sh    # roles read from .branch-guard.json at the repository root

Options:
  --strict             Also fail (exit 1) when only advisory patch-id matches
                       are found.
  --no-check-patch-id  Skip the patch-id comparison against shared validation
                       branches.

Configuration:
  When the repository root contains .branch-guard.json, its "production" and
  "integration" arrays are used as defaults. Command-line options always
  override the configuration file. Without a configuration file, --production
  and at least one --integration are required.

Purpose:
  Audit the commits between the production base and a work branch for signs
  that shared validation branches were merged, pulled, rebased, or cherry-picked
  into the work branch before release.
USAGE
}

# Minimal extraction helpers for the flat .branch-guard.json schema. They
# handle one-level string arrays and string scalars; branch names that contain
# double quotes or backslashes are out of scope and documented as such.
json_array_values() {
  local key="$1"
  local file="$2"

  # The final awk stage also guarantees newline-terminated output; BSD sed
  # would otherwise drop the trailing newline and `while read` would skip the
  # last value.
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

resolve_production_ref() {
  local name="$1"
  local short="${name#origin/}"

  if git rev-parse --verify "origin/$short" >/dev/null 2>&1; then
    printf 'origin/%s' "$short"
    return 0
  fi

  if git rev-parse --verify "$name" >/dev/null 2>&1; then
    printf '%s' "$name"
    return 0
  fi

  return 1
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
strict=0
check_patch_id=1

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
    --strict)
      strict=1
      shift
      ;;
    --no-check-patch-id)
      check_patch_id=0
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

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Not inside a Git work tree." >&2
  exit 2
fi

config_file="$(git rev-parse --show-toplevel)/.branch-guard.json"
config_used=0

if [ -f "$config_file" ]; then
  if [ -z "$production" ]; then
    while IFS= read -r config_production; do
      [ -n "$config_production" ] || continue
      if production="$(resolve_production_ref "$config_production")"; then
        config_used=1
        break
      fi
      production=""
    done < <(json_array_values production "$config_file")
  fi

  if [ "${#integrations[@]}" -eq 0 ]; then
    while IFS= read -r config_integration; do
      [ -n "$config_integration" ] || continue
      integrations+=("$config_integration")
      config_used=1
    done < <(json_array_values integration "$config_file")
  fi
fi

if [ -z "$production" ] || [ "${#integrations[@]}" -eq 0 ]; then
  echo "Missing required arguments." >&2
  if [ -f "$config_file" ]; then
    echo "No usable branch roles found in $config_file." >&2
  fi
  usage >&2
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
if [ "$config_used" -ne 0 ]; then
  echo "Branch roles loaded from .branch-guard.json"
fi
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
if [ "${#resolved_refs[@]}" -eq 0 ]; then
  echo "  skipped: none of the shared validation branch refs were found locally"
else
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
  if [ "$graph_found" -eq 0 ]; then
    echo "  none found"
  fi
fi
echo

patch_id_found=0
if [ "$check_patch_id" -eq 1 ]; then
  echo "Commits whose patches also exist on shared validation branches under a different hash:"
  if [ "${#resolved_refs[@]}" -eq 0 ]; then
    echo "  skipped: none of the shared validation branch refs were found locally"
  else
    # Join the patch-ids of validation-only commits against the release range.
    # A match with a different hash usually means a cherry-picked or rebased
    # copy whose commit message no longer names the validation branch.
    patch_id_matches="$(
      {
        for integration_ref in "${resolved_refs[@]}"; do
          git log --no-show-signature --no-merges -p "$production..$integration_ref" 2>/dev/null |
            git patch-id --stable |
            awk -v ref="$integration_ref" '{ print "I", $1, $2, ref }'
        done
        git log --no-show-signature --no-merges -p "$range" 2>/dev/null |
          git patch-id --stable |
          awk '{ print "H", $1, $2 }'
      } | awk '
        $1 == "I" && !($2 in integration_sha) { integration_sha[$2] = $3; integration_ref[$2] = $4; next }
        $1 == "H" && ($2 in integration_sha) && integration_sha[$2] != $3 {
          print $3, integration_sha[$2], integration_ref[$2]
        }
      '
    )"
    if [ -n "$patch_id_matches" ]; then
      while IFS=' ' read -r head_commit twin_commit twin_ref; do
        [ -n "$head_commit" ] || continue
        echo "  $(git log -1 --no-decorate --no-show-signature --oneline "$head_commit")"
        echo "    same patch as $(git rev-parse --short "$twin_commit") on $twin_ref"
        patch_id_found=1
      done <<EOF
$patch_id_matches
EOF
      cat <<'NOTE'
  note: patch-id matches are advisory. A rebased work branch that was
  previously merged into a validation pool matches its own copied commits;
  verify the origin of each commit before treating it as contamination.
NOTE
    else
      echo "  none found"
    fi
  fi
  echo
fi

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

if [ "$patch_id_found" -ne 0 ]; then
  cat <<'WARNING'
Result: advisory patch-id matches found; verify the origin of those commits.
WARNING
  if [ "$strict" -eq 1 ]; then
    exit 1
  fi
  exit 0
fi

echo "Result: no obvious shared-validation branch contamination found."
