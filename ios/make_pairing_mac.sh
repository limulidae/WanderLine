#!/bin/bash
# 在 Mac 上產生 WanderLine 的「電腦配對檔」（跟 LocationLab 的 LL Pair 一樣的做法）。
# 有了它，WanderLine 出門只有 4G/5G 也能改位置。手機重設、更新 iOS 或「重置位置與隱私權」後要重新產生。
# 用法：iPhone 用傳輸線接上 Mac、解鎖，然後在 WanderLine 資料夾裡跑：bash ios/make_pairing_mac.sh
set -e
OUT="$HOME/Desktop/WanderLine-配對檔.plist"

if ! command -v brew >/dev/null; then
  echo "== 安裝 Homebrew（會要你輸入 Mac 的密碼）"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
if ! command -v pymobiledevice3 >/dev/null; then
  echo "== 安裝 pymobiledevice3（跟 iPhone 溝通的工具）"
  command -v pipx >/dev/null || brew install pipx
  pipx install pymobiledevice3
  export PATH="$HOME/.local/bin:$PATH"
fi

echo "== 配對：iPhone 跳出「要信任這部電腦嗎？」請按「信任」並輸入手機密碼"
pymobiledevice3 lockdown pair || true

echo "== 允許用網路連線（4G 時 WanderLine 靠這個連回手機自己）"
pymobiledevice3 lockdown wifi-connections on

echo "== 存配對檔"
pymobiledevice3 lockdown save-pair-record "$OUT"
UDID=$(pymobiledevice3 lockdown get --key UniqueDeviceID 2>/dev/null | tr -d '"[:space:]')
if [ -n "$UDID" ] && ! /usr/libexec/PlistBuddy -c "Print :UDID" "$OUT" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :UDID string $UDID" "$OUT"
fi

echo
echo "== 好了：桌面上的「WanderLine-配對檔.plist」"
echo "   1. 用 AirDrop 傳到 iPhone（存到「檔案」）"
echo "   2. WanderLine → ☰ → 設定 → 最下面「匯入電腦配對檔」→ 選這個檔"
echo "   這個檔等於這支手機的鑰匙，不要傳給別人。"
open -R "$OUT"
