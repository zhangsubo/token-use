#!/bin/bash
#
# TokenUse.app 打包脚本
#
# 输入 env:
#   MARKETING_VERSION  默认 0.1.0    （CFBundleShortVersionString，对应 git tag v*.*.*）
#   BUILD_NUMBER       默认 1        （CFBundleVersion，对应 GitHub Actions run_number）
#
# 产物：
#   TokenUse.app         arm64-only bundle（ad-hoc 签，可被 Sparkle 替换）
#   TokenUse.zip         ditto 压缩，用于 Sparkle appcast 分发
#
set -euo pipefail

APP_NAME="TokenUse"
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_BUNDLE="$APP_NAME.app"
RESOURCE_BUNDLE="${APP_NAME}_${APP_NAME}.bundle"
ZIP_NAME="${APP_NAME}.zip"
PROJECT_DIR="$(pwd -P)"

MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-cache-physical"
export SWIFTPM_CACHE_PATH="$PROJECT_DIR/.build/swiftpm-cache-physical"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_CACHE_PATH"

echo "==> Building TokenUse (version $MARKETING_VERSION, build $BUILD_NUMBER)..."
swift build -c release --disable-sandbox

echo "==> Assembling .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# 补 rpath 让 @rpath/Sparkle.framework 在 .app bundle 内可解析
# Why：SwiftPM 的 rpath 列表里没有 @executable_path/../Frameworks，
# 运行时 dyld 会报 "Library not loaded: @rpath/Sparkle.framework/..."
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
if ! otool -l "$APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BINARY"
    echo "==> Added @executable_path/../Frameworks rpath"
fi

if [ -d "$BUILD_DIR/$RESOURCE_BUNDLE" ]; then
    cp -R "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# Sparkle framework 嵌入
# Why：SPM 把 Sparkle 编译到 .build/.../Sparkle.framework 但不自动拷到 .app，
# binary 链了 @rpath/Sparkle.framework → 运行时 dlopen 失败。
# Why arm64-only：项目承诺只支持 M 芯片，xcframework 里含 x86_64 slice 浪费体积
SPARKLE_FW_SRC="$BUILD_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FW_SRC" ]; then
    # fallback: 从 xcframework 抽 arm64 slice
    SPARKLE_FW_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [ -d "$SPARKLE_FW_SRC" ]; then
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"
    cp -R "$SPARKLE_FW_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    # 删除 x86_64 slice（如有），保证 arm64-only
    SPARKLE_BIN="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
    if [ -f "$SPARKLE_BIN" ] && lipo -info "$SPARKLE_BIN" 2>/dev/null | grep -q "x86_64"; then
        echo "==> Stripping x86_64 from Sparkle.framework..."
        lipo -remove x86_64 "$SPARKLE_BIN" -output "$SPARKLE_BIN.tmp"
        mv "$SPARKLE_BIN.tmp" "$SPARKLE_BIN"
    fi
    echo "==> Sparkle framework embedded (arm64-only)"
else
    echo "ERROR: Sparkle.framework not found in .build/. Did swift build succeed?"
    exit 1
fi

if [ -f "Sources/TokenUse/Resources/AppIcon.icns" ]; then
    cp "Sources/TokenUse/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi

# Info.plist：从模板复制 + PlistBuddy 注入版本号
# Why：模板化让 .github/workflows/release.yml 通过 env 注入版本，避免 heredoc 散落
echo "==> Writing Info.plist from template..."
PLIST_TEMPLATE="Sources/TokenUse/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

if [ ! -f "$PLIST_TEMPLATE" ]; then
    echo "ERROR: $PLIST_TEMPLATE not found"
    exit 1
fi

cp "$PLIST_TEMPLATE" "$APP_BUNDLE/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $MARKETING_VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$APP_BUNDLE/Contents/Info.plist"

# Bundle-level ad-hoc 签
# Why：Sparkle 强制要求 sealed bundle（Info.plist bound、Sealed Resources non-empty）
# 单纯 linker 阶段的 adhoc 不够，必须对 .app 整体再签一次
# Why iCloud/workspace copies can attach extended attributes to embedded frameworks,
# and codesign rejects those as resource forks or Finder metadata.
echo "==> Clearing extended attributes..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo "==> Ad-hoc codesigning bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

# Zip：保持 .app 目录结构，sequesterRsrc 确保 resource fork 不被剥离
# ditto 比 zip 更稳，macOS 推荐用于 .app 打包
echo "==> Creating zip..."
rm -f "$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_NAME"

echo ""
echo "==> Done!"
echo "    App bundle: $APP_BUNDLE"
echo "    Zip:        $ZIP_NAME"
echo ""
echo "Verify arm64 + signature:"
echo "    lipo -info $APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo "    codesign -dvv $APP_BUNDLE"
echo ""
echo "Run locally:"
echo "    open $APP_BUNDLE"
