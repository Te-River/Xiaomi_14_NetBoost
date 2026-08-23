#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost installer - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# This script runs in KernelSU's BusyBox ash (standalone mode).
# It copies the two kernel modules (.ko) into the module directory and
# registers them for loading on boot.

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
for ko in tcp_bbr.ko tcp_westwood.ko tcp_bbr3.ko netboost_core.ko; do
    if [ -f "${ko}" ]; then
        cp -f "${ko}" "${KERNEL_DIR}/${ko}"
        rm -f "${ko}"
        found_ko=$((found_ko + 1))
        ui_print "  staged: ${ko}"
    fi
done
if [ "${found_ko}" -ne 4 ]; then
    ui_print "!! WARNING: kernel modules missing from package"
    ui_print "!! Re-download the zip; runtime tuning will still apply"
fi

# --- verify kernel compatibility -----------------------------------
KREL=$(uname -r)
ui_print "  kernel: ${KREL}"
case "${KREL}" in
    *android14-6.1*|6.1.*)
        ui_print "  OK: android14-6.1 GKI kernel detected"
        ;;
    *)
        ui_print "  warning: kernel release may not be android14-6.1"
        ui_print "  module was built for android14-6.1 (6.1.x)"
        ;;
esac

# --- vermagic check (module UTS_RELEASE must equal uname -r) --------
if [ -f "${MODPATH}/BUILD_RELEASE" ]; then
    BREL="$(head -n1 "${MODPATH}/BUILD_RELEASE" | tr -d '[:space:]')"
    if [ -n "${BREL}" ] && [ "${BREL}" != "unknown" ]; then
        if [ "${BREL}" != "${KREL}" ]; then
            ui_print "!! VERMAGIC MISMATCH:"
            ui_print "!!   modules built for: ${BREL}"
            ui_print "!!   device kernel is:  ${KREL}"
            ui_print "!! insmod will FAIL (Invalid module format)."
            ui_print "!! Report your 'uname -r' to get a matching build;"
            ui_print "!! sysctl tuning still applies in the meantime."
        else
            ui_print "  OK: vermagic matches device kernel"
        fi
    fi
fi

# --- set permissions ------------------------------------------------
set_perm_recursive "${MODPATH}" 0 0 0755 0644
for s in service.sh uninstall.sh nb.sh update-display.sh; do
    [ -f "${MODPATH}/${s}" ] && set_perm "${MODPATH}/${s}" 0 0 0755
done
for ko in netboost_core.ko tcp_bbr3.ko tcp_bbr.ko tcp_westwood.ko; do
    [ -f "${KERNEL_DIR}/${ko}" ] && set_perm "${KERNEL_DIR}/${ko}" 0 0 0644
done

# --- config file -----------------------------------------------------
if [ -f "${MODPATH}/netboost.conf" ]; then
    ui_print "  config: netboost.conf found"
fi

ui_print "----------------------------------------"
ui_print " Install complete. Reboot to activate."
ui_print " After boot: cat /proc/netboost"
ui_print "----------------------------------------"
