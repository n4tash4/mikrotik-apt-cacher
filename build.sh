#!/usr/bin/env sh

VERSION=0.1.0
EMPTY_LAYER_DIGEST=sha256:5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef

set -eu

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

    docker buildx build \
      --pull ${_nocache:+"${_nocache}"} \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "${_tag}" .

    _layers=$(docker image inspect "${_tag}" --format '{{range .RootFS.Layers}}{{println .}}{{end}}')
    _dups=$(printf '%s\n' "${_layers}" | sort | uniq -d)
    if [ -n "${_dups}" ]; then
        echo "ERROR: image has duplicate layers. RouterOS stacks layers as overlayfs lowerdirs by content digest, so the container fails with \"could not mount overlayfs root\":" >&2
        echo "${_dups}" >&2
        exit 1
    fi
    if printf '%s\n' "${_layers}" | grep -q "${EMPTY_LAYER_DIGEST}"; then
        echo "ERROR: image has an empty layer. RouterOS stacks layers as overlayfs lowerdirs by content digest, so the container fails with \"could not mount overlayfs root\"." >&2
        exit 1
    fi

    skopeo copy \
      "docker-daemon:${_tag}" \
      "docker-archive:${_out}"

    echo ">>> Done: ${_out}"
}

build_arch arm64 "linux/arm64" "arm64v8/debian:bookworm-slim"

echo ">>> Build complete."
ls -lh apt-cacher-*.tar 2>/dev/null || true
