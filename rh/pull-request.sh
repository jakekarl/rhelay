#!/usr/bin/env bash
set -euo pipefail

# Usage helper
usage() {
  cat <<'USAGE'
Usage:
  pull-request.sh [source_branch] <target_branch>

Arguments:
  source_branch     Source GitHub branch to promote from (defaults to current branch)
  target_branch     Target GitHub branch to promote to

Description:
  This script creates a promotional pull request by:
  1. Checking out the source branch
  2. Pulling the latest changes
  3. Creating a new promotion branch with naming convention: promotion__[source]__[target]
  4. Generating a manifest using generate-manifest.sh
  5. Creating a pull request from the promotion branch to the target branch

Examples:
  ./pull-request.sh feature/my-feature main
  ./pull-request.sh main uat
  ./pull-request.sh main                    # Uses current branch as source
USAGE
}

# ---- Parse & validate args ----
if [[ $# -eq 1 ]]; then
  # Only target branch provided, use current branch as source
  SOURCE_BRANCH=$(git branch --show-current)
  TARGET_BRANCH="$1"
elif [[ $# -eq 2 ]]; then
  # Both source and target branches provided
  SOURCE_BRANCH="$1"
  TARGET_BRANCH="$2"
else
  usage
  exit 1
fi

# ---- Validate branches ----
if [[ -z "$SOURCE_BRANCH" || -z "$TARGET_BRANCH" ]]; then
  echo "Error: Could not determine source and target branches."
  usage
  exit 2
fi

# ---- Constants ----
API_VERSION="64.0"
PROMOTION_BRANCH="promotion__${SOURCE_BRANCH}__${TARGET_BRANCH}"

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
  # Delete local branch if it exists (shouldn't happen, but just in case)
  if git show-ref --verify --quiet "refs/heads/$PROMOTION_BRANCH"; then
    echo "  Local promotion branch exists but remote doesn't, deleting local first..."
    git branch -D "$PROMOTION_BRANCH"
  fi
  git checkout -b "$PROMOTION_BRANCH"
fi

# ---- Step 4: Run generate-manifest.sh ----
# echo -e "${GREEN}Step 4: Generating manifest with generate-manifest.sh...${NC}"
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source "$SCRIPT_DIR/generate-manifest.sh" \
#   --base "origin/$TARGET_BRANCH" \
#   --head "$SOURCE_BRANCH" \
#   --api "$API_VERSION" \
#   --verbose

# # ---- Step 5: Push promotional branch ----
echo -e "${GREEN}Step 5: Pushing promotional branch...${NC}"
git push origin "$PROMOTION_BRANCH"
# if git diff --quiet && git diff --cached --quiet; then
#   echo "  No manifest changes to commit."
# else
#   git add manifest/
#   git commit -m "Generate manifest for promotion from $SOURCE_BRANCH to $TARGET_BRANCH"
# fi
# git push origin "$PROMOTION_BRANCH"

# ---- Step 6: Create pull request ----
echo -e "${GREEN}Step 6: Creating pull request...${NC}"
if command -v gh >/dev/null 2>&1; then
  gh pr create \
    --base "$TARGET_BRANCH" \
    --head "$PROMOTION_BRANCH" \
    --title "[Promote] $SOURCE_BRANCH → $TARGET_BRANCH" \
    --body "Automated promotion from \`$SOURCE_BRANCH\` to \`$TARGET_BRANCH\`

This PR contains:
- Manifest generated for changes between \`$TARGET_BRANCH\` and \`$SOURCE_BRANCH\`
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

echo ""
echo "✅ Promotion process completed!"
echo "   Promotion branch: $PROMOTION_BRANCH"
echo "   Ready to merge into: $TARGET_BRANCH"