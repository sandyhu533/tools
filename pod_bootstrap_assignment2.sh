#!/usr/bin/env bash
# Bootstrap a CS336 assignment2-systems dev env on a fresh pod. Invoke as root
# or sandy; safe to re-run. The repo is uv-native (has uv.lock), so we use
# `uv sync` to build the venv in $REPO_DIR/.venv per the lockfile.
#
# Usage:  bash /workspace/tools/pod_bootstrap_assignment2.sh
#         SKIP_FETCH=1 bash ...                # skip git fetch for quick rerun
#         DEV_BRANCH=sandy/foo bash ...        # override branch

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/pod_bootstrap_common.sh"

FRAMEWORK="assignment2"
REPO_URL="https://github.com/sandyhu533/assignment2-systems.git"
DEV_BRANCH="${DEV_BRANCH:-practive/v1}"
REPO_DIR="$ASSIGNMENT2_REPO"
VENV_DIR="$ASSIGNMENT2_VENV"

common_root_phase "$0"   # no-op when already sandy; else execs back here
common_sandy_base

log "clone + branch ($FRAMEWORK)"
# No upstream remote — this is the student's own assignment repo, not a fork.
if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$REPO_URL" "$REPO_DIR"
fi
common_checkout_branch "$REPO_DIR" "$DEV_BRANCH"

log "uv sync -> $VENV_DIR"
# uv sync builds $REPO_DIR/.venv from pyproject.toml + uv.lock and installs
# cs336-basics as an editable local dep (per [tool.uv.sources] in pyproject).
# Re-runs are idempotent: uv only touches packages whose lock entries changed.
cd "$REPO_DIR"
if ! command -v uv >/dev/null 2>&1; then
    # uv normally lands inside the framework venvs (common_make_venv installs
    # it). For assignment2 we need uv *before* any venv exists — grab it via
    # the standalone installer into $HOME/.local/bin.
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
uv sync

common_write_active_env "$FRAMEWORK"
common_install_claude_code
common_final_summary "$FRAMEWORK" "$VENV_DIR" "$REPO_DIR"
log "launching zsh as sandy…"
exec zsh -l
