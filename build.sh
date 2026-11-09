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

# 固定证书签名：ad-hoc 签名的「指定要求」是 cdhash，每次编译都会变，
# 系统就把它当成另一个 App，完全磁盘访问等授权每次都要重给。
# 用固定证书后指定要求变成「bundle id + 证书」，重建也不会丢权限。
SIGN_ID="${MACKIT_SIGN_ID:-MacKit Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> 签名（${SIGN_ID}）"
    codesign --force --deep --sign "$SIGN_ID" "$BUNDLE"
else
    echo "==> 签名（未找到 \"$SIGN_ID\"，退回 ad-hoc：授权会在每次重建后失效）"
    codesign --force --deep --sign - "$BUNDLE"
fi
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
