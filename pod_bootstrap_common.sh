#!/usr/bin/env bash
# Library of shared bootstrap steps. Not meant to be executed directly —
# `source` this from pod_bootstrap_sglang.sh or pod_bootstrap_vllm.sh.
#
# Contract: the caller sets FRAMEWORK / VENV_DIR / REPO_DIR / DEV_BRANCH /
# FORK_REPO / UPSTREAM_REPO, then invokes the phases in order:
#     common_root_phase "$0"   # exec's back as sandy if started as root
#     common_sandy_base
#     common_clone_repo "$FORK_REPO" "$UPSTREAM_REPO" "$REPO_DIR"
#     common_checkout_branch "$REPO_DIR" "$DEV_BRANCH"
#     common_make_venv "$VENV_DIR"
#     ...framework-specific `uv pip install`...
#     common_write_active_env "$FRAMEWORK"
#     common_install_claude_code
#     common_final_summary

set -euo pipefail

WORKSPACE=/workspace
SANDY_HOME="$WORKSPACE/home/sandy"
OMZ_DIR="$WORKSPACE/.oh-my-zsh"
SHELLRC="$WORKSPACE/.shellrc"
NPM_PREFIX="$WORKSPACE/.npm-global"
ACTIVE_ENV_FILE="$WORKSPACE/.active_env"
SGLANG_VENV="$WORKSPACE/venv-sglang"
VLLM_VENV="$WORKSPACE/venv-vllm"
# assignment2-systems is a uv-native project (has uv.lock); `uv sync` creates
# its venv inside the repo, so the path follows the repo layout rather than
# the /workspace/venv-* convention used by sglang/vllm.
ASSIGNMENT2_REPO="$WORKSPACE/assignment2-systems"
ASSIGNMENT2_VENV="$ASSIGNMENT2_REPO/.venv"
MARKER="# === cloudgpu bootstrap ==="

log() { echo -e "\033[1;34m[bootstrap]\033[0m $*"; }

# ---------- root phase: apt + nodejs + sandy user, then hand off ----------
# Call as: common_root_phase "$0"  — the arg is the top-level script path so
# the `exec sudo -u sandy bash <path>` re-enters the same framework script.
# No-op when already running as sandy.
common_root_phase() {
    local caller_script="$1"
    [ "$(id -u)" != "0" ] && return 0

    log "root phase (apt + node + sandy)"

    # apt tools + node + gh + libnuma (see root-only notes below).
    local APT_TOOLS=(zsh git curl tmux htop gpg sudo cmake ninja)
    local MISSING=()
    local t
    for t in "${APT_TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || MISSING+=("$t"); done
    local NEED_NUMA=0
    # libnuma is a shared library, not a binary — probe via ldconfig. sgl_kernel's
    # common_ops.so dlopens libnuma.so.1 during sglang startup and fails silently
    # otherwise (falls back to a less-capable variant).
    ldconfig -p 2>/dev/null | grep -q 'libnuma\.so\.1' || NEED_NUMA=1
    local NEED_PYDEV=0
    compgen -G '/usr/include/python3.*/Python.h' >/dev/null 2>&1 \
        || dpkg -s python3-dev >/dev/null 2>&1 \
        || NEED_PYDEV=1
    if [ "${#MISSING[@]}" -gt 0 ] || [ "$NEED_NUMA" = "1" ] || [ "$NEED_PYDEV" = "1" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq zsh git curl tmux htop ca-certificates gnupg libnuma1 sudo \
            cmake ninja-build python3-dev build-essential pkg-config
    fi

    # Node.js 20.x (for claude-code). Reinstalled each pod rebuild (overlay).
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
        apt-get install -y -qq nodejs
    fi

    # Nsight Systems profiler. Pulls latest versioned package from the CUDA repo
    # (cuda-ubuntu2204-x86_64.list, pre-populated on RunPod images). The package
    # wires /usr/local/bin/nsys via update-alternatives, so no PATH munging.
    if ! command -v nsys >/dev/null 2>&1; then
        local NSYS_PKG
        NSYS_PKG=$(apt-cache search '^nsight-systems-[0-9]' 2>/dev/null \
            | awk '{print $1}' | sort -V | tail -1)
        if [ -n "$NSYS_PKG" ]; then
            apt-get install -y -qq "$NSYS_PKG"
        else
            log "     no nsight-systems package found in apt; skipping nsys install"
        fi
    fi

    # GitHub CLI. Auth via $GH_TOKEN picked up from /workspace/.gh_token in shellrc.
    if ! command -v gh >/dev/null 2>&1; then
        local GH_KEYRING=/usr/share/keyrings/githubcli-archive-keyring.gpg
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | dd of="$GH_KEYRING" status=none
        chmod go+r "$GH_KEYRING"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$GH_KEYRING] https://cli.github.com/packages stable main" \
            > /etc/apt/sources.list.d/github-cli.list
        apt-get update -qq
        apt-get install -y -qq gh
    fi

    # sandy user — zsh login shell, home on /workspace, passwordless sudo.
    if ! id -u sandy >/dev/null 2>&1; then
        useradd -M -d "$SANDY_HOME" -s /bin/zsh sandy
    fi
    if [ "$(getent passwd sandy | cut -d: -f7)" != "/bin/zsh" ]; then
        chsh -s /bin/zsh sandy
    fi
    if [ "$(getent passwd sandy | cut -d: -f6)" != "$SANDY_HOME" ]; then
        usermod -d "$SANDY_HOME" sandy
    fi
    echo 'sandy:1' | chpasswd
    if [ ! -f /etc/sudoers.d/sandy ]; then
        echo 'sandy ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/sandy
        chmod 440 /etc/sudoers.d/sandy
    fi

    # sandy's home (shared volume — can't chown, so create *as* sandy).
    if [ ! -d "$SANDY_HOME" ]; then
        sudo -u sandy mkdir -p "$SANDY_HOME"
        local f
        for f in /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout; do
            [ -f "$f" ] && sudo -u sandy cp -n "$f" "$SANDY_HOME/" 2>/dev/null || true
        done
    fi

    # SSH: propagate root's authorized_keys to sandy (RunPod only plants root's).
    if [ -f /root/.ssh/authorized_keys ]; then
        local SANDY_SSH="$SANDY_HOME/.ssh"
        sudo -u sandy mkdir -p "$SANDY_SSH"
        sudo -u sandy touch "$SANDY_SSH/authorized_keys"
        local key
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            sudo -u sandy grep -qxF -- "$key" "$SANDY_SSH/authorized_keys" 2>/dev/null \
                || echo "$key" | sudo -u sandy tee -a "$SANDY_SSH/authorized_keys" >/dev/null
        done < /root/.ssh/authorized_keys
        sudo -u sandy chmod 700 "$SANDY_SSH" 2>/dev/null || true
        sudo -u sandy chmod 600 "$SANDY_SSH/authorized_keys" 2>/dev/null || true
    fi

    # sshd StrictModes off — /workspace is a shared volume that can't enforce
    # 600 perms, so sshd's default rejects sandy's authorized_keys.
    local SSHD_TARGET
    if [ -d /etc/ssh/sshd_config.d ] && \
       grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
        SSHD_TARGET=/etc/ssh/sshd_config.d/99-sandy.conf
    else
        SSHD_TARGET=/etc/ssh/sshd_config
    fi
    if ! grep -qE '^\s*StrictModes\s+no' "$SSHD_TARGET" 2>/dev/null; then
        {
            echo ""
            echo "# sandy's home is on a shared volume that can't enforce 600 perms."
            echo "StrictModes no"
        } >> "$SSHD_TARGET"
        if sshd -t 2>/dev/null; then
            pkill -HUP -f '^sshd:' 2>/dev/null || pkill -HUP sshd 2>/dev/null || true
        else
            log "     sshd -t failed after StrictModes edit; reverting"
            sed -i -e '/^# sandy.s home is on a shared/,/^StrictModes no$/d' "$SSHD_TARGET"
        fi
    fi

    # One-time /workspace chown (only when the shared mount permits it).
    local CHOWN_MARKER=/workspace/.sandy-ownership
    if [ ! -f "$CHOWN_MARKER" ]; then
        if chown sandy:sandy /workspace 2>/dev/null; then
            log "     chown /workspace -> sandy (first run only)"
            chown -R sandy:sandy /workspace
            touch "$CHOWN_MARKER"
            chown sandy:sandy "$CHOWN_MARKER"
        else
            log "     /workspace chown not permitted (shared volume); skipping"
            touch "$CHOWN_MARKER" 2>/dev/null || true
        fi
    fi

    log "     handoff -> sandy"
    exec sudo -u sandy -H env "SKIP_FETCH=${SKIP_FETCH:-0}" bash "$caller_script"
}

# ---------- sandy-phase base setup: apt guard, shellrc, rc files, caches ----------
common_sandy_base() {
    if [ "$(id -un)" != "sandy" ]; then
        echo "[bootstrap] must run as sandy at this point (current: $(id -un))" >&2
        exit 1
    fi

    # Shared /workspace may hold files from prior root-run bootstraps.
    git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*' \
        || git config --global --add safe.directory '*'

    # Git identity — needed for commits via `gh` / `git`. Public values; the
    # auth token stays in /workspace/.gh_token (gitignored, sourced by shellrc).
    git config --global user.name "sandyhu533"
    git config --global user.email "533.sandyhu@gmail.com"

    # Route `git push` over https through gh's credential helper so it picks up
    # $GH_TOKEN (set by shellrc) instead of prompting for a password.
    command -v gh >/dev/null 2>&1 && gh auth setup-git 2>/dev/null || true

    # Runtime-required build tooling check (ninja is invoked by sglang's tvm_ffi
    # and flashinfer JIT at runtime). The root-phase apt only fires when
    # bootstrap starts as root; reruns as sandy would skip it otherwise.
    local NEEDS=()
    for t in ninja cmake; do command -v "$t" >/dev/null 2>&1 || NEEDS+=("$t"); done
    if [ "${#NEEDS[@]}" -gt 0 ]; then
        log "     sudo apt-get install: ${NEEDS[*]} (runtime build tooling)"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            ninja-build cmake build-essential pkg-config python3-dev
    fi

    log "write $SHELLRC"
    cat > "$SHELLRC" <<'EOF'
# Shared by bash and zsh. Persisted on /workspace.
# Every cache on the persistent volume so / (20GB overlay) stays clean and
# pod rebuilds don't re-download models / wheels / compiled kernels.
export HF_HOME=/workspace/.cache/huggingface
export TRANSFORMERS_CACHE=/workspace/.cache/huggingface
export HF_DATASETS_CACHE=/workspace/.cache/huggingface/datasets
export PIP_CACHE_DIR=/workspace/.cache/pip
export UV_CACHE_DIR=/workspace/.cache/uv
export TORCH_HOME=/workspace/.cache/torch
export TRITON_CACHE_DIR=/workspace/.cache/triton
export XDG_CACHE_HOME=/workspace/.cache
export FLASHINFER_WORKSPACE_BASE=/workspace/.cache/flashinfer
export SGLANG_JIT_CACHE_DIR=/workspace/.cache/sglang_jit
export PATH=/workspace/.npm-global/bin:$PATH
[ -f /workspace/.gh_token ] && export GH_TOKEN="$(cat /workspace/.gh_token)"
cd /workspace 2>/dev/null || true
# Active env selection:
#   $BOOT_ENV override (inline) > /workspace/.active_env file > sglang default.
# The framework bootstrap script writes .active_env on completion so new shells
# land in the matching venv.
_boot_env="${BOOT_ENV:-$(cat /workspace/.active_env 2>/dev/null || echo sglang)}"
case "$_boot_env" in
    vllm)         _active_venv=/workspace/venv-vllm ;;
    assignment2)  _active_venv=/workspace/assignment2-systems/.venv ;;
    *)            _active_venv=/workspace/venv-sglang ;;
esac
if [ -f "$_active_venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "$_active_venv/bin/activate"
fi
unset _boot_env _active_venv
alias activate-sglang='source /workspace/venv-sglang/bin/activate'
alias activate-vllm='source /workspace/venv-vllm/bin/activate'
alias activate-assignment2='source /workspace/assignment2-systems/.venv/bin/activate'
EOF

    log "oh-my-zsh + plugins"
    if [ ! -d "$OMZ_DIR" ]; then
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes ZSH="$OMZ_DIR" \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    fi
    local OMZ_PLUGINS="$OMZ_DIR/custom/plugins"
    mkdir -p "$OMZ_PLUGINS"
    [ -d "$OMZ_PLUGINS/zsh-autosuggestions" ] || \
        git clone --quiet https://github.com/zsh-users/zsh-autosuggestions "$OMZ_PLUGINS/zsh-autosuggestions"
    [ -d "$OMZ_PLUGINS/zsh-syntax-highlighting" ] || \
        git clone --quiet https://github.com/zsh-users/zsh-syntax-highlighting "$OMZ_PLUGINS/zsh-syntax-highlighting"

    log "write shell rc files"
    # .zshenv sourced for every zsh invocation — covers `ssh sandy@pod 'cmd'`.
    cat > ~/.zshenv <<EOF
$MARKER
[ -f $SHELLRC ] && source $SHELLRC
EOF
    cat > ~/.zshrc <<EOF
$MARKER
export ZSH_DISABLE_COMPFIX=true
export ZSH="$OMZ_DIR"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source \$ZSH/oh-my-zsh.sh
EOF
    if ! grep -qF "$MARKER" ~/.bashrc 2>/dev/null; then
        cat >> ~/.bashrc <<EOF

$MARKER
[ -f $SHELLRC ] && source $SHELLRC
EOF
    fi
    if ! grep -qF "$MARKER" ~/.profile 2>/dev/null; then
        cat >> ~/.profile <<EOF

$MARKER
[ -f $SHELLRC ] && source $SHELLRC
EOF
    fi

    log "caches"
    mkdir -p "$WORKSPACE/.cache/"{huggingface,pip,uv,torch,triton,flashinfer,sglang_jit}
    export HF_HOME=/workspace/.cache/huggingface
    export PIP_CACHE_DIR=/workspace/.cache/pip
    export UV_CACHE_DIR=/workspace/.cache/uv
    export TRITON_CACHE_DIR=/workspace/.cache/triton
    export XDG_CACHE_HOME=/workspace/.cache
    export FLASHINFER_WORKSPACE_BASE=/workspace/.cache/flashinfer
    export SGLANG_JIT_CACHE_DIR=/workspace/.cache/sglang_jit

    # One-time migration: legacy shared /workspace/venv (sglang-only) -> new layout.
    if [ -d "$WORKSPACE/venv" ] && [ ! -L "$WORKSPACE/venv" ] && [ ! -d "$SGLANG_VENV" ]; then
        log "     migrate /workspace/venv -> $SGLANG_VENV"
        mv "$WORKSPACE/venv" "$SGLANG_VENV"
    fi
}

# ---------- helpers ----------

# common_clone_repo FORK_URL UPSTREAM_URL TARGET_DIR
common_clone_repo() {
    local fork="$1" upstream="$2" dir="$3"
    if [ ! -d "$dir/.git" ]; then
        git clone "$fork" "$dir"
    fi
    cd "$dir"
    git remote | grep -q '^upstream$' || git remote add upstream "$upstream"
}

# common_checkout_branch REPO_DIR BRANCH
# Assumes cwd==repo dir. Skips fetch when SKIP_FETCH=1.
common_checkout_branch() {
    local dir="$1" branch="$2"
    cd "$dir"
    if [ "${SKIP_FETCH:-0}" != "1" ]; then
        git fetch --all --quiet
    fi
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch"
        git pull --ff-only origin "$branch" 2>/dev/null || true
    elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git checkout -b "$branch" "origin/$branch"
    else
        git checkout -b "$branch"
    fi
}

# common_make_venv PATH — creates venv if missing, activates it, ensures uv.
common_make_venv() {
    local venv="$1"
    if [ ! -f "$venv/bin/activate" ]; then
        python3 -m venv "$venv"
        # shellcheck disable=SC1091
        source "$venv/bin/activate"
        pip install --quiet --upgrade pip wheel setuptools
        pip install --quiet uv
    else
        # shellcheck disable=SC1091
        source "$venv/bin/activate"
        command -v uv >/dev/null 2>&1 || pip install --quiet uv
    fi
}

# common_write_active_env FRAMEWORK
common_write_active_env() {
    echo "$1" > "$ACTIVE_ENV_FILE"
}

common_install_claude_code() {
    log "claude code"
    mkdir -p "$NPM_PREFIX"
    npm config set prefix "$NPM_PREFIX" >/dev/null
    export PATH="$NPM_PREFIX/bin:$PATH"
    if [ ! -x "$NPM_PREFIX/bin/claude" ]; then
        npm install -g --silent @anthropic-ai/claude-code
    fi
    mkdir -p /workspace/.claude
    # Default settings.json: enable auto mode so sandy isn't prompt-spammed on
    # a fresh pod. Only writes when missing — never clobbers existing config.
    if [ ! -s /workspace/.claude/settings.json ]; then
        cat > /workspace/.claude/settings.json <<'JSON'
{
  "theme": "auto",
  "autoUpdatesChannel": "stable",
  "permissions": {
    "defaultMode": "auto"
  }
}
JSON
    fi
    [ -e /workspace/.claude.json ] || echo '{}' > /workspace/.claude.json
    if [ ! -L ~/.claude ]; then
        [ -e ~/.claude ] && rm -rf ~/.claude
        ln -s /workspace/.claude ~/.claude
    fi
    if [ ! -L ~/.claude.json ]; then
        [ -e ~/.claude.json ] && rm -f ~/.claude.json
        ln -s /workspace/.claude.json ~/.claude.json
    fi
}

# common_final_summary FRAMEWORK VENV REPO
common_final_summary() {
    local fw="$1" venv="$2" repo="$3"
    log "done!"
    echo "  user:      sandy (password: 1, passwordless sudo)"
    echo "  framework: $fw"
    echo "  repo:      $repo ($(git -C "$repo" branch --show-current))"
    echo "  venv:      $venv"
    # Import check from /tmp: /workspace contains a `vllm/` subdir (git repo)
    # which PEP 420 picks up as a namespace package shadowing site-packages.
    case "$fw" in
        sglang)      echo "  sanity:    $(cd /tmp && "$venv/bin/python" -c 'import sglang; print("(sglang ok)")' 2>/dev/null || echo '(sglang import FAILED)')" ;;
        vllm)        echo "  sanity:    $(cd /tmp && "$venv/bin/python" -c 'import vllm, vllm.envs; print("(vllm ok)")' 2>/dev/null || echo '(vllm import FAILED)')" ;;
        assignment2) echo "  sanity:    $(cd /tmp && "$venv/bin/python" -c 'import torch, cs336_systems; print("(assignment2 ok)")' 2>/dev/null || echo '(assignment2 import FAILED)')" ;;
    esac
    echo "  switch:    activate-sglang | activate-vllm | activate-assignment2   (in a new shell)"
    echo "  claude:    $(command -v claude || echo "$NPM_PREFIX/bin/claude")"
    local GH_TOKEN_FILE=/workspace/.gh_token
    if [ ! -s "$GH_TOKEN_FILE" ]; then
        echo "  [!] gh token missing at $GH_TOKEN_FILE — gh CLI will be unauthenticated."
        echo "      Fetch one: https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=pod"
        echo "      Save:      echo -n '<token>' > $GH_TOKEN_FILE && chmod 600 $GH_TOKEN_FILE"
    fi
}
