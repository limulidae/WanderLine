#!/bin/sh
# Xcode Cloud：clone 完之後產生專案（WanderLine.xcodeproj 不進 git，由 XcodeGen 依 project.yml 產生），
# 並下載 idevice 程式庫（連 iPhone 開發者服務用，太大不進 git）。
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH/ios"
IDEVICE_VERSION=v0.1.68

brew install xcodegen

tmp=$(mktemp -d)
curl -fsSL -o "$tmp/idv.zip" "https://github.com/jkcoxson/idevice/releases/download/$IDEVICE_VERSION/idevice-xcframework-$IDEVICE_VERSION.zip"
unzip -q "$tmp/idv.zip" -d "$tmp/x"
mkdir -p Frameworks
cp -R "$(find "$tmp/x" -name IDevice.xcframework -type d | head -1)" Frameworks/

xcodegen generate
