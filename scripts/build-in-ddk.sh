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

# --- build both modules ---------------------------------------------
make -C kernel/netboost_core KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_bbr3    KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules

echo ">> in-container build done:"
ls -l kernel/netboost_core/netboost_core.ko kernel/tcp_bbr3/tcp_bbr3.ko
