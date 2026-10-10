#!/usr/bin/env bash
# Install the published Maxa runtime's Linux dependencies inside a test WSL.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash ~/.config/nvim/install.sh [--proxy <http(s) URL>]

Run as the target WSL's normal user (sudo access required).
Supports Ubuntu 24.04, x86_64 and aarch64. Installs system tools, Neovim,
Node.js, pnpm, uv, repository Python/Node dependencies, Chromium, Obsidian and
Syncthing. Enables the Obsidian CLI and the Obsidian/Syncthing user services
when systemd is available. Syncthing's GUI listens on 127.0.0.1:8384 only.
Does not register project Vaults, add sync folders/devices, configure Maxa's
startup entrypoint or start Windows/Telegram services.
Existing .env is preserved; a missing .env is initialized from .env.example.
Without --proxy, all installation downloads use direct connections.
--proxy explicitly selects one HTTP(S) proxy for this installation only.
Inherited proxy variables and project .env are not used for proxy selection.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
PROXY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --proxy)
      [[ $# -ge 2 && "$2" =~ ^https?://[^[:space:]]+$ ]] || fail '--proxy requires a nonempty HTTP(S) URL.'
      PROXY="$2"
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

# Script-local routing: neither the caller environment nor .env selects a proxy.
export ALL_PROXY="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
export all_proxy="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY"
export NO_PROXY="" no_proxy="" npm_config_noproxy="" NPM_CONFIG_NOPROXY=""
export npm_config_proxy="$PROXY" npm_config_https_proxy="$PROXY"
export NPM_CONFIG_PROXY="$PROXY" NPM_CONFIG_HTTPS_PROXY="$PROXY"
if [[ -z "$PROXY" ]]; then
  export NO_PROXY='*' no_proxy='*' npm_config_noproxy='*' NPM_CONFIG_NOPROXY='*'
  export NODE_USE_ENV_PROXY=0
else
  export NODE_USE_ENV_PROXY=1
fi
APT_PROXY="${PROXY:-DIRECT}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ $EUID != 0 ]] || fail 'Run as the target Linux user, not root or sudo bash.'
grep -qi microsoft /proc/sys/kernel/osrelease || fail 'This installer is for WSL only.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || fail 'Ubuntu 24.04 is required.'
[[ "$ROOT" == "$(realpath -m -- "$HOME/.config/nvim")" ]] || fail 'Install the snapshot in ~/.config/nvim first.'
[[ -f "$ROOT/bundled/mcp-hub/package-lock.json" ]] || fail 'Missing bundled MCPHub lockfile.'
case "$(uname -m)" in
  x86_64) NODE_ARCH=x64; NVIM_ARCH=x86_64; UV_ARCH=x86_64 ;;
  aarch64) NODE_ARCH=arm64; NVIM_ARCH=arm64; UV_ARCH=aarch64 ;;
  *) fail 'Only x86_64 and aarch64 are supported.' ;;
esac

sudo -v
APT=(sudo apt-get -o "Acquire::http::Proxy=$APT_PROXY" -o "Acquire::https::Proxy=$APT_PROXY")
"${APT[@]}" update
"${APT[@]}" install -y ca-certificates curl git unzip xz-utils build-essential \
  python3 python3-venv ripgrep fd-find jq just tmux file openssl syncthing \
  ffmpeg poppler-utils xclip wl-clipboard xvfb xauth \
  libgtk-3-0t64 libnss3 libasound2t64 libgbm1

WORK="$(mktemp -d)"
trap 'rm -r -- "$WORK"' EXIT
fetch() { curl --fail --location --retry 3 --proxy "$PROXY" "$1" -o "$2"; }
sudo mkdir -p /opt/maxa /usr/local/bin
export PATH="/usr/local/bin:$PATH"
hash -r

# Ubuntu's Neovim package is older than Maxa's required 0.11+.
if ! command -v nvim >/dev/null || ! nvim --headless -u NONE '+lua if vim.fn.has("nvim-0.11") == 0 then vim.cmd("cquit 1") end' +qa >/dev/null 2>&1; then
  NVIM_TAR="nvim-linux-$NVIM_ARCH.tar.gz"
  fetch "https://github.com/neovim/neovim/releases/latest/download/$NVIM_TAR" "$WORK/$NVIM_TAR"
  sudo tar -xzf "$WORK/$NVIM_TAR" -C /opt/maxa
  sudo ln -sfn "/opt/maxa/nvim-linux-$NVIM_ARCH/bin/nvim" /usr/local/bin/nvim
fi

# NODE_OPTIONS=--use-env-proxy appears in the published MCP definitions.
if ! command -v npm >/dev/null || ! node --use-env-proxy -e 'if (Number(process.versions.node.split(".")[0]) < 24) process.exit(1)' >/dev/null 2>&1; then
  fetch https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt "$WORK/SHASUMS256.txt"
  NODE_TAR="$(awk -v arch="$NODE_ARCH" '$2 ~ ("^node-v24\\.[0-9]+\\.[0-9]+-linux-" arch "\\.tar\\.xz$") {print $2}' "$WORK/SHASUMS256.txt")"
  [[ -n "$NODE_TAR" && "$NODE_TAR" != *$'\n'* ]] || fail 'Could not resolve the Node.js 24 LTS archive.'
  fetch "https://nodejs.org/dist/latest-v24.x/$NODE_TAR" "$WORK/$NODE_TAR"
  (cd "$WORK"; grep -F "  $NODE_TAR" SHASUMS256.txt | sha256sum -c -)
  sudo tar -xJf "$WORK/$NODE_TAR" -C /opt/maxa
  NODE_DIR="/opt/maxa/${NODE_TAR%.tar.xz}"
  for tool in node npm npx; do sudo ln -sfn "$NODE_DIR/bin/$tool" "/usr/local/bin/$tool"; done
fi
hash -r

if ! command -v uv >/dev/null || ! command -v uvx >/dev/null; then
  UV_TAR="uv-$UV_ARCH-unknown-linux-gnu.tar.gz"
  fetch "https://github.com/astral-sh/uv/releases/latest/download/$UV_TAR" "$WORK/$UV_TAR"
  tar -xzf "$WORK/$UV_TAR" -C "$WORK"
  sudo install -m 755 "$WORK/uv-$UV_ARCH-unknown-linux-gnu/uv" /usr/local/bin/uv
  sudo install -m 755 "$WORK/uv-$UV_ARCH-unknown-linux-gnu/uvx" /usr/local/bin/uvx
fi
if ! command -v pnpm >/dev/null || [[ "$(pnpm --version)" != 10.* ]]; then
  sudo env "PATH=$PATH" "npm_config_proxy=$HTTP_PROXY" "npm_config_https_proxy=$HTTPS_PROXY" "npm_config_noproxy=$NO_PROXY" \
    npm install --global --prefix /usr/local pnpm@10
fi

# Ability Python environments belong to their individual uv projects.
# Python 3.12 also satisfies the protected browser backend's <3.13 constraint.
uv python install 3.12
for parent in abilities tools; do
  while IFS= read -r -d '' manifest; do
    project="$(dirname -- "$manifest")"
    if [[ -f "$project/uv.lock" ]]; then
      uv sync --project "$project" --python 3.12 --no-dev --locked
    else
      uv sync --project "$project" --python 3.12 --no-dev
    fi
  done < <(find "$ROOT/$parent" -mindepth 2 -maxdepth 2 -name pyproject.toml -print0)
done

install_node_project() {
  local project="$1"
  [[ -f "$project/package.json" ]] || fail "Missing package.json: $project"
  if [[ -f "$project/pnpm-lock.yaml" ]]; then
    (cd "$project"; pnpm install --frozen-lockfile)
  elif [[ -f "$project/package-lock.json" ]]; then
    (cd "$project"; npm ci)
  else
    fail "Missing Node lockfile: $project"
  fi
}
install_node_project "$ROOT/bundled/mcp-hub"
node "$ROOT/bundled/mcp-hub/disable-marketplace.cjs"
node "$ROOT/bundled/mcp-hub/disable-marketplace.cjs" --check
install_node_project "$ROOT/mcp-servers/browser"
install_node_project "$ROOT/mcp-servers/replicate"
install_node_project "$ROOT/tools/chat-upload"
(cd "$ROOT/tools/chat-upload"; npm run build)

# Vendor Node dependencies used by web-fetch, when present in the snapshot.
while IFS= read -r -d '' manifest; do
  install_node_project "$(dirname -- "$manifest")"
done < <(find "$ROOT/abilities/web-fetch/vendor" -mindepth 2 -maxdepth 2 -name package.json -print0)

# These are separately hosted plugins, but their build dependencies ship here.
for project in "$ROOT"/obsidian-plugins/*; do
  [[ -f "$project/package.json" && "$(basename -- "$project")" != _reference ]] || continue
  install_node_project "$project"
  (cd "$project"; npm run build --if-present)
done

# The web-fetch manifest includes base Scrapling, but browser fetchers need
# its optional dependencies. Keep the manifest's resolved Scrapling version.
WEB_FETCH="$ROOT/abilities/web-fetch"
SCRAPLING_VERSION="$(uv run --no-sync --project "$WEB_FETCH" python -c 'from importlib.metadata import version; print(version("scrapling"))')"
uv pip install --python "$WEB_FETCH/.venv/bin/python" "scrapling[fetchers]==$SCRAPLING_VERSION"
# Install system libraries as root, browsers/cache as the test user. Pass the
# proxy explicitly through sudo and prevent root-owned bytecode in the user venv.
sudo env "PATH=$PATH" "http_proxy=$HTTP_PROXY" "https_proxy=$HTTPS_PROXY" "no_proxy=$NO_PROXY" "PYTHONDONTWRITEBYTECODE=1" \
  uv run --no-sync --project "$WEB_FETCH" python -m playwright install-deps chromium
uv run --no-sync --project "$WEB_FETCH" python -m playwright install chromium
(cd "$ROOT/mcp-servers/browser"; pnpm exec agent-browser install)

# Obsidian installation is runtime setup, independent of project Vault identity.
OBSIDIAN_DIR="$HOME/.local/opt/obsidian"
OBSIDIAN_BIN="$HOME/.local/bin/obsidian"
OBSIDIAN_SUFFIX=""
[[ "$UV_ARCH" != aarch64 ]] || OBSIDIAN_SUFFIX="-arm64"
fetch https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest "$WORK/obsidian-release.json"
OBSIDIAN_VERSION="$(jq -er '.tag_name | ltrimstr("v")' "$WORK/obsidian-release.json")"
[[ "$OBSIDIAN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Invalid Obsidian release version.'
OBSIDIAN_ASSET="Obsidian-$OBSIDIAN_VERSION$OBSIDIAN_SUFFIX.AppImage"
OBSIDIAN_URL="$(jq -er --arg name "$OBSIDIAN_ASSET" '.assets[] | select(.name == $name) | .browser_download_url' "$WORK/obsidian-release.json")"
[[ "$OBSIDIAN_URL" == "https://github.com/obsidianmd/obsidian-releases/releases/download/"* ]] || fail 'Missing official Obsidian AppImage asset.'
mkdir -p "$OBSIDIAN_DIR" "$HOME/.local/bin"
if [[ ! -x "$OBSIDIAN_DIR/$OBSIDIAN_ASSET" ]]; then
  fetch "$OBSIDIAN_URL" "$WORK/Obsidian.AppImage"
  install -m 755 "$WORK/Obsidian.AppImage" "$OBSIDIAN_DIR/$OBSIDIAN_ASSET"
fi
ln -sfn "$OBSIDIAN_ASSET" "$OBSIDIAN_DIR/Obsidian.AppImage"
cat > "$OBSIDIAN_BIN" <<'WRAPPER'
#!/usr/bin/env bash
# Headless CLI launch; extraction avoids requiring a WSL FUSE mount.
export APPIMAGE_EXTRACT_AND_RUN=1
exec /usr/bin/xvfb-run --auto-servernum "$HOME/.local/opt/obsidian/Obsidian.AppImage" --no-sandbox "$@"
WRAPPER
chmod +x "$OBSIDIAN_BIN"
sudo ln -sfn "$OBSIDIAN_BIN" /usr/local/bin/obsidian
hash -r

# Enable CLI without creating or retargeting any project Vault registration.
OBSIDIAN_CONFIG="$HOME/.config/obsidian/obsidian.json"
mkdir -p "$(dirname -- "$OBSIDIAN_CONFIG")"
if [[ -f "$OBSIDIAN_CONFIG" ]]; then
  jq 'if type == "object" then .cli = true else error("Invalid Obsidian configuration") end' \
    "$OBSIDIAN_CONFIG" > "$WORK/obsidian.json"
else
  printf '{"vaults": {}, "cli": true}\n' > "$WORK/obsidian.json"
fi
install -m 600 "$WORK/obsidian.json" "$OBSIDIAN_CONFIG"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/obsidian.service" <<'SERVICE'
[Unit]
Description=Obsidian (headless via Xvfb for CLI)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/obsidian
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SERVICE
if systemctl --user daemon-reload; then
  systemctl --user enable obsidian
  systemctl --user restart obsidian
else
  printf 'WARNING: Obsidian installed, but its headless service was not started.\n' >&2
  printf 'Enable WSL systemd, then run: systemctl --user daemon-reload && systemctl --user enable --now obsidian\n' >&2
fi
printf 'Obsidian %s installed; project Vault registration remains an explicit ProjectAdmin operation.\n' "$OBSIDIAN_VERSION"

# Syncthing installation starts the WSL service, not project/device registration.
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/syncthing.service" <<'SERVICE'
[Unit]
Description=Syncthing - File Synchronization
Documentation=man:syncthing(1)
After=network.target

[Service]
ExecStart=/usr/bin/syncthing serve --no-browser --no-restart --no-default-folder --gui-address=127.0.0.1:8384
Restart=on-failure
RestartSec=10
SuccessExitStatus=3 4
RestartForceExitStatus=3 4

[Install]
WantedBy=default.target
SERVICE
if systemctl --user daemon-reload; then
  systemctl --user enable syncthing
  systemctl --user restart syncthing
  systemctl --user is-active --quiet syncthing || fail 'Syncthing service is not active. Check: journalctl --user -u syncthing'
  printf 'Syncthing service started; GUI: http://127.0.0.1:8384. Project folders/devices require explicit setup.\n'
else
  printf 'WARNING: Syncthing installed, but its user service was not started.\n' >&2
  printf 'Enable WSL systemd, then run: systemctl --user daemon-reload && systemctl --user enable --now syncthing\n' >&2
fi

# Register only local launchers. Never start Windows/Telegram services here.
if [[ -f "$ROOT/tools/wingui/runwingui" ]]; then
  sudo ln -sfn "$ROOT/tools/wingui/runwingui" /usr/local/bin/runwingui
fi
if [[ ! -e "$ROOT/.env" && -f "$ROOT/.env.example" ]]; then
  install -m 600 "$ROOT/.env.example" "$ROOT/.env"
fi

nvim --version | head -n 3
node --version
uv --version
syncthing --version
printf '\nDependencies installed. Configure %s/.env, then start nvim.\n' "$ROOT"
printf 'Maxa startup configuration is intentionally not changed by this installer.\n'
