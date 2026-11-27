#!/usr/bin/env bash
set -euo pipefail

# Usage: gen_changelog.sh <mode: pre|release> <curr_tag> [target_ref] [max_commits]
MODE="${1:-pre}"
CURR_TAG="${2:-HEAD}"
TARGET_REF="${3:-HEAD}"
MAX_COMMITS="${4:-20}"

REPO="${GITHUB_REPOSITORY:-Najip/RKP-Mfr-Auto-Match}"
TARGET_SHA="$(git rev-parse "${TARGET_REF}")"

# Find previous tag:
# - pre: most recent tag (pre-release or full release) before this commit
# - release: most recent full release tag (v* without '-') before this commit
PREV_TAG=""
while IFS= read -r t; do
  [[ -z "$t" ]] && continue
  [[ "$t" == "$CURR_TAG" ]] && continue
  [[ "$t" == v* ]] || continue
  if [[ "$MODE" == "release" && "$t" == *-* ]]; then
    continue
  fi
  TAG_SHA="$(git rev-parse "${t}^{commit}" 2>/dev/null || true)"
  [[ "$TAG_SHA" == "$TARGET_SHA" ]] && continue
  PREV_TAG="$t"
  break
done < <(git tag --merged "${TARGET_REF}" --sort=-committerdate)

if [[ -n "$PREV_TAG" ]]; then
  RANGE="${PREV_TAG}..${TARGET_REF}"
else
  RANGE="${TARGET_REF}"
fi

# Collect commits (skip automated [skip ci] commits)
mapfile -t COMMITS < <(git log --no-merges --grep='\[skip ci\]' --invert-grep \
  --format='%H%x09%h%x09%s' "${RANGE}")

TOTAL="${#COMMITS[@]}"

echo "### Changes"
echo ""

if (( TOTAL == 0 )); then
  echo "- No new code changes."
else
  SHOWN=0
  for line in "${COMMITS[@]}"; do
    (( SHOWN >= MAX_COMMITS )) && break
    IFS=$'\t' read -r full_sha short_sha subject <<< "$line"
    echo "- [\`${short_sha}\`](https://github.com/${REPO}/commit/${full_sha}) ${subject}"
    SHOWN=$((SHOWN + 1))
  done

  if (( TOTAL > MAX_COMMITS )); then
    REMAINING=$((TOTAL - MAX_COMMITS))
    echo ""
    if [[ -n "$PREV_TAG" ]]; then
      echo "...and ${REMAINING} more commits. [See more](https://github.com/${REPO}/compare/${PREV_TAG}...${CURR_TAG})"
    else
      echo "...and ${REMAINING} more commits. [See more](https://github.com/${REPO}/commits/${CURR_TAG})"
    fi
  else
    echo ""
    if [[ -n "$PREV_TAG" ]]; then
      echo "**Full Changelog**: https://github.com/${REPO}/compare/${PREV_TAG}...${CURR_TAG}"
    else
      echo "**Full Changelog**: https://github.com/${REPO}/commits/${CURR_TAG}"
    fi
  fi
fi
