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
ui_print "  Extracting files..."
mkdir -p "${KERNEL_DIR}"
cd "${MODPATH}" || abort "cannot enter module dir"

# copy .ko files that were bundled into the zip
for ko in netboost_core.ko tcp_bbr3.ko; do
    if [ -f "${ko}" ]; then
        cp -f "${ko}" "${KERNEL_DIR}/${ko}"
        chmod 644 "${KERNEL_DIR}/${ko}"
        ui_print "  staged: ${ko}"
    else
        ui_print "  warning: ${ko} not found in package"
    fi
done

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

# --- set permissions ------------------------------------------------
set_perm_recursive "${MODPATH}" 0 0 0755 0644
set_perm "${KERNEL_DIR}/netboost_core.ko" 0 0 0644
set_perm "${KERNEL_DIR}/tcp_bbr3.ko" 0 0 0644

# --- config file -----------------------------------------------------
if [ -f "${MODPATH}/netboost.conf" ]; then
    ui_print "  config: netboost.conf found"
fi

ui_print "----------------------------------------"
ui_print " Install complete. Reboot to activate."
ui_print " After boot: cat /proc/netboost"
ui_print "----------------------------------------"
