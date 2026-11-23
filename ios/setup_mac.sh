#!/bin/bash
# 在自己的 Mac 上準備 WanderLine 專案：裝 XcodeGen、下載 idevice 程式庫、產生 Xcode 專案，最後打開 Xcode。
# 用法（在 WanderLine 資料夾裡）：bash ios/setup_mac.sh
set -e
cd "$(dirname "$0")"
IDEVICE_VERSION=v0.1.68

if ! command -v brew >/dev/null; then
  echo "== 安裝 Homebrew（會要你輸入 Mac 的密碼）"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi
command -v xcodegen >/dev/null || brew install xcodegen

if [ ! -d Frameworks/IDevice.xcframework ]; then
  echo "== 下載 idevice 程式庫"
  tmp=$(mktemp -d)
  curl -fL -o "$tmp/idv.zip" "https://github.com/jkcoxson/idevice/releases/download/$IDEVICE_VERSION/idevice-xcframework-$IDEVICE_VERSION.zip"
  unzip -q "$tmp/idv.zip" -d "$tmp/x"
  mkdir -p Frameworks
  cp -R "$(find "$tmp/x" -name IDevice.xcframework -type d | head -1)" Frameworks/
fi

echo "== 產生 Xcode 專案"
xcodegen generate
open WanderLine.xcodeproj
echo "== 好了：Xcode 已打開。接上 iPhone，上方選你的 iPhone，按 ▶︎"
