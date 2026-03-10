#!/usr/bin/env zsh
set -euo pipefail

echo "Build TailscaleKit.framework from https://github.com/tailscale/libtailscale/tree/main/swift"
echo "Expected output:"
echo "  ios/Vendor/TailscaleKit/TailscaleKit.framework"
echo
echo "This repo does not vendor the framework automatically. Follow the upstream"
echo "README in swift/README.md and then place the built framework at:"
echo "  $(pwd)/ios/Vendor/TailscaleKit"
