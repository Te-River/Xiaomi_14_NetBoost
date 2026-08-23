#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost boot service - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# Runs in late_start service mode. Loads the three congestion-control
# provider LKMs and applies the configured scenario via nb.sh (pure
# sysctl - the netboost_core manager LKM was removed because its
# file-I/O helpers are not exported by the stock device kernel).
#
# All commands run in KernelSU BusyBox ash.

MODDIR="${0%/*}"
KERNEL_DIR="${MODDIR}/kernel"
CONF="${MODDIR}/netboost.conf"
LOG="${MODDIR}/netboost.log"

# default scenario if no config file: boost (all-round for CN networks)
SCENARIO="boost"
if [ -f "${CONF}" ]; then
    . "${CONF}" 2>/dev/null
fi

log() {
    echo "[$(date '+%F %T')] $*" >> "${LOG}"
}

# keep the log bounded (simple rotation: keep last ~64KB)
if [ -f "${LOG}" ] && [ "$(wc -c < "${LOG}")" -gt 131072 ]; then
    tail -c 65536 "${LOG}" > "${LOG}.tmp" 2>/dev/null && mv -f "${LOG}.tmp" "${LOG}"
fi

log "=== NetBoost boot service (scenario=${SCENARIO}) ==="

# --- 1. load congestion-control provider LKMs ------------------------
# They register "bbr3" / "bbr" / "westwood"; failures degrade gracefully
# per-module (nb.sh falls back to the next available algo, incl. cubic).
load_failed=0
for mod in tcp_bbr3 tcp_bbr tcp_westwood; do
    if [ -f "${KERNEL_DIR}/${mod}.ko" ]; then
        if ! grep -q "^${mod} " /proc/modules 2>/dev/null; then
            insmod "${KERNEL_DIR}/${mod}.ko" 2>>"${LOG}" && \
                log "loaded ${mod}.ko" || { log "FAILED to load ${mod}.ko"; load_failed=1; }
        fi
    else
        log "note: ${mod}.ko not bundled in this install"
    fi
done
if [ "${load_failed}" -ne 0 ]; then
    # insmod only says "failed"; the real reason (unknown symbol / CRC
    # mismatch) lands in the kernel log - capture it for diagnosis.
    dmesg 2>/dev/null | grep -iE 'netboost|bbr|westwood|unknown symbol|disagrees about version' \
        | tail -n 30 >> "${LOG}" 2>/dev/null
    log "(captured kernel log for failed insmod, see lines above)"
fi

# --- 2. apply scenario ------------------------------------------------
# nb.sh apply does: one-time stock snapshot (netboost.orig) -> algo
# preference -> qdisc -> common tuning -> scenario file + manager display.
sh "${MODDIR}/nb.sh" apply "${SCENARIO}" >> "${LOG}" 2>&1

log "=== NetBoost boot service done ==="
