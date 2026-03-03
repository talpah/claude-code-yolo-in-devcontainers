#!/usr/bin/env sh
set -e

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

echo "✓ Installed cc-yolo to $BIN_DIR/cc-yolo"
echo ""
echo "Reload your shell or run:"
echo '  export PATH="$HOME/.local/bin:$PATH"'
echo ""
echo "Then cd into any project and run:"
echo "  cc-yolo"
