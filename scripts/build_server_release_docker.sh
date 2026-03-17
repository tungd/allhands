#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TARGET_ARCH="${TARGET_ARCH:?TARGET_ARCH is required}"
VERSION="${VERSION:?VERSION is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
TARGET_OS="${TARGET_OS:-linux}"
TARGET_LIBC="${TARGET_LIBC:-musl}"
OCAML_VERSION="${OCAML_VERSION:-5.4.0}"
IMAGE_TAG="allhands-server-release-env:${TARGET_ARCH}"

case "$TARGET_OS/$TARGET_ARCH/$TARGET_LIBC" in
  linux/amd64/musl)
    zig_target="x86_64-linux-musl"
    docker_platform="linux/amd64"
    ;;
  linux/arm64/musl)
    zig_target="aarch64-linux-musl"
    docker_platform="linux/arm64"
    ;;
  *)
    echo "Unsupported Docker release target: $TARGET_OS/$TARGET_ARCH/$TARGET_LIBC" >&2
    exit 1
    ;;
esac

mkdir -p "$OUTPUT_DIR"

docker buildx build \
  --platform "$docker_platform" \
  --build-arg ZIG_VERSION="${ZIG_VERSION:-0.14.0}" \
  --load \
  --tag "$IMAGE_TAG" \
  --file "$ROOT_DIR/scripts/server_release.Dockerfile" \
  "$ROOT_DIR"

docker run --rm \
  --platform "$docker_platform" \
  --user "$(id -u):$(id -g)" \
  --volume "$ROOT_DIR:$ROOT_DIR" \
  --workdir "$ROOT_DIR" \
  --env HOME=/tmp/allhands-home \
  --env OPAMROOT=/tmp/allhands-home/.opam \
  --env TARGET_OS="$TARGET_OS" \
  --env TARGET_ARCH="$TARGET_ARCH" \
  --env TARGET_LIBC="$TARGET_LIBC" \
  --env VERSION="$VERSION" \
  --env OUTPUT_DIR="$OUTPUT_DIR" \
  --env ZIG_TARGET="$zig_target" \
  "$IMAGE_TAG" \
  zsh -lc "
    mkdir -p \"\$HOME\"
    opam init --disable-sandboxing --yes --bare
    opam switch create \"$OCAML_VERSION\" --yes
    eval \"\$(opam env --switch $OCAML_VERSION --set-switch --shell=zsh)\"
    opam install ./server --deps-only --yes
    mkdir -p \"\$HOME/bin\"
    cat >\"\$HOME/bin/cc\" <<'EOF'
#!/usr/bin/env sh
exec zig cc -target \"\$ZIG_TARGET\" \"\$@\"
EOF
    chmod +x \"\$HOME/bin/cc\"
    cp \"\$HOME/bin/cc\" \"\$HOME/bin/gcc\"
    export PATH=\"\$HOME/bin:\$PATH\"
    export CC=cc
    export AR='zig ar'
    export RANLIB='zig ranlib'
    export CFLAGS='-Os'
    export CPPFLAGS='-D_FILE_OFFSET_BITS=64'
    ./scripts/build_server_release.sh
  "
