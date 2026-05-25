#!/usr/bin/env bash
# Bootstrap a bare pod: sandy user + shell + claude code. No framework.
# Invoke as root or sandy; safe to re-run.
#
# Usage:  bash /workspace/tools/pod_bootstrap_minimal.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/pod_bootstrap_common.sh"

common_root_phase "$HERE/$(basename "${BASH_SOURCE[0]}")"   # no-op when already sandy; else execs back here
common_sandy_base
common_write_active_env "none"
common_install_claude_code

log "done!"
echo "  user:    sandy (password: 1, passwordless sudo)"
echo "  shell:   zsh + oh-my-zsh"
echo "  claude:  $(command -v claude || echo "$NPM_PREFIX/bin/claude")"
GH_TOKEN_FILE=/workspace/.gh_token
if [ ! -s "$GH_TOKEN_FILE" ]; then
    echo "  [!] gh token missing at $GH_TOKEN_FILE — gh CLI unauthenticated."
    echo "      Fetch one: https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=pod"
    echo "      Save:      echo -n '<token>' > $GH_TOKEN_FILE && chmod 600 $GH_TOKEN_FILE"
fi

if [ -t 0 ] && [ -t 1 ]; then
    log "launching zsh as sandy…"
    exec zsh -l
else
    log "non-interactive shell detected; not exec'ing zsh."
    log "to enter sandy manually: sudo -iu sandy"
fi