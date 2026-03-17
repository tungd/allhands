#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/ios/Vendor/TailscaleKit"
OUTPUT_XCFRAMEWORK="$VENDOR_DIR/TailscaleKit.xcframework"
UPSTREAM_REPO="${TAILSCALE_LIBTAILSCALE_REPO:-https://github.com/tailscale/libtailscale}"
UPSTREAM_REF="${TAILSCALE_LIBTAILSCALE_REF:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/allhands-tailscalekit.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for tool in git make xcodebuild go; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is required" >&2
    exit 1
  fi
done

echo "Cloning upstream libtailscale from:"
echo "  $UPSTREAM_REPO"
git clone --depth=1 "$UPSTREAM_REPO" "$WORK_DIR/libtailscale"

if [[ -n "$UPSTREAM_REF" ]]; then
  git -C "$WORK_DIR/libtailscale" fetch --depth=1 origin "$UPSTREAM_REF"
  git -C "$WORK_DIR/libtailscale" checkout FETCH_HEAD
fi

echo
echo "Building TailscaleKit.xcframework..."
(
  cd "$WORK_DIR/libtailscale/swift"
  make ios-fat
)

BUILT_XCFRAMEWORK="$WORK_DIR/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"

if [[ ! -d "$BUILT_XCFRAMEWORK" ]]; then
  echo "Expected XCFramework not found at:" >&2
  echo "  $BUILT_XCFRAMEWORK" >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"
rm -rf "$OUTPUT_XCFRAMEWORK"
cp -R "$BUILT_XCFRAMEWORK" "$OUTPUT_XCFRAMEWORK"

echo
echo "Installed:"
echo "  $OUTPUT_XCFRAMEWORK"

echo
echo "Regenerating Xcode project..."
(
  cd "$ROOT_DIR/ios"
  xcodegen generate
)

echo
echo "Done. Open:"
echo "  $ROOT_DIR/ios/AllHands.xcodeproj"
