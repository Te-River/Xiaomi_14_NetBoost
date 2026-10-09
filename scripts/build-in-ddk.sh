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

# --- build baseline release ------------------------------------------
# MODVERSIONS fact (kernel/module/version.c: same_magic()): for modules
# carrying __crc_* sections, insmod only compares the FLAGS part of the
# vermagic ("SMP preempt mod_unload modversions aarch64"); the
# UTS_RELEASE string is NOT compared - ABI compatibility is enforced by
# symbol CRCs instead. Net effect: one .ko build loads on ALL
# 6.1.x-android14 kernels (any sublevel, any -gHASH-abSTAMP suffix).
#
# We still pin the release (via NB_KERNEL_RELEASE or kernel/
# TARGET_RELEASE) because the ddk tree ships its own release (e.g.
# "6.1.166-dirty") and a clean, GKI-shaped release string keeps the
# artifacts reproducible and readable - it is just no longer a
# load-time requirement.
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
        echo ">> build baseline release: ${NB_KERNEL_RELEASE}"
    else
        echo "ERROR: cannot parse release '${NB_KERNEL_RELEASE}'" >&2
        exit 1
    fi
else
    echo ">> WARNING: no TARGET_RELEASE pinned - modules will carry the" >&2
    echo ">> ddk tree release (still loadable: only vermagic FLAGS are" >&2
    echo ">> compared for MODVERSIONS modules, but keep it tidy)." >&2
fi
echo "${NB_KERNEL_RELEASE:-$(cat "${KERNEL_SRC}/include/config/kernel.release" 2>/dev/null || echo unknown)}" \
    > "${ROOT}/module/BUILD_RELEASE"

# --- build all modules ----------------------------------------------
# Three congestion-control provider LKMs. (The former netboost_core
# manager module was removed: its file-I/O helpers - filp_open /
# kernel_read / kernel_write - are not exported by the device kernel,
# so it could never insmod there. All management now lives in shell.)
make -C kernel/tcp_bbr3    KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_bbr     KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules
make -C kernel/tcp_westwood KERNEL_SRC="${KERNEL_SRC}" CLANG_DIR="${CLANG_DIR}" modules

echo ">> in-container build done:"
ls -l kernel/tcp_bbr3/tcp_bbr3.ko \
      kernel/tcp_bbr/tcp_bbr.ko \
      kernel/tcp_westwood/tcp_westwood.ko

# --- post-build vermagic assertion ----------------------------------
# Assert the vermagic FLAGS match the GKI standard and the release is a
# 6.1.x string. Per kernel/module/version.c: same_magic(), MODVERSIONS
# modules are compared on flags only, so matching flags + a 6.1 release
# prefix == loadable on ALL 6.1.x-android14 kernels (CRC-backed).
GKI_FLAGS="SMP preempt mod_unload modversions aarch64"
bad=0
for ko in kernel/tcp_bbr3/tcp_bbr3.ko \
          kernel/tcp_bbr/tcp_bbr.ko \
          kernel/tcp_westwood/tcp_westwood.ko; do
    vm="$(strings "${ko}" | grep '^vermagic=' | head -1 || true)"
    case "${vm}" in
        "vermagic=6.1."*" ${GKI_FLAGS}")
            echo ">> OK: ${ko} (flags = GKI, release-agnostic)"
            echo ">>     ${vm}"
            ;;
        *)
            echo "ERROR: vermagic flags mismatch for ${ko}" >&2
            echo "       got:  ${vm:-<none>}" >&2
            echo "       want: vermagic=6.1.* ${GKI_FLAGS}" >&2
            bad=1
            ;;
    esac
done
[ "${bad}" -eq 0 ] || exit 1
