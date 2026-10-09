#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost installer - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# This script runs in KernelSU's BusyBox ash (standalone mode).
# It extracts the module files and stages the three congestion-control
# kernel modules (.ko) into the module directory.

SKIPUNZIP=1

MODDIR="${MODPATH:-/data/adb/modules/netboost}"
KERNEL_DIR="${MODDIR}/kernel"

ui_print "----------------------------------------"
ui_print " NetBoost - Xiaomi 14 Kernel Network Accelerator"
ui_print "----------------------------------------"

# --- sanity checks -------------------------------------------------
if [ -z "$KSU" ]; then
    ui_print "!! This module is designed for KernelSU only."
    ui_print "!! Install via KernelSU Manager, not Magisk/Recovery."
    abort "KernelSU required"
fi

API=$(getprop ro.build.version.sdk)
ui_print "  Android API level: ${API}"

# --- extract module files ------------------------------------------
# SKIPUNZIP=1 means KernelSU does NOT auto-extract; we must do it ourselves.
ui_print "  Extracting files..."
unzip -o "${ZIPFILE}" -d "${MODPATH}" >/dev/null 2>&1 || \
    abort "failed to extract module zip"

mkdir -p "${KERNEL_DIR}"
cd "${MODPATH}" || abort "cannot enter module dir"

# move bundled .ko files into kernel/ so the module dir stays tidy
found_ko=0
for ko in tcp_bbr3.ko tcp_bbr.ko tcp_westwood.ko; do
    if [ -f "${ko}" ]; then
        cp -f "${ko}" "${KERNEL_DIR}/${ko}"
        rm -f "${ko}"
        found_ko=$((found_ko + 1))
        ui_print "  staged: ${ko}"
    fi
done
if [ "${found_ko}" -ne 3 ]; then
    ui_print "!! WARNING: kernel modules missing from package"
    ui_print "!! Re-download the zip; sysctl tuning will still apply"
fi

# remove stale files from a previous version (module update path)
rm -f "${KERNEL_DIR}/netboost_core.ko" "${MODPATH}/netboost.orig" 2>/dev/null

# --- persistent data migration (v2.6 -> v2.7.1+) ---------------------
# The stock snapshot (netboost.orig) and LingXi learning data used to
# live INSIDE the module dir, which gets wiped on module update. They
# now live in /data/adb/netboost_data/. Migrate from the previously
# installed module dir (still intact at install time) so a direct
# v2.6 -> v2.7.1 upgrade keeps `nb.sh stock` working.
NB_DATA="/data/adb/netboost_data"
OLD_MOD="/data/adb/modules/netboost"
mkdir -p "${NB_DATA}" 2>/dev/null && chmod 700 "${NB_DATA}" 2>/dev/null
if [ -f "${OLD_MOD}/netboost.orig" ] && [ ! -s "${NB_DATA}/netboost.orig" ]; then
    cp -f "${OLD_MOD}/netboost.orig" "${NB_DATA}/netboost.orig" 2>/dev/null && \
        ui_print "  migrated: netboost.orig (stock snapshot)"
fi
if [ -f "${OLD_MOD}/cellmap.csv" ] && [ ! -s "${NB_DATA}/cellmap.csv" ]; then
    cp -f "${OLD_MOD}/cellmap.csv" "${NB_DATA}/cellmap.csv" 2>/dev/null && \
        ui_print "  migrated: cellmap.csv (lingxi learning data)"
fi
if [ -f "${OLD_MOD}/lingxi.state" ] && [ ! -s "${NB_DATA}/lingxi.state" ]; then
    cp -f "${OLD_MOD}/lingxi.state" "${NB_DATA}/lingxi.state" 2>/dev/null
fi
ui_print "  data dir: ${NB_DATA} (persists across updates)"

# --- kernel compatibility (MODVERSIONS facts, v2.7.0) -----------------
# kernel/module/version.c: same_magic() only compares the FLAGS part of
# vermagic for MODVERSIONS modules ("SMP preempt mod_unload modversions
# aarch64"); the UTS_RELEASE string is NOT compared - ABI compatibility
# is backed by symbol CRCs instead. Therefore the bundled .ko works on
# ALL 6.1.x-android14 kernels (6.1.138 included) as long as the flags
# match. CRC mismatch (KMI-breaking custom kernels) degrades gracefully:
# nb.sh falls back to cubic and sysctl tuning still applies.
KREL=$(uname -r)
ui_print "  kernel: ${KREL}"
case "${KREL}" in
    *android14-6.1*)
        ui_print "  OK: android14-6.1 GKI kernel"
        ui_print "  (release-agnostic: works on all 6.1.x-android14)"
        ;;
    6.1.*)
        ui_print "  OK: 6.1 GKI kernel; LKM flags may or may not match -"
        ui_print "  if LKM count shows 0/3 after boot, sysctl tuning still applies"
        ;;
    *)
        ui_print "  warning: kernel is not 6.1.x-android14; LKMs likely won't"
        ui_print "  load (CRC mismatch) - sysctl tuning still applies"
        ;;
esac

# informational: the release this build was produced against
if [ -f "${MODPATH}/BUILD_RELEASE" ]; then
    BREL="$(head -n1 "${MODPATH}/BUILD_RELEASE" | tr -d '[:space:]')"
    if [ -n "${BREL}" ] && [ "${BREL}" != "unknown" ]; then
        ui_print "  built against: ${BREL}"
        ui_print "  (CRC-backed; exact release match NOT required)"
    fi
fi

# --- set permissions ------------------------------------------------
set_perm_recursive "${MODPATH}" 0 0 0755 0644
for s in service.sh uninstall.sh nb.sh update-display.sh lingxi.sh; do
    [ -f "${MODPATH}/${s}" ] && set_perm "${MODPATH}/${s}" 0 0 0755
done
for ko in tcp_bbr3.ko tcp_bbr.ko tcp_westwood.ko; do
    [ -f "${KERNEL_DIR}/${ko}" ] && set_perm "${KERNEL_DIR}/${ko}" 0 0 0644
done

# --- config file -----------------------------------------------------
if [ -f "${MODPATH}/netboost.conf" ]; then
    ui_print "  config: netboost.conf found"
fi

ui_print "----------------------------------------"
ui_print " Install complete. Reboot to activate."
ui_print " After boot: nb.sh status | lingxi.sh status"
ui_print "----------------------------------------"
