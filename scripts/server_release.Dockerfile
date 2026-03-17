FROM debian:bookworm

ARG TARGETARCH
ARG ZIG_VERSION=0.14.0

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  binutils \
  bubblewrap \
  build-essential \
  ca-certificates \
  curl \
  file \
  git \
  libgmp-dev \
  m4 \
  opam \
  pkg-config \
  python3 \
  rsync \
  unzip \
  xz-utils \
  zsh \
  && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
    amd64) zig_arch=x86_64 ;; \
    arm64) zig_arch=aarch64 ;; \
    *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
  esac \
  && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${zig_arch}-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
  && tar -C /opt -xf /tmp/zig.tar.xz \
  && ln -s "/opt/zig-linux-${zig_arch}-${ZIG_VERSION}/zig" /usr/local/bin/zig \
  && rm -f /tmp/zig.tar.xz
