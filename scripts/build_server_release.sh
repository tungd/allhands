#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"

TARGET_OS="${TARGET_OS:?TARGET_OS is required}"
TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH is required}"
TARGET_LIBC="${TARGET_LIBC:-}"
VERSION="${VERSION:?VERSION is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"

ARCHIVE_BASENAME="allhands-server_${VERSION}_${TARGET_OS}_${TARGET_ARCH}"
BUILD_DIR="$SERVER_DIR/_build_release_${TARGET_OS}_${TARGET_ARCH}${TARGET_LIBC:+_$TARGET_LIBC}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/allhands-server-release.XXXXXX")"
INSTALL_ROOT="$STAGING_DIR/$ARCHIVE_BASENAME"
BINARY_PATH="$INSTALL_ROOT/allhands-server"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

normalize_link_flags() {
  case "$TARGET_OS/$TARGET_ARCH${TARGET_LIBC:+/$TARGET_LIBC}" in
    linux/amd64/musl)
      echo "(-cclib -static)"
      ;;
    linux/arm64/musl)
      echo "(-cclib -static)"
      ;;
    darwin/amd64|darwin/arm64)
      echo "()"
      ;;
    *)
      echo "Unsupported release target: $TARGET_OS/$TARGET_ARCH${TARGET_LIBC:+/$TARGET_LIBC}" >&2
      exit 1
      ;;
  esac
}

maybe_activate_opam() {
  if ! command -v opam >/dev/null 2>&1; then
    return
  fi

  if opam switch show >/dev/null 2>&1; then
    eval "$(opam env --shell=zsh)"
  fi
}

copy_if_present() {
  local source_path="$1"
  local dest_path="$2"
  if [[ -f "$source_path" ]]; then
    cp "$source_path" "$dest_path"
  fi
}

smoke_test_binary() {
  local log_file port server_pid
  log_file="$(mktemp "${TMPDIR:-/tmp}/allhands-server-smoke.XXXXXX.log")"
  port="$(
    python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
  )"

  "$BINARY_PATH" --host 127.0.0.1 --port "$port" --no-bonjour >"$log_file" 2>&1 &
  server_pid=$!

  {
    python3 - "$port" "$VERSION" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
version = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"
deadline = time.time() + 10.0
last_error = None

while time.time() < deadline:
    try:
        with urllib.request.urlopen(base_url + "/healthz", timeout=1.0) as response:
            health = json.load(response)
        with urllib.request.urlopen(base_url + "/server-info", timeout=1.0) as response:
            info = json.load(response)
        if health.get("status") != "ok":
            raise RuntimeError(f"unexpected health payload: {health}")
        if info.get("version") != version:
            raise RuntimeError(f"expected version {version!r} but got {info.get('version')!r}")
        sys.exit(0)
    except Exception as exc:
        last_error = exc
        time.sleep(0.2)

raise SystemExit(f"server smoke test failed: {last_error}")
PY
  } always {
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    rm -f "$log_file"
  }
}

verify_linux_static_binary() {
  local ldd_output
  file "$BINARY_PATH"
  ldd_output="$(ldd "$BINARY_PATH" 2>&1 || true)"
  echo "$ldd_output"
  if [[ "$ldd_output" != *"not a dynamic executable"* ]]; then
    echo "Expected a static Linux binary but ldd reported dynamic dependencies" >&2
    exit 1
  fi
}

mkdir -p "$OUTPUT_DIR"
mkdir -p "$INSTALL_ROOT"

maybe_activate_opam

export DUNE_BUILD_DIR="$BUILD_DIR"
export ALLHANDS_SERVER_VERSION="$VERSION"
export ALLHANDS_SERVER_LINK_FLAGS="$(normalize_link_flags)"

cd "$SERVER_DIR"
dune build ./allhands_server.exe --profile release

cp "$BUILD_DIR/default/allhands_server.exe" "$BINARY_PATH"
chmod +x "$BINARY_PATH"

copy_if_present "$ROOT_DIR/README.md" "$INSTALL_ROOT/README.md"
copy_if_present "$ROOT_DIR/LICENSE" "$INSTALL_ROOT/LICENSE"
copy_if_present "$ROOT_DIR/LICENSE.md" "$INSTALL_ROOT/LICENSE.md"

if [[ "$TARGET_OS" == "linux" ]]; then
  verify_linux_static_binary
fi

smoke_test_binary

tar -C "$STAGING_DIR" -czf "$OUTPUT_DIR/${ARCHIVE_BASENAME}.tar.gz" "$ARCHIVE_BASENAME"
