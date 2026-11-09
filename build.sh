#!/usr/bin/env sh
# Build the apt-cacher container for MikroTik RouterOS, producing a single
# container-archive tar.
#
# Mirrors ../mikrotik-nginx/build.sh, ARM64 ONLY:
#
#   apt-cacher-arm64.tar  linux/arm64  ARMv8  -> RB5009 (Cortex-A72) & aarch64
#
# apt-cacher is installed from the Debian archive, so there is no cross-compile
# step — the whole build runs in the target-arch base image. The Mac build host
# is native arm64, so no QEMU is needed. On a non-arm64 host, register QEMU
# once first:
#   docker run --privileged --rm tonistiigi/binfmt --install all
#
# Requires Docker Buildx and skopeo.
#
# Usage:
#   ./build.sh              # -> apt-cacher-arm64.tar (layer cache on, --pull)
#   NO_CACHE=1 ./build.sh   # full clean rebuild

VERSION=0.1.0

set -eu

# --pull re-checks the base image every build, so a new debian:bookworm-slim
# (security updates) invalidates the cache below it. NO_CACHE=1 for a full
# clean rebuild.
_nocache=""
if [ "${NO_CACHE:-}" = "1" ]; then _nocache="--no-cache"; fi

build_arch() {
    _name="$1"
    _platform="$2"
    _runtime_base="$3"
    _out="apt-cacher-${_name}.tar"
    _tag="apt-cacher-mikrotik:${VERSION}-${_name}"

    echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
    rm -f "${_out}"

    # shellcheck disable=SC2086
    docker buildx build \
      --pull ${_nocache} \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "${_tag}" .

    # RouterOS stacks layers as overlayfs lowerdirs keyed by content digest, so
    # an empty or duplicated layer makes the container fail with "could not
    # mount overlayfs root". Reject such an image before it reaches the router.
    _layers=$(docker image inspect "${_tag}" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
    _dups=$(printf '%s\n' "${_layers}" | sort | uniq -d)
    if [ -n "${_dups}" ]; then
        echo "ERROR: image has duplicate layers (RouterOS cannot mount these):" >&2
        echo "${_dups}" >&2
        exit 1
    fi
    # sha256 of an empty tar layer
    if printf '%s\n' "${_layers}" | grep -q 'sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef'; then
        echo "ERROR: image has an empty layer (RouterOS cannot mount these)." >&2
        exit 1
    fi

    skopeo copy \
      "docker-daemon:${_tag}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

# Single arch (arm64) — no arch matrix to iterate.
build_arch arm64 "linux/arm64" "arm64v8/debian:bookworm-slim"

echo ">>> Build complete."
ls -lh apt-cacher-*.tar 2>/dev/null || true
