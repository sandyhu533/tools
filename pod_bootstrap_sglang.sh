#!/usr/bin/env bash
# Bootstrap a sglang dev env on a fresh pod. Invoke as root or sandy; safe
# to re-run. Set DEV_BRANCH below (or via env) to pick a working branch.
#
# Usage:  bash /workspace/tools/pod_bootstrap_sglang.sh
#         SKIP_FETCH=1 bash ...                # skip git fetch for quick rerun

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/pod_bootstrap_common.sh"

FRAMEWORK="sglang"
FORK_REPO="https://github.com/sandyhu533/sglang.git"
UPSTREAM_REPO="https://github.com/sgl-project/sglang.git"
# DEV_BRANCH="experiment/ttft-22831-ablation"
# DEV_BRANCH="sandy/lora-scheduler-crash-fix"
DEV_BRANCH="${DEV_BRANCH:-sandy/fix-scheduler-ttft-hol}"
REPO_DIR="$WORKSPACE/sglang"
VENV_DIR="$SGLANG_VENV"

common_root_phase "$0"   # no-op when already sandy; else execs back here
common_sandy_base

log "clone + branch ($FRAMEWORK)"
common_clone_repo "$FORK_REPO" "$UPSTREAM_REPO" "$REPO_DIR"
common_checkout_branch "$REPO_DIR" "$DEV_BRANCH"

log "install sglang -> $VENV_DIR"
common_make_venv "$VENV_DIR"
# Editable install: local edits on the dev branch are picked up without reinstall.
# cd /tmp before the import probe — /workspace has a vllm/ subdir that PEP 420
# picks up as a namespace package, not relevant here but keeps the pattern
# consistent with the vllm script.
if ! (cd /tmp && python -c "import sglang" >/dev/null 2>&1); then
    uv pip install -e "$REPO_DIR/python"
fi
deactivate

common_write_active_env "$FRAMEWORK"
common_install_claude_code
common_final_summary "$FRAMEWORK" "$VENV_DIR" "$REPO_DIR"
log "launching zsh as sandy…"
exec zsh -l
