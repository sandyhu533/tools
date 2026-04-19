#!/usr/bin/env bash
# Idempotent bootstrap for RunPod (or any cloud GPU pod).
# Usage: bash /workspace/pod_bootstrap.sh    (must start as root)
# Safe to re-run after every pod rebuild — skips work already done.
#
# Structure:
#   phase 0 — must run as root: apt, nodejs, create sandy, one-time chown,
#             then exec'd handoff to sandy via `sudo -u sandy`.
#   phase 1..7 — runs as sandy so every file created (venv, repo, caches) is
#             owned by sandy from birth, no recursive chown needed.

set -euo pipefail

WORKSPACE=/workspace
FORK_REPO="https://github.com/sandyhu533/sglang.git"
UPSTREAM_REPO="https://github.com/sgl-project/sglang.git"
# DEV_BRANCH="experiment/ttft-22831-ablation"
# DEV_BRANCH="sandy/lora-scheduler-crash-fix"
DEV_BRANCH="sandy/fix-scheduler-ttft-hol"
REPO_DIR="$WORKSPACE/sglang"
VENV_DIR="$WORKSPACE/venv"
OMZ_DIR="$WORKSPACE/.oh-my-zsh"
SHELLRC="$WORKSPACE/.shellrc"
NPM_PREFIX="$WORKSPACE/.npm-global"
# sandy's home lives on the persistent volume so shell history, dotfiles,
# venv configs, etc. survive pod rebuilds.
SANDY_HOME="$WORKSPACE/home/sandy"
MARKER="# === cloudgpu bootstrap ==="

log() { echo -e "\033[1;34m[bootstrap]\033[0m $*"; }

# ---------- 0. root phase: apt + nodejs + sandy user, then hand off ----------
if [ "$(id -u)" = "0" ]; then
    log "0/7 root phase (apt + node + sandy)"

    # -- apt tools (zsh + runtime libs + sudo) --
    APT_TOOLS=(zsh git curl tmux htop gpg sudo)
    MISSING=()
    for t in "${APT_TOOLS[@]}"; do command -v "$t" >/dev/null 2>&1 || MISSING+=("$t"); done
    # libnuma is a shared library, not a binary — probe via ldconfig. sgl_kernel's
    # common_ops.so dlopens libnuma.so.1 during sglang startup and fails silently
    # otherwise, falling back to a less-capable variant (breaks first-time import).
    NEED_NUMA=0
    ldconfig -p 2>/dev/null | grep -q 'libnuma\.so\.1' || NEED_NUMA=1
    if [ "${#MISSING[@]}" -gt 0 ] || [ "$NEED_NUMA" = "1" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq zsh git curl tmux htop ca-certificates gnupg libnuma1 sudo
    fi

    # -- Node.js 20.x via NodeSource (apt package — reinstalled each pod rebuild) --
    # Installed up here in the root phase so sandy doesn't need sudo later.
    if ! command -v node >/dev/null 2>&1; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null
        apt-get install -y -qq nodejs
    fi

    # -- GitHub CLI via official apt repo (signed) --
    # Install in root phase so sandy doesn't need sudo later. Auth is handled via
    # $GH_TOKEN picked up from /workspace/.gh_token in shellrc (see phase 1).
    if ! command -v gh >/dev/null 2>&1; then
        GH_KEYRING=/usr/share/keyrings/githubcli-archive-keyring.gpg
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | dd of="$GH_KEYRING" status=none
        chmod go+r "$GH_KEYRING"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=$GH_KEYRING] https://cli.github.com/packages stable main" \
            > /etc/apt/sources.list.d/github-cli.list
        apt-get update -qq
        apt-get install -y -qq gh
    fi

    # -- sandy user (password=1, zsh login shell, passwordless sudo) --
    # Each block is independently idempotent so a pre-existing sandy (wrong
    # shell, wrong home, no sudoers, no password) gets brought up to spec.
    # -M => useradd doesn't try to mkdir the home; we build it below as sandy
    # so the dir ends up sandy-owned (chown fails on the shared /workspace mount).
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

    # -- sandy home dir on /workspace (persistent across pod rebuilds) --
    # Shared volume: root can't chown, so the dir's creator owns it. Create
    # as sandy. mkdir -p walks up, creating /workspace/home as sandy too
    # (/workspace itself is 777, so sandy can mkdir inside it).
    if [ ! -d "$SANDY_HOME" ]; then
        sudo -u sandy mkdir -p "$SANDY_HOME"
        # Seed skeleton dotfiles (bash defaults); cp -n keeps any pre-existing.
        for f in /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout; do
            [ -f "$f" ] && sudo -u sandy cp -n "$f" "$SANDY_HOME/" 2>/dev/null || true
        done
    fi

    # -- SSH: let sandy be reached directly by copying root's authorized_keys --
    # RunPod only provisions root's keys, so without this step `ssh sandy@pod`
    # fails. Merge (not overwrite) so keys added manually to sandy survive.
    if [ -f /root/.ssh/authorized_keys ]; then
        SANDY_SSH="$SANDY_HOME/.ssh"
        sudo -u sandy mkdir -p "$SANDY_SSH"
        sudo -u sandy touch "$SANDY_SSH/authorized_keys"
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            sudo -u sandy grep -qxF -- "$key" "$SANDY_SSH/authorized_keys" 2>/dev/null \
                || echo "$key" | sudo -u sandy tee -a "$SANDY_SSH/authorized_keys" >/dev/null
        done < /root/.ssh/authorized_keys
        sudo -u sandy chmod 700 "$SANDY_SSH" 2>/dev/null || true
        sudo -u sandy chmod 600 "$SANDY_SSH/authorized_keys" 2>/dev/null || true
    fi

    # -- sshd: disable StrictModes --
    # /workspace is a shared volume that forces 666/777 regardless of chmod, so
    # sandy's authorized_keys stays 666 and her home is 777; sshd's default
    # StrictModes=yes rejects both. OpenSSH doesn't allow StrictModes inside
    # Match blocks, so this has to be global. Acceptable on a single-user dev pod.
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
            # SIGHUP makes sshd re-read config without dropping existing sessions.
            pkill -HUP -f '^sshd:' 2>/dev/null || pkill -HUP sshd 2>/dev/null || true
        else
            log "     sshd -t failed after StrictModes edit; reverting"
            sed -i -e '/^# sandy.s home is on a shared/,/^StrictModes no$/d' "$SSHD_TARGET"
        fi
    fi

    # -- one-time /workspace chown (only if the mount permits it) --
    # On RunPod /workspace is a shared volume where chown returns EPERM; the
    # volume is already world-rwx so sandy can r/w without owning it. Probe
    # chown on the root dir first; if EPERM, skip the recursive walk.
    CHOWN_MARKER=/workspace/.sandy-ownership
    if [ ! -f "$CHOWN_MARKER" ]; then
        if chown sandy:sandy /workspace 2>/dev/null; then
            log "     chown /workspace -> sandy (first run only)"
            chown -R sandy:sandy /workspace
            touch "$CHOWN_MARKER"
            chown sandy:sandy "$CHOWN_MARKER"
        else
            log "     /workspace chown not permitted (shared volume); skipping — 777 perms let sandy r/w anyway"
            touch "$CHOWN_MARKER" 2>/dev/null || true
        fi
    fi

    # -- hand off to sandy for the rest of the script --
    log "     handoff -> sandy"
    exec sudo -u sandy -H env "SKIP_FETCH=${SKIP_FETCH:-0}" bash "$0"
fi

if [ "$(id -un)" != "sandy" ]; then
    echo "[bootstrap] must be invoked as root or sandy (current: $(id -un))" >&2
    exit 1
fi

# Shared /workspace mount may still hold files from prior root-run bootstraps.
# Tell git not to bail on "dubious ownership" for any repo under /workspace.
git config --global --get-all safe.directory 2>/dev/null | grep -qxF '*' \
    || git config --global --add safe.directory '*'

# ---------- 1. shared shell config (sourced by both bash & zsh) ----------
log "1/7 write $SHELLRC"
cat > "$SHELLRC" <<'EOF'
# Shared by bash and zsh. Persisted on /workspace.
# Keep every cache on the persistent network volume so / (20GB overlay) stays clean
# and pod rebuilds don't have to re-download models / wheels / compiled kernels.
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
# gh CLI auth: token lives on persistent volume (chmod 600), not in this file.
[ -f /workspace/.gh_token ] && export GH_TOKEN="$(cat /workspace/.gh_token)"
cd /workspace 2>/dev/null || true
if [ -f /workspace/venv/bin/activate ]; then
    # shellcheck disable=SC1091
    source /workspace/venv/bin/activate
fi
EOF

# ---------- 2. oh-my-zsh + plugins (on /workspace, one-time) ----------
log "2/7 oh-my-zsh + plugins"
if [ ! -d "$OMZ_DIR" ]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes ZSH="$OMZ_DIR" \
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
OMZ_PLUGINS="$OMZ_DIR/custom/plugins"
mkdir -p "$OMZ_PLUGINS"
[ -d "$OMZ_PLUGINS/zsh-autosuggestions" ] || \
    git clone --quiet https://github.com/zsh-users/zsh-autosuggestions "$OMZ_PLUGINS/zsh-autosuggestions"
[ -d "$OMZ_PLUGINS/zsh-syntax-highlighting" ] || \
    git clone --quiet https://github.com/zsh-users/zsh-syntax-highlighting "$OMZ_PLUGINS/zsh-syntax-highlighting"

# ---------- 3. ~/.zshenv + ~/.zshrc + ~/.bashrc + ~/.profile ----------
log "3/7 write shell rc files"
# .zshenv is sourced for *every* zsh invocation (login, interactive, -c cmd,
# scripts), so putting shellrc here covers `ssh sandy@pod 'cmd'` which sshd
# launches as a non-login non-interactive zsh.
cat > ~/.zshenv <<EOF
$MARKER
[ -f $SHELLRC ] && source $SHELLRC
EOF
# .zshrc — interactive-only stuff (theme, plugins, completions).
cat > ~/.zshrc <<EOF
$MARKER
# /workspace is forced to 666/777 by the shared volume; oh-my-zsh's compfix
# warns loudly on world-writable paths. Disable the check since we can't chmod.
export ZSH_DISABLE_COMPFIX=true
export ZSH="$OMZ_DIR"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source \$ZSH/oh-my-zsh.sh
EOF
# bash: .bashrc for interactive, .profile for login (covers ssh sandy@pod 'cmd').
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

# ---------- 4. venv + repo ----------
log "4/7 caches, venv, repo"
mkdir -p "$WORKSPACE/.cache/"{huggingface,pip,uv,torch,triton,flashinfer,sglang_jit}
export HF_HOME=/workspace/.cache/huggingface
export PIP_CACHE_DIR=/workspace/.cache/pip
export UV_CACHE_DIR=/workspace/.cache/uv
export TRITON_CACHE_DIR=/workspace/.cache/triton
export XDG_CACHE_HOME=/workspace/.cache
export FLASHINFER_WORKSPACE_BASE=/workspace/.cache/flashinfer
export SGLANG_JIT_CACHE_DIR=/workspace/.cache/sglang_jit

FRESH_VENV=0
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    python3 -m venv "$VENV_DIR"
    FRESH_VENV=1
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
# Only upgrade pip/wheel/setuptools once per venv — PyPI phone-home takes
# ~5-10s each even when nothing changes, and the venv lives on /workspace so
# it persists across pod rebuilds.
if [ "$FRESH_VENV" = "1" ]; then
    pip install --quiet --upgrade pip wheel setuptools
fi
command -v uv >/dev/null 2>&1 || pip install --quiet uv

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$FORK_REPO" "$REPO_DIR"
fi
cd "$REPO_DIR"
git remote | grep -q '^upstream$' || git remote add upstream "$UPSTREAM_REPO"
# Fetch is opt-out via SKIP_FETCH=1 for quick re-runs that don't need remote state.
if [ "${SKIP_FETCH:-0}" != "1" ]; then
    git fetch --all --quiet
fi

if git show-ref --verify --quiet "refs/heads/$DEV_BRANCH"; then
    git checkout "$DEV_BRANCH"
    git pull --ff-only origin "$DEV_BRANCH" 2>/dev/null || true
elif git show-ref --verify --quiet "refs/remotes/origin/$DEV_BRANCH"; then
    git checkout -b "$DEV_BRANCH" "origin/$DEV_BRANCH"
else
    git checkout -b "$DEV_BRANCH"
fi

# ---------- 5. install sglang (editable) ----------
log "5/7 install sglang"
# Editable install drops sglang into $VENV/lib/.../site-packages as a pointer to
# /workspace/sglang/python, so local edits on the dev branch are picked up
# without reinstall. uv pip is ~5-10x faster than pip for this dependency set.
if ! python -c "import sglang" >/dev/null 2>&1; then
    uv pip install -e "$REPO_DIR/python"
fi

# ---------- 6. Claude Code (npm global on /workspace) ----------
log "6/7 claude code"
# Global npm packages go to /workspace so claude-code persists across rebuilds.
mkdir -p "$NPM_PREFIX"
npm config set prefix "$NPM_PREFIX" >/dev/null
export PATH="$NPM_PREFIX/bin:$PATH"

if [ ! -x "$NPM_PREFIX/bin/claude" ]; then
    npm install -g --silent @anthropic-ai/claude-code
fi

# Persist ~/.claude (auth + settings + history) by symlinking to /workspace.
mkdir -p /workspace/.claude
[ -e /workspace/.claude.json ] || echo '{}' > /workspace/.claude.json
if [ ! -L ~/.claude ]; then
    [ -e ~/.claude ] && rm -rf ~/.claude
    ln -s /workspace/.claude ~/.claude
fi
if [ ! -L ~/.claude.json ]; then
    [ -e ~/.claude.json ] && rm -f ~/.claude.json
    ln -s /workspace/.claude.json ~/.claude.json
fi

# ---------- 7. drop into sandy's interactive login shell ----------
log "7/7 done!"
echo "  user:   sandy (password: 1, passwordless sudo)"
echo "  repo:   $REPO_DIR ($(git branch --show-current))"
echo "  venv:   $VENV_DIR"
echo "  sglang: $(python -c 'import sglang, os; print(os.path.dirname(sglang.__file__))' 2>/dev/null || echo 'not installed')"
echo "  claude: $(command -v claude || echo "$NPM_PREFIX/bin/claude")"
echo
echo "Next steps (manual):"
echo "  claude                                         # first time: run /login"
# gh token lives on /workspace so it persists; warn loudly if it's missing
# (fresh volume, accidentally deleted). Token can't be auto-fetched — PATs
# only come from a logged-in browser session on github.com.
GH_TOKEN_FILE=/workspace/.gh_token
if [ ! -s "$GH_TOKEN_FILE" ]; then
    echo "  [!] gh token missing at $GH_TOKEN_FILE — gh CLI will be unauthenticated."
    echo "      Fetch one from the web:"
    echo "        https://github.com/settings/tokens/new?scopes=repo,workflow,read:org&description=pod"
    echo "      Then save it:"
    echo "        echo -n '<paste-token>' > $GH_TOKEN_FILE && chmod 600 $GH_TOKEN_FILE"
    echo "      New shells will auto-export it as \$GH_TOKEN."
fi
echo
log "launching zsh as sandy…"
exec zsh -l
