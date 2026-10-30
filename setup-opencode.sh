cat <<'EOF' > setup-opencode.sh
#!/bin/bash
set -e

echo "Updating package list and installing dependencies..."
sudo apt update && sudo apt install -y ripgrep fzf

echo "Downloading OpenCode..."
cd ~/Downloads
curl -LO "https://opencode.ai/download/stable/linux-x64-deb"

echo "Installing OpenCode package..."
sudo dpkg -i linux-x64-deb || sudo apt --fix-broken install -y

echo "Writing configuration file..."
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

echo "Creating desktop app launcher..."
mkdir -p ~/.local/share/applications ~/Desktop
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

echo "Setup finished! Launching..."
ai.opencode --no-sandbox
EOF
