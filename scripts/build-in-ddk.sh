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
#
# kbuild recomputes include/config/kernel.release on external module
# builds (VERSION/PATCHLEVEL/SUBLEVEL from the top Makefile + CONFIG_
# LOCALVERSION + localversion-* files + scm suffix via setlocalversion),
# so pinning ustrelease.h alone is not enough. We therefore rewrite ALL
# four ingredients:
#   1. top Makefile version triple  -> 6.1.138
#   2. CONFIG_LOCALVERSION_AUTO off (no git-describe suffix)
#   3. empty .scmversion            (no -dirty suffix)
#   4. localversion-netboost        (-android14-11-g...-ab...)
# plus the direct kernel.release/utsrelease.h writes as a belt-and-
# suspenders, and LOCALVERSION= exported (documented way to suppress
# the scm suffix).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NB_KERNEL_RELEASE="${NB_KERNEL_RELEASE:-}"
if [ -z "${NB_KERNEL_RELEASE}" ] && [ -f "${ROOT}/kernel/TARGET_RELEASE" ]; then
    NB_KERNEL_RELEASE="$(head -n1 "${ROOT}/kernel/TARGET_RELEASE" | tr -d '[:space:]')"
fi
if [ -n "${NB_KERNEL_RELEASE}" ]; then
    BASE="$(printf '%s' "${NB_KERNEL_RELEASE}" \
        | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
    if [ -n "${BASE}" ]; then
        KV_MAJOR="${BASE%%.*}"
        _rest="${BASE#*.}"
        KV_MINOR="${_rest%%.*}"
        KV_PATCH="${_rest##*.}"
        SUFFIX="${NB_KERNEL_RELEASE#"${BASE}"}"

        sed -i -E \
            -e "s/^VERSION[[:space:]]*=.*/VERSION = ${KV_MAJOR}/" \
            -e "s/^PATCHLEVEL[[:space:]]*=.*/PATCHLEVEL = ${KV_MINOR}/" \
            -e "s/^SUBLEVEL[[:space:]]*=.*/SUBLEVEL = ${KV_PATCH}/" \
            "${KERNEL_SRC}/Makefile"
        sed -i -e 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' \
            "${KERNEL_SRC}/.config" 2>/dev/null || true
        rm -f "${KERNEL_SRC}"/localversion*
        printf '%s' "${SUFFIX}" > "${KERNEL_SRC}/localversion-netboost"
        : > "${KERNEL_SRC}/.scmversion"
        export LOCALVERSION=""
        # belt-and-suspenders: also write the generated files directly;
        # if kbuild regenerates them the four ingredients above yield
        # the identical string anyway.
        echo "${NB_KERNEL_RELEASE}" > "${KERNEL_SRC}/include/config/kernel.release"
        printf '#define UTS_RELEASE "%s"\n' "${NB_KERNEL_RELEASE}" \
            > "${KERNEL_SRC}/include/generated/utsrelease.h"
        echo ">> vermagic pinned to: ${NB_KERNEL_RELEASE}"
    else
        echo "ERROR: cannot parse release '${NB_KERNEL_RELEASE}'" >&2
        exit 1
    fi
else
    echo ">> WARNING: no TARGET_RELEASE pinned - modules will carry the ddk" >&2
    echo ">> tree release and insmod will fail on any real device." >&2
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

# --- post-build vermagic assertion ----------------------------------
# Fail inside the container (clear error, no broken zip) if the pin
# did not take effect for every module.
if [ -n "${NB_KERNEL_RELEASE:-}" ]; then
    bad=0
    for ko in kernel/netboost_core/netboost_core.ko \
              kernel/tcp_bbr3/tcp_bbr3.ko \
              kernel/tcp_bbr/tcp_bbr.ko \
              kernel/tcp_westwood/tcp_westwood.ko; do
        vm="$(grep -aoE 'vermagic=[^ ]* [^ ]*' "${ko}" | head -1 || true)"
        case "${vm}" in
            "vermagic=${NB_KERNEL_RELEASE} "*)
                echo ">> OK: ${ko}: ${vm}"
                ;;
            *)
                echo "ERROR: vermagic mismatch for ${ko}" >&2
                echo "       got:  ${vm:-<none>}" >&2
                echo "       want: vermagic=${NB_KERNEL_RELEASE} ..." >&2
                bad=1
                ;;
        esac
    done
    [ "${bad}" -eq 0 ] || exit 1
fi
