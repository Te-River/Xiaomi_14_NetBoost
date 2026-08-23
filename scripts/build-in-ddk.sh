#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost in-container build script.
#
# Runs INSIDE the ghcr.io/ylarod/ddk-min:<kmi>-<tag> image (or any
# environment that lays out /opt/ddk/kdir/<kmi> + /opt/ddk/clang/clang-r*/bin)
# and builds both kernel modules with the GKI clang toolchain.
#
# Usage (inside the container, repo mounted at /src):
#   bash scripts/build-in-ddk.sh android14-6.1

set -euo pipefail

KMI="${1:-${KMI:-android14-6.1}}"

# --- locate the prepared kernel tree --------------------------------
KERNEL_SRC="${KERNEL_SRC:-/opt/ddk/kdir/${KMI}}"
if [ ! -d "${KERNEL_SRC}" ]; then
    echo "ERROR: kernel tree not found at ${KERNEL_SRC}" >&2
    echo "  expected the ddk-min layout: /opt/ddk/kdir/${KMI}" >&2
    exit 1
fi

# --- locate the newest clang toolchain ------------------------------
if [ -z "${CLANG_DIR:-}" ]; then
    CLANG_DIR="$(ls -d /opt/ddk/clang/clang-r*/bin 2>/dev/null | sort -V | tail -1 || true)"
fi
if [ -z "${CLANG_DIR}" ] || [ ! -x "${CLANG_DIR}/clang" ]; then
    echo "ERROR: no clang toolchain under /opt/ddk/clang" >&2
    exit 1
fi
export PATH="${CLANG_DIR}:${PATH}"

echo ">> kdir=${KERNEL_SRC}"
echo ">> clang=${CLANG_DIR}"

# --- optional vermagic pin -------------------------------------------
# The kernel enforces exact vermagic: insmod fails with "Invalid module
# format" unless the module's UTS_RELEASE equals the device's `uname -r`.
# The ddk tree ships its own release (e.g. "6.1.166-dirty") which matches
# no real device. Pin the target release via either:
#   - env NB_KERNEL_RELEASE, or
#   - a tracked kernel/TARGET_RELEASE file (one line: exact uname -r)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NB_KERNEL_RELEASE="${NB_KERNEL_RELEASE:-}"
if [ -z "${NB_KERNEL_RELEASE}" ] && [ -f "${ROOT}/kernel/TARGET_RELEASE" ]; then
    NB_KERNEL_RELEASE="$(head -n1 "${ROOT}/kernel/TARGET_RELEASE" | tr -d '[:space:]')"
fi
if [ -n "${NB_KERNEL_RELEASE}" ]; then
    echo "${NB_KERNEL_RELEASE}" > "${KERNEL_SRC}/include/config/kernel.release"
    printf '#define UTS_RELEASE "%s"\n' "${NB_KERNEL_RELEASE}" \
        > "${KERNEL_SRC}/include/generated/utsrelease.h"
    echo ">> vermagic pinned to: ${NB_KERNEL_RELEASE}"
fi
echo "${NB_KERNEL_RELEASE:-$(cat "${KERNEL_SRC}/include/config/kernel.release" 2>/dev/null || echo unknown)}" \
    > "${ROOT}/module/BUILD_RELEASE"

# --- build all modules ----------------------------------------------
# congestion-control providers first (independent), manager last.
make -C kernel/netboost_core KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_bbr3    KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_bbr     KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_westwood KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules

echo ">> in-container build done:"
ls -l kernel/netboost_core/netboost_core.ko \
      kernel/tcp_bbr3/tcp_bbr3.ko \
      kernel/tcp_bbr/tcp_bbr.ko \
      kernel/tcp_westwood/tcp_westwood.ko
