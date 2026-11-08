#!/bin/bash
# 构建 MacKit.app
# 用法：./build.sh [安装目录]   默认安装到 /Applications
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MacKit"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> 清理"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "==> 编译（先编私有框架桥接的 C 文件）"
clang -c -fblocks -O2 -Wno-objc-root-class \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$BUILD_DIR/native_visibility.o" \
    Sources/native_visibility.m

swiftc -O -swift-version 5 \
    -target "$(uname -m)-apple-macos13.0" \
    -import-objc-header Sources/native_visibility.h \
    -framework Cocoa -framework Carbon -framework ServiceManagement \
    -o "$BUNDLE/Contents/MacOS/$APP_NAME" \
    Sources/main.swift "$BUILD_DIR/native_visibility.o"

echo "==> 打包"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/*.icns "$BUNDLE/Contents/Resources/"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$BUNDLE"
codesign --verify --verbose "$BUNDLE" 2>&1 | tail -2

echo "==> 产物: $(pwd)/$BUNDLE"

DEST="${1:-/Applications}"
if [ "$DEST" = "none" ]; then
    echo "==> 跳过安装"
    exit 0
fi

echo "==> 安装到 $DEST"
rm -rf "$DEST/$APP_NAME.app"
cp -R "$BUNDLE" "$DEST/$APP_NAME.app"
echo "==> 完成: $DEST/$APP_NAME.app"
