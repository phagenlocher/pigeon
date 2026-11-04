# syntax=docker/dockerfile:1
#
# Multi-stage, multi-arch build for pigeon-server and pigeon-client.
#
#   docker build  --target server -t pigeon-server .
#   docker build  --target client -t pigeon-client .
#   docker buildx build --platform linux/amd64,linux/arm64 \
#       --target server -t ghcr.io/you/pigeon-server:0.1.0 --push .
#
# Publishing a GitHub release produces multi-arch manifest lists at
# ghcr.io/<owner>/pigeon-server and ghcr.io/<owner>/pigeon-client.
#
# The build stage runs on the *target* platform, so no Haskell
# cross-compilation and no QEMU is involved: releases build amd64 on
# ubuntu-24.04 and arm64 on the native ubuntu-24.04-arm runner (see
# .github/workflows/release-images.yml).

# Keep in step with .github/workflows/ci.yml. The slim image is Debian
# bookworm, which the runtime stage below must stay on for glibc/libgmp ABI
# compatibility. It already ships gcc, libc6-dev, zlib1g-dev, and libgmp-dev.
ARG GHC_VERSION=9.14.1

FROM haskell:${GHC_VERSION}-slim-bookworm AS build

# BuildKit cache mounts are shared between platforms by default, so the
# architecture is part of the cache id. Automatic platform args must be
# re-declared inside the stage to be usable in RUN.
ARG TARGETARCH

WORKDIR /src

RUN --mount=type=cache,id=cabal-packages,sharing=locked,target=/root/.cabal/packages \
    cabal update

# The sources must be present before the first build: the executables depend on
# the local library, so `--dependencies-only` would still configure and compile
# it. Dependency reuse comes from the store cache mount below, not from a
# separate layer. test/fixtures is referenced by extra-source-files.
COPY cabal.project pigeon.cabal LICENSE CHANGELOG.md /src/
COPY test/fixtures /src/test/fixtures
COPY app /src/app
COPY src /src/src

# Install both binaries into a plain layer; the stages below choose one.
# cabal.project compiles dependencies at -O2, which is what production wants.
RUN --mount=type=cache,id=cabal-packages,sharing=locked,target=/root/.cabal/packages \
    --mount=type=cache,id=cabal-store-${TARGETARCH},target=/root/.cabal/store \
    --mount=type=cache,id=pigeon-dist-${TARGETARCH},target=/src/dist-newstyle \
    cabal build --disable-tests -j exe:pigeon-server exe:pigeon-client \
 && mkdir -p /out \
 && install -m 0755 "$(cabal list-bin exe:pigeon-server)" /out/pigeon-server \
 && install -m 0755 "$(cabal list-bin exe:pigeon-client)" /out/pigeon-client \
 && strip --strip-unneeded /out/pigeon-server /out/pigeon-client

# Runtime base, on the same Debian release as the builder. The server needs
# libgmp and zlib (Pigeon.Streaming's FFI crc32); libstdc++ is pulled in by C
# code in the dependency closure.
FROM debian:bookworm-slim AS runtime

ENV LANG=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends libgmp10 zlib1g libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

# * Client ---------------------------------------------------------------
FROM runtime AS client

# Validating the server's TLS certificate needs a CA bundle; the server image
# should not carry one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /out/pigeon-client /usr/local/bin/pigeon-client

# No token, server URL, or credentials are baked in. Supply them with
# PIGEON_SERVER / PIGEON_TOKEN or flags. Run with
#   --user "$(id -u):$(id -g)" -v "$PWD:/data"
# so uploaded files keep the caller's ownership.
WORKDIR /data

ENTRYPOINT ["/usr/local/bin/pigeon-client"]

# * Server ---------------------------------------------------------------
# Last stage on purpose: a bare `docker build .` yields the server.
FROM runtime AS server

# Unprivileged, stable uid/gid so volume ownership survives rebuilds.
RUN groupadd --gid 10001 pigeon \
 && useradd --uid 10001 --gid 10001 --no-create-home \
      --home-dir /var/lib/pigeon --shell /usr/sbin/nologin pigeon \
 && install -d -m 0750 -o pigeon -g pigeon /var/lib/pigeon \
 && install -d -m 0755 -o root -g root /etc/pigeon

COPY --from=build /out/pigeon-server /usr/local/bin/pigeon-server

# TLS stays the default (spec SRV-034/SRV-035). Mount a key pair readable by
# uid 10001 and point PIGEON_TLS_CERT / PIGEON_TLS_KEY at it; set
# PIGEON_PUBLIC_URL because 127.0.0.1 is never the public name (SRV-022/024).
# Behind a TLS-terminating proxy, set PIGEON_NO_TLS=1 plus PIGEON_PORT and
# PIGEON_PUBLIC_URL; X-Forwarded-* is not trusted.
#
# Note SRV-036: the data directory must not be group/other writable. Named
# volumes inherit the 0750 ownership above; bind mounts need
#   chown 10001:10001 DIR && chmod 0750 DIR
ENV PIGEON_HOST=0.0.0.0 \
    PIGEON_PORT=8443 \
    PIGEON_DATA_DIR=/var/lib/pigeon

USER pigeon:pigeon
WORKDIR /var/lib/pigeon
VOLUME ["/var/lib/pigeon"]
EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/pigeon-server"]
