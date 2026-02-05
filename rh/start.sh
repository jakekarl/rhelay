#!/bin/bash

# Create Scratch Org
## STOP SCRIPT EXECUTION ON ERROR
set -euo pipefail

usage() {
        cat <<'USAGE'
Usage:
    start.sh <ticket_number> <create_scratch>

Arguments:
    ticket_number   Ticket or branch name to create/checkout (required)
    create_scratch  yes|no (required) - whether to create a scratch org and deploy

Description:
    Sets up a development scratch org and deploys metadata. When the
    second argument is 'no', all scratch org creation and deployment
    steps are skipped and the script only prepares the local branch
    and environment.

Examples:
    ./start.sh JIRA-123 yes
    ./start.sh JIRA-123 no
USAGE
}

##  ECHO COLORS
ORANGE='\033[38;5;214m'
BRed='\033[1;31m' 
RED='\033[0;31m'
BLUE='\033[1;34m'
DEFAULT='\033[m' # No Color

## STORE LAST FUNCTION NAME
LAST_ARG=''

## CALL THIS ON ERROR
notify() {
    echo -e "${BRed}${LAST_ARG} Error ${RED}$(caller): ${BASH_COMMAND}"
    echo -e "$DEFAULT"
}
trap notify ERR

function echo_block() {
    echo -e "${BLUE}**************************************************";
    echo -e "${ORANGE} $1 $2 ${BLUE} $(date)" 
    echo -e "**************************************************${DEFAULT}";
}

function echo_wrapper() {
    if [[ ! -z $LAST_ARG ]]; then
        echo_block "${LAST_ARG}" "Complete"
        echo ""
    fi

    echo_block "$1" "Starting"
    LAST_ARG=$1
}

if [[ $# -lt 2 ]]; then
    echo -e "${RED}Error: Missing required arguments."
    usage
    exit 1
fi

TICKET_NUMBER="$1"
CREATE_SCRATCH_ARG="$2"
CREATE_SCRATCH=$(echo "$CREATE_SCRATCH_ARG" | tr '[:upper:]' '[:lower:]')
if [[ "$CREATE_SCRATCH" =~ ^(y|yes|true|1)$ ]]; then
    DO_SCRATCH=1
else
    DO_SCRATCH=0
fi

## CREATE SCRATCH ORG
echo_wrapper "Install Latest NPM Packages"
npm ci

echo_wrapper "Discord Changes"
git restore .

# Read production branch from pipeline.json
PROD_BRANCH=$(cat rh/pipeline.json | grep -A 2 '"production"' | grep '"branch"' | sed 's/.*"branch": "\(.*\)".*/\1/')

echo_wrapper "Checkout $PROD_BRANCH Branch"
git checkout "$PROD_BRANCH"

echo_wrapper "Pull Latest Changes"
git pull origin "$PROD_BRANCH"

echo_wrapper "Checkout New Branch for Ticket"
if git show-ref --verify --quiet "refs/heads/$TICKET_NUMBER"; then
    git checkout "$TICKET_NUMBER"
else
    git checkout -b "$TICKET_NUMBER"
fi

# Read organization and project abbreviations from pipeline.json
ORG_ABBR=$(jq -r '.organization.abbreviation' rh/pipeline.json)
PROJECT_ABBR=$(jq -r '.project.abbreviation' rh/pipeline.json)
project="$ORG_ABBR-$PROJECT_ABBR"
branch=$(git branch | sed -n -e 's/^\* \(.*\)/\1/p')
scratchOrgName="$project-$branch"
if [[ $DO_SCRATCH -eq 1 ]]; then
    echo_wrapper "Install SF Plugin"
    # Install texei plugin if not already installed. Don't fail the whole script
    # if the sf install command returns a non-zero exit code but the plugin
    # is usable (some optional native deps may fail to install while the
    # plugin still works).
    if sf plugins | grep -q "texei-sfdx-plugin"; then
        echo "texei-sfdx-plugin already installed"
    else
        echo "Installing texei-sfdx-plugin..."
        # run install; if it fails, verify plugin availability before exiting
        if ! printf 'y\n' | sf plugins install texei-sfdx-plugin --verbose; then
            echo "sf plugins install returned non-zero. Verifying plugin availability..."
            if sf texei --help >/dev/null 2>&1; then
                echo "texei plugin appears usable despite install warnings — continuing."
            else
                echo "texei plugin failed to install and is not available. Please run:\n  sf plugins install texei-sfdx-plugin --verbose"
                exit 1
            fi
        fi
    fi

    echo_wrapper "Create Fresh Scratch Org" 
    sf org create scratch -f ./config/project-scratch-def.json -a "$scratchOrgName" --name "$scratchOrgName" -y 30 -w 60 -d

    echo_wrapper "Deploy Package Metadata"
    sf project deploy start -d force-app -o "$scratchOrgName" --ignore-conflicts

    echo_wrapper "Reset Project Tracking"
    sf project reset tracking -p

    echo_wrapper "Open Scratch Org"
    sf org open
else
    echo_wrapper "Skipping scratch org creation and deployment as requested"
fi