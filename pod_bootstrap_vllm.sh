#!/usr/bin/env bash
# Bootstrap a vllm dev env on a fresh pod. Invoke as root or sandy; safe to
# re-run. Uses VLLM_USE_PRECOMPILED=1 so we don't need nvcc / full CUDA toolkit.
#
# Usage:  bash /workspace/tools/pod_bootstrap_vllm.sh
#         SKIP_FETCH=1 bash ...                # skip git fetch for quick rerun
#         DEV_BRANCH=sandy/foo bash ...        # override branch

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/pod_bootstrap_common.sh"

FRAMEWORK="vllm"
FORK_REPO="https://github.com/sandyhu533/vllm.git"
UPSTREAM_REPO="https://github.com/vllm-project/vllm.git"
DEV_BRANCH="${DEV_BRANCH:-main}"
REPO_DIR="$WORKSPACE/vllm"
VENV_DIR="$VLLM_VENV"

common_root_phase "$0"
common_sandy_base

log "clone + branch ($FRAMEWORK)"
common_clone_repo "$FORK_REPO" "$UPSTREAM_REPO" "$REPO_DIR"
common_checkout_branch "$REPO_DIR" "$DEV_BRANCH"

log "install vllm -> $VENV_DIR"
common_make_venv "$VENV_DIR"
# VLLM_USE_PRECOMPILED=1: pull prebuilt CUDA .so from the matching wheel
# instead of invoking nvcc. Python edits in $REPO_DIR still picked up because
# it's an editable install; only CUDA kernels are frozen to wheel version.
#
# Build isolation stays ON (default): vllm's setup.py imports torch at metadata
# time; --no-build-isolation would require preinstalling torch+cmake+ninja.
#
# --extra-index-url: torch==2.11.0+cu128 wheels live on the PyTorch index.
# UV_EXTRA_INDEX_URL propagates to uv's isolated build env too.
# --index-strategy unsafe-best-match: uv's default keeps each package pinned to
# the first index it appears in — the PyTorch index's stale cmake==3.25.0 would
# otherwise shadow newer PyPI versions.
if ! (cd /tmp && python -c "import vllm, vllm.envs" >/dev/null 2>&1); then
    cd "$REPO_DIR"
    UV_EXTRA_INDEX_URL="https://download.pytorch.org/whl/cu128" \
        UV_INDEX_STRATEGY=unsafe-best-match \
        VLLM_USE_PRECOMPILED=1 \
        uv pip install -e . \
            --extra-index-url https://download.pytorch.org/whl/cu128 \
            --index-strategy unsafe-best-match
fi
deactivate

common_write_active_env "$FRAMEWORK"
common_install_claude_code
common_final_summary "$FRAMEWORK" "$VENV_DIR" "$REPO_DIR"
log "launching zsh as sandy…"
exec zsh -l
