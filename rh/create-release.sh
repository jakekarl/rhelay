#!/usr/bin/env bash
set -euo pipefail

# create-release.sh
# Usage: create-release.sh
# This script creates the next release branch in the series: release/A, release/B, ...

usage() {
  cat <<'USAGE'
Usage:
  create-release.sh

Description:
  Determines the next letter in the release series (A..Z) based on existing
  branches named `release/<LETTER>` (local or remote) and creates a new
  branch named `release/<NEXT>` from `main`, then pushes it and sets upstream.

Notes:
  - First release will be `release/A` when no existing release branches are found.
  - The script will error if it would need to create past `release/Z`.
USAGE
}

if [[ $# -gt 0 ]]; then
  echo "Unexpected arguments."
  usage
  exit 1
fi

echo "Preparing to create next release branch..."

# Save original branch
ORIGINAL_BRANCH=$(git branch --show-current)
echo "Original branch: $ORIGINAL_BRANCH"

echo "Fetching latest refs..."
git fetch origin --prune

# Determine next release letter (A..Z)
echo "Detecting existing release branches..."
# Gather local release branches (single-letter) and remote release branches
LOCAL_RELEASES=$(git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | grep -E '^release/[A-Za-z]$' || true)
REMOTE_RELEASES=$(git ls-remote --heads origin 'refs/heads/release/*' 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | grep -E '^release/[A-Za-z]$' || true)

ALL_RELEASES=$(printf "%s\n%s\n" "$LOCAL_RELEASES" "$REMOTE_RELEASES" | grep -E '^release/[A-Za-z]$' || true)

MAX_ORD=0
while IFS= read -r rb; do
  if [[ -z "$rb" ]]; then
    continue
  fi
  letter=$(echo "$rb" | sed -E 's/^release\/([A-Za-z])$/\1/')
  # uppercase
  letter=$(echo "$letter" | tr '[:lower:]' '[:upper:]')
  ord=$(printf '%d' "'${letter}")
  if [[ $ord -gt $MAX_ORD ]]; then
    MAX_ORD=$ord
  fi
done <<< "$ALL_RELEASES"

if [[ $MAX_ORD -eq 0 ]]; then
  NEXT_LETTER='A'
else
  if [[ $MAX_ORD -ge 90 ]]; then
    echo "Error: existing release branches reached 'Z'. Cannot create next release letter." >&2
    exit 2
  fi
  NEXT_LETTER=$(printf "\\$(printf '%03o' $((MAX_ORD + 1)))")
fi

BRANCH="release/${NEXT_LETTER}"

echo "Next release branch will be: $BRANCH"

# Read production branch from pipeline.json
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPELINE_JSON="$PROJECT_ROOT/rh/pipeline.json"

if [[ ! -f "$PIPELINE_JSON" ]]; then
  echo "Error: pipeline.json not found at $PIPELINE_JSON" >&2
  exit 2
fi

PROD_BRANCH=$(jq -r '.stages.production.branch' "$PIPELINE_JSON" 2>/dev/null)
if [[ -z "$PROD_BRANCH" || "$PROD_BRANCH" == "null" ]]; then
  echo "Error: Could not read production branch from pipeline.json" >&2
  exit 2
fi

echo "Checking out production branch: $PROD_BRANCH"
git checkout "$PROD_BRANCH"

echo "Pulling latest changes for $PROD_BRANCH..."
git pull --ff-only origin "$PROD_BRANCH"

# If remote branch exists, create local tracking branch or switch to it
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "Remote branch 'origin/$BRANCH' already exists."
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    echo "Local branch '$BRANCH' also exists. Checking it out."
    git checkout "$BRANCH"
  else
    echo "Creating local tracking branch for 'origin/$BRANCH'."
    git checkout -b "$BRANCH" "origin/$BRANCH"
  fi
  echo "Done."
  echo "Returning to original branch: $ORIGINAL_BRANCH"
  git checkout "$ORIGINAL_BRANCH"
  exit 0
fi

# If local branch exists but remote doesn't, switch to it
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "Local branch '$BRANCH' already exists. Checking it out."
  git checkout "$BRANCH"
  echo "Returning to original branch: $ORIGINAL_BRANCH"
  git checkout "$ORIGINAL_BRANCH"
  exit 0
fi

echo "Creating new branch '$BRANCH' from main..."
git checkout -b "$BRANCH"

echo "Pushing '$BRANCH' to origin and setting upstream..."
git push -u origin "$BRANCH"

echo "Branch created and pushed: $BRANCH"

echo "Returning to original branch: $ORIGINAL_BRANCH"
git checkout "$ORIGINAL_BRANCH"

exit 0

