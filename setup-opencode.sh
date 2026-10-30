cat <<'EOF' > setup.sh
#!/bin/bash
set -e

echo "Updating package list and installing dependencies..."
sudo apt update && sudo apt install -y ripgrep fzf curl

mkdir -p ~/Downloads ~/.local/share/applications ~/Desktop
cd ~/Downloads

echo ""
echo "Select software to install:"
echo "1) OpenCode"
echo "2) FreeBuff"
echo "3) Both"
read -p "Enter choice [1-3]: " CHOICE

install_opencode() {
  echo "Downloading OpenCode..."
  curl -LO "https://opencode.ai/download/stable/linux-x64-deb"
  
  echo "Installing OpenCode package..."
  sudo dpkg -i linux-x64-deb || sudo apt --fix-broken install -y

  echo "Writing OpenCode configuration..."
  mkdir -p ~/.config/opencode
  cat > ~/.config/opencode/opencode.json <<'CONFIGEOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "apinex/gpt-6.1-sol",
  "provider": {
    "apinex": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "APInex",
      "options": {
        "baseURL": "https://api.apinex.bond/v1",
        "apiKey": "dummy-key-to-bypass"
      },
      "models": {
        "gpt-6.1-sol": { "name": "GPT 6.1 Sol" },
        "claude-sonnet-5.5": { "name": "Claude Sonnet 5.5" },
        "free/kimi-k3": { "name": "Kimi K3 (Free)" }
      }
    }
  }
}
CONFIGEOF

  echo "Creating OpenCode desktop launcher..."
  cat > ~/.local/share/applications/opencode.desktop <<'DESKEOF'
[Desktop Entry]
Name=OpenCode
Comment=OpenCode AI Desktop App
Exec=ai.opencode --no-sandbox
Terminal=false
Type=Application
Categories=Development;
Icon=opencode
DESKEOF

  chmod +x ~/.local/share/applications/opencode.desktop
  cp ~/.local/share/applications/opencode.desktop ~/Desktop/
  chmod +x ~/Desktop/opencode.desktop
  gio set ~/Desktop/opencode.desktop metadata::trusted true 2>/dev/null || true
}

install_freebuff() {
  echo "Downloading FreeBuff..."
  ARCH=$(uname -m)
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
      curl -L "https://freebuff.com/api/desktop/download/linux-arm64" -o freebuff.deb
  else
      curl -L "https://freebuff.com/api/desktop/download/linux" -o freebuff.deb
  fi

  echo "Installing FreeBuff package..."
  sudo dpkg -i freebuff.deb || sudo apt --fix-broken install -y

  echo "Creating FreeBuff desktop launcher..."
  cat > ~/.local/share/applications/freebuff.desktop <<'FBEOF'
[Desktop Entry]
Name=FreeBuff
Comment=FreeBuff Desktop App
Exec=freebuff --no-sandbox
Terminal=false
Type=Application
Categories=Utility;
Icon=freebuff
FBEOF

  chmod +x ~/.local/share/applications/freebuff.desktop
  cp ~/.local/share/applications/freebuff.desktop ~/Desktop/
  chmod +x ~/Desktop/freebuff.desktop
  gio set ~/Desktop/freebuff.desktop metadata::trusted true 2>/dev/null || true
}

case $CHOICE in
  1)
    install_opencode
    echo "Setup finished! Launching OpenCode..."
    ai.opencode --no-sandbox
    ;;
  2)
    install_freebuff
    echo "Setup finished! Launching FreeBuff..."
    freebuff --no-sandbox
    ;;
  3)
    install_opencode
    install_freebuff
    echo "Setup finished! Launching OpenCode..."
    ai.opencode --no-sandbox
    ;;
  *)
    echo "Invalid choice. Exiting."
    exit 1
    ;;
esac
EOF
