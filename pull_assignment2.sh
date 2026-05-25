#!/usr/bin/env bash
# Clone (or pull) sandyhu533/assignment2-systems into /workspace and check out
# the shanshan/dev branch. Safe to re-run.
#
# Usage:  bash /workspace/tools/pull_assignment2.sh
#         SKIP_FETCH=1 bash ...    # use local refs only, skip network fetch

set -euo pipefail

REPO_URL="https://github.com/sandyhu533/assignment2-systems.git"
REPO_DIR="/workspace/assignment2-systems"
BRANCH="shanshan/dev"

log() { echo -e "\033[1;34m[assignment2]\033[0m $*"; }

if [ ! -d "$REPO_DIR/.git" ]; then
    log "clone $REPO_URL -> $REPO_DIR"
    git clone "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"

if [ "${SKIP_FETCH:-0}" != "1" ]; then
    log "git fetch --all"
    git fetch --all --quiet
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git checkout "$BRANCH"
    git pull --ff-only origin "$BRANCH" 2>/dev/null || true
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git checkout -b "$BRANCH" "origin/$BRANCH"
else
    log "branch $BRANCH not found locally or on origin" >&2
    exit 1
fi

log "done — on $(git branch --show-current) @ $(git rev-parse --short HEAD)"
