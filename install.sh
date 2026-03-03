#!/usr/bin/env sh
set -e

# ─── Helpers ──────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

ask() {
  printf "%s [y/N] " "$1"
  read -r ans
  case "$ans" in [yY]*) return 0;; *) return 1;; esac
}

is_mac()   { [ "$(uname)" = "Darwin" ]; }
is_linux() { [ "$(uname)" = "Linux" ]; }

# ─── Requirement checks ───────────────────────────────────────────────────────

missing=""

check() {
  local cmd="$1" label="$2"
  if ! have "$cmd"; then
    printf "  ✗ %s\n" "$label"
    missing="$missing $cmd"
  else
    printf "  ✓ %s\n" "$label"
  fi
}

echo ""
echo "Checking requirements…"
check curl       "curl"
check python3    "python3"
check jq         "jq"
check docker     "Docker"
check devcontainer "devcontainer CLI (@devcontainers/cli)"
check claude     "Claude Code"
echo ""

# ─── Install missing deps ─────────────────────────────────────────────────────

for cmd in $missing; do
  case "$cmd" in

    curl)
      echo "curl is required to run this script. Please install it manually."
      exit 1
      ;;

    python3)
      if is_mac && have brew; then
        ask "Install python3 via Homebrew?" && brew install python3
      elif is_linux && have apt-get; then
        ask "Install python3 via apt?" && sudo apt-get install -y python3
      else
        echo "Please install python3 manually: https://python.org"
      fi
      ;;

    jq)
      if is_mac && have brew; then
        ask "Install jq via Homebrew?" && brew install jq
      elif is_linux && have apt-get; then
        ask "Install jq via apt?" && sudo apt-get install -y jq
      else
        echo "Please install jq manually: https://jqlang.github.io/jq/"
      fi
      ;;

    docker)
      echo "Docker is required but not installed."
      if is_mac; then
        echo "→ Install Docker Desktop: https://docs.docker.com/desktop/mac/install/"
      else
        echo "→ Install Docker Engine: https://docs.docker.com/engine/install/"
      fi
      ;;

    devcontainer)
      if have npm; then
        ask "Install @devcontainers/cli via npm?" && npm install -g @devcontainers/cli
      elif have node; then
        echo "npm not found. Install Node.js first: https://nodejs.org"
      else
        echo "Node.js not found. Install it first: https://nodejs.org"
        echo "Then run: npm install -g @devcontainers/cli"
      fi
      ;;

    claude)
      ask "Install Claude Code via the native installer?" \
        && curl -fsSL https://claude.ai/install.sh | sh
      ;;

  esac
done

# Re-check after installs
still_missing=""
for cmd in $missing; do
  have "$cmd" || still_missing="$still_missing $cmd"
done

if [ -n "$still_missing" ]; then
  echo ""
  echo "⚠ Still missing:$still_missing"
  echo "Please install them and re-run this script."
  exit 1
fi

# ─── Install cc-yolo ──────────────────────────────────────────────────────────

BIN_DIR="${HOME}/.local/bin"
SCRIPT_URL="https://raw.githubusercontent.com/talpah/claude-code-yolo-in-devcontainers/main/cc-yolo.sh"

mkdir -p "$BIN_DIR"
curl -fsSL "$SCRIPT_URL" -o "$BIN_DIR/cc-yolo"
chmod +x "$BIN_DIR/cc-yolo"

# Ensure ~/.local/bin is on PATH
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
    echo "→ Added ~/.local/bin to PATH in $rc"
  fi
done

echo ""
echo "✓ Installed cc-yolo to $BIN_DIR/cc-yolo"
echo ""
echo "Reload your shell or run:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo ""
echo "Then cd into any project and run:"
echo "  cc-yolo"
