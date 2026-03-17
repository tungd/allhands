#!/usr/bin/env zsh
set -euo pipefail

OUTPUT_DIR="${1:-${OUTPUT_DIR:-}}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "OUTPUT_DIR is required" >&2
  exit 1
fi

cd "$OUTPUT_DIR"

archives=(allhands-server_*.tar.gz)
if [[ ! -e "${archives[1]}" ]]; then
  echo "No release archives found in $OUTPUT_DIR" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "${archives[@]}" | sort > checksums.txt
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "${archives[@]}" | sort > checksums.txt
else
  echo "No SHA-256 tool found (expected shasum or sha256sum)" >&2
  exit 1
fi
