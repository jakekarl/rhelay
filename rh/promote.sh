#!/usr/bin/env bash
set -euo pipefail

# Usage helper
usage() {
  cat <<'USAGE'
Usage:
  promote.sh [source_branch]

Arguments:
  source_branch     Source GitHub branch to promote from (defaults to current branch)

Description:
  This script automates creating a promotion pull request to the initial stage by:
    1. Reading the target branch from pipeline.json (stage where previous = null)
    2. Checking out the source branch and pulling latest.
    3. Creating or updating a promotion branch named promotion__<source>__<target>.
    4. If there are no commits between origin/<target> and <source>, the script
       will clean up any promotion branch it created locally and exit.
    5. Otherwise it pushes the promotion branch to origin and creates a PR 
       using the GitHub CLI (gh) if present.

Examples:
  ./promote.sh feature/my-feature
  ./promote.sh release
  ./promote.sh                    # Uses current branch as source
USAGE
}

# ---- Parse & validate args ----
if [[ $# -eq 0 ]]; then
  # Use current branch as source
  SOURCE_BRANCH=$(git branch --show-current)
elif [[ $# -eq 1 ]]; then
  SOURCE_BRANCH="$1"
else
  usage
  exit 1
fi

# ---- Read target branch from pipeline.json ----
TARGET_BRANCH=$(jq -r '.stages | to_entries[] | select(.value.previous == null) | .value.branch' rh/pipeline.json)

if [[ -z "$TARGET_BRANCH" ]]; then
  echo "Error: Could not determine target branch from pipeline.json"
  exit 2
fi

# ---- Validate source branch ----
if [[ -z "$SOURCE_BRANCH" ]]; then
  echo "Error: Could not determine source branch."
  usage
  exit 2
fi

# ---- Constants ----
API_VERSION="64.0"
PROMOTION_BRANCH="promotion__${SOURCE_BRANCH}__${TARGET_BRANCH}"
# Track whether we created the promotion branch in this run (so we can delete it)
CREATED_PROMOTION=0

# Color codes
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "Creating promotional pull request:"
echo "  Source branch: $SOURCE_BRANCH"
echo "  Target branch: $TARGET_BRANCH"
echo "  Promotion branch: $PROMOTION_BRANCH"
echo ""

# ---- Step 1: Checkout source branch ----
echo -e "${GREEN}Step 1: Checking out source branch '$SOURCE_BRANCH'...${NC}"
git checkout "$SOURCE_BRANCH"

# ---- Step 2: Pull latest changes ----
echo -e "${GREEN}Step 2: Pulling latest changes...${NC}"
git pull origin "$SOURCE_BRANCH"

# ---- Step 3: Handle promotion branch ----
echo -e "${GREEN}Step 3: Handling promotion branch '$PROMOTION_BRANCH'...${NC}"

# Check if promotion branch exists on remote
if git ls-remote --exit-code --heads origin "$PROMOTION_BRANCH" >/dev/null 2>&1; then
  echo "  Promotion branch exists on remote, checking it out..."
  # Check if local branch exists
  if git show-ref --verify --quiet "refs/heads/$PROMOTION_BRANCH"; then
    echo "  Local promotion branch exists, switching to it..."
    git checkout "$PROMOTION_BRANCH"
    echo "  Pulling latest changes from remote promotion branch..."
    git pull origin "$PROMOTION_BRANCH"
  else
    echo "  Creating local tracking branch for remote promotion branch..."
    git checkout -b "$PROMOTION_BRANCH" "origin/$PROMOTION_BRANCH"
  fi
  
  echo "  Rebasing promotion branch with latest changes from '$SOURCE_BRANCH'..."
  git rebase "$SOURCE_BRANCH"
else
  echo "  Promotion branch doesn't exist, creating new one..."
  CREATED_PROMOTION=1
  # Delete local branch if it exists (shouldn't happen, but just in case)
  if git show-ref --verify --quiet "refs/heads/$PROMOTION_BRANCH"; then
    echo "  Local promotion branch exists but remote doesn't, deleting local first..."
    git branch -D "$PROMOTION_BRANCH"
  fi
  git checkout -b "$PROMOTION_BRANCH"
fi

# ---- Check for commits between target and source ----
echo -e "${GREEN}Checking for commits between origin/$TARGET_BRANCH and $SOURCE_BRANCH...${NC}"
# Ensure we have latest target ref
git fetch origin "$TARGET_BRANCH" >/dev/null 2>&1 || true
COMMITS_AHEAD=$(git rev-list --count "origin/$TARGET_BRANCH..$SOURCE_BRANCH" || true)
if [[ -z "$COMMITS_AHEAD" ]]; then
  COMMITS_AHEAD=0
fi
if [[ "$COMMITS_AHEAD" -eq 0 ]]; then
  echo "No commits found between origin/$TARGET_BRANCH and $SOURCE_BRANCH. Cleaning up."
  # If we created the promotion branch during this run, delete it locally.
  if [[ "$CREATED_PROMOTION" -eq 1 ]]; then
    echo "Deleting local promotion branch '$PROMOTION_BRANCH'..."
    # Return to source branch before deleting
    git checkout "$SOURCE_BRANCH" || true
    git branch -D "$PROMOTION_BRANCH" || true
    echo "Local promotion branch deleted."
  else
    echo "Promotion branch pre-existed; leaving remote branch intact."
    # Return to source branch
    git checkout "$SOURCE_BRANCH" || true
  fi

  echo "Nothing to promote. Exiting."
  exit 0
fi

# ---- Step 4: Push promotional branch ----
echo -e "${GREEN}Step 4: Pushing promotional branch...${NC}"
git push origin "$PROMOTION_BRANCH"

# ---- Step 5: Create pull request ----
echo -e "${GREEN}Step 5: Creating pull request...${NC}"
if command -v gh >/dev/null 2>&1; then
  gh pr create \
    --base "$TARGET_BRANCH" \
    --head "$PROMOTION_BRANCH" \
    --title "[rHelay] $SOURCE_BRANCH → $TARGET_BRANCH" \
    --body "Automated promotion from \`$SOURCE_BRANCH\` to \`$TARGET_BRANCH\`

This PR contains changes to promote to the initial pipeline stage.
- API Version: $API_VERSION

**Source Branch:** \`$SOURCE_BRANCH\`
**Target Branch:** \`$TARGET_BRANCH\`
**Promotion Branch:** \`$PROMOTION_BRANCH\`"
  
  echo ""
  echo "✅ Pull request created successfully!"
  echo "   View it at: $(gh pr view "$PROMOTION_BRANCH" --json url --jq '.url')"
else
  echo "⚠️  GitHub CLI (gh) not found. Please install it to automatically create pull requests."
  echo "   Alternatively, create the PR manually from branch '$PROMOTION_BRANCH' to '$TARGET_BRANCH'"
  echo "   Branch has been pushed and is ready for PR creation."
fi

# ---- Step 6: Return to source branch ----
echo ""
echo -e "${GREEN}Step 6: Returning to source branch '$SOURCE_BRANCH'...${NC}"
git checkout "$SOURCE_BRANCH"

echo ""
echo "✅ Promotion process completed!"
echo "   Promotion branch: $PROMOTION_BRANCH"
echo "   Ready to merge into: $TARGET_BRANCH"
echo "   Back on source branch: $SOURCE_BRANCH"
