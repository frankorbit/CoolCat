#!/usr/bin/env bash
# 打一个可以直接发给别人的 CoolCat 包：Developer ID 签名（加固运行时 + 时间戳）→ 公证 → 装订 → zip。
#
# 用法：
#   COOLCAT_SIGN_IDENTITY="Developer ID Application: XXX (TEAMID)" \
#   COOLCAT_NOTARY_PROFILE=coolcat-notary \
#   scripts/package-macos.sh
#
# COOLCAT_NOTARY_PROFILE 为空时只签名打包、不公证（对方需在「隐私与安全性」里点「仍要打开」）。
# 公证配置需事先用 `xcrun notarytool store-credentials <名字>` 存进钥匙串。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/CoolCat.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP="$DIST/CoolCat-$VERSION-macOS.zip"

: "${COOLCAT_SIGN_IDENTITY:?请设置 COOLCAT_SIGN_IDENTITY 为 Developer ID Application 证书名}"
case "$COOLCAT_SIGN_IDENTITY" in
    "Developer ID Application:"*) ;;
    *) echo "[ERROR] 分发给他人必须用 Developer ID Application 证书，当前是：$COOLCAT_SIGN_IDENTITY" >&2; exit 1 ;;
esac

echo "==> 构建并签名 v$VERSION"
COOLCAT_HARDENED=1 COOLCAT_REQUIRE_STABLE_SIGNATURE=1 "$ROOT/build.sh"

echo "==> 校验签名"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer ID Application|flags=.*runtime|Timestamp=" || {
    echo "[ERROR] 签名里缺少 Developer ID / runtime / 时间戳" >&2; exit 1; }

mkdir -p "$DIST"

# zip 里放 App + 安装说明；公证提交只需要 App 本身
make_zip() {
    local stage
    stage="$(mktemp -d)/CoolCat-$VERSION"
    mkdir -p "$stage"
    ditto "$APP" "$stage/CoolCat.app"
    cp "$ROOT/scripts/colleague-install.txt" "$stage/安装说明.txt"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$stage" "$ZIP"
    rm -rf "$(dirname "$stage")"
}

NOTARY_ZIP="$DIST/.notary-upload.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

if [ -n "${COOLCAT_NOTARY_PROFILE:-}" ]; then
    echo "==> 提交 Apple 公证（通常 1~5 分钟）"
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$COOLCAT_NOTARY_PROFILE" --wait
    echo "==> 装订公证票据"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "==> Gatekeeper 评估"
    spctl --assess --type execute --verbose=2 "$APP"
else
    echo "==> 未设置 COOLCAT_NOTARY_PROFILE，跳过公证（对方首次打开需在「隐私与安全性」里点「仍要打开」，见安装说明）"
fi
rm -f "$NOTARY_ZIP"
make_zip

shasum -a 256 "$ZIP"
echo "==> 完成：$ZIP"
