#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost build script - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# Builds the two kernel modules (netboost_core.ko + tcp_bbr3.ko) and packs
# them into a KernelSU flashable module zip.
#
# Usage:
#   ./scripts/build.sh                 # build via DDK container (recommended)
#   ./scripts/build.sh --local         # build against local kernel tree
#   ./scripts/build.sh --kdir <path>   # build against a specific kernel tree
#   ./scripts/build.sh --kmi android14-6.1   # DDK container for a GKI variant
#
# Requirements for DDK mode: docker or podman.
# Requirements for local mode: kernel headers + matching toolchain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KMI="${KMI:-android14-6.1}"
# Dated ddk-min tag for reproducible builds (plain :<kmi> also exists).
DDK_TAG="${DDK_TAG:-20260313}"
DDK_IMAGE="${DDK_IMAGE:-ghcr.io/ylarod/ddk-min:${KMI}-${DDK_TAG}}"
MODE="ddk"
KDIR=""
ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"
OUT_DIR="${ROOT}/out"

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)   MODE="local"; shift ;;
        --kdir)    KDIR="$2"; MODE="local"; shift 2 ;;
        --kmi)     KMI="$2"; DDK_IMAGE="ghcr.io/ylarod/ddk-min:${KMI}-${DDK_TAG}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1"; usage ;;
    esac
done

build_local() {
    local kdir="${KDIR:-/lib/modules/$(uname -r)/build}"
    local make_args=()
    # only cross-compile when a cross toolchain is actually available
    if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
        make_args+=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
        echo ">> building against $kdir (arch=arm64 cross)"
    else
        echo ">> building against $kdir (arch=native)"
    fi
    echo ">> building netboost_core"
    make -C "${ROOT}/kernel/netboost_core" KDIR="$kdir" "${make_args[@]}" modules
    echo ">> building tcp_bbr3"
    make -C "${ROOT}/kernel/tcp_bbr3" KDIR="$kdir" "${make_args[@]}" modules
}

build_ddk() {
    local runner="docker"
    if ! command -v docker >/dev/null 2>&1; then
        if command -v podman >/dev/null 2>&1; then
            runner="podman"
        else
            echo "ERROR: neither docker nor podman found; use --local mode" >&2
            exit 1
        fi
    fi
    echo ">> building via DDK container: ${DDK_IMAGE}"
    # The in-container script auto-detects the kernel tree at
    # /opt/ddk/kdir/<kmi> and the clang toolchain under /opt/ddk/clang,
    # then builds both modules with the GKI clang toolchain (LLVM=1).
    $runner run --rm -v "${ROOT}:/src" -w /src \
        "${DDK_IMAGE}" \
        bash scripts/build-in-ddk.sh "${KMI}"
}

pack_module() {
    echo ">> packing KernelSU module zip"
    local zip="${OUT_DIR}/netboost-${KMI}.zip"
    mkdir -p "${OUT_DIR}"
    ( cd "${ROOT}/module" && zip -r "${zip}" . -x '*.DS_Store' )
    # add built .ko files
    ( cd "${ROOT}/kernel/netboost_core" && zip -j "${zip}" netboost_core.ko )
    ( cd "${ROOT}/kernel/tcp_bbr3" && zip -j "${zip}" tcp_bbr3.ko )
    echo ">> module zip: ${zip}"
}

case "$MODE" in
    local) build_local ;;
    ddk)   build_ddk ;;
esac

pack_module
echo ">> done."
