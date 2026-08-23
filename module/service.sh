#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost boot service - Xiaomi 14 (SM8650 / android14-6.1 GKI)
#
# Runs in late_start service mode. Loads the two kernel modules and applies
# the configured scenario. All commands run in KernelSU BusyBox ash.

MODDIR="${0%/*}"
KERNEL_DIR="${MODDIR}/kernel"
CONF="${MODDIR}/netboost.conf"
LOG="${MODDIR}/netboost.log"

# default scenario if no config file: boost (all-round for CN mobile networks)
SCENARIO="boost"

# load user config if present
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

sysctlw() {
    # sysctlw <path> <value> <label>
    echo "$2" > "$1" 2>>"${LOG}" && log "$3=$2" || log "FAILED $3 ($1)"
}

log "=== NetBoost boot service (scenario=${SCENARIO}) ==="

# --- 1. load kernel modules -----------------------------------------
# Load order matters: congestion-control providers first (they register
# "bbr3"/"bbr"/"westwood"), then netboost_core which picks the default.
# All are independent LKMs; failures degrade gracefully per-module.
for mod in tcp_bbr3 tcp_bbr tcp_westwood netboost_core; do
    if [ -f "${KERNEL_DIR}/${mod}.ko" ]; then
        if ! grep -q "^${mod} " /proc/modules 2>/dev/null; then
            insmod "${KERNEL_DIR}/${mod}.ko" 2>>"${LOG}" && \
                log "loaded ${mod}.ko" || log "FAILED to load ${mod}.ko"
        fi
    fi
done

# --- 2. apply scenario preset (algo switch via kernel module) --------
if [ -r /proc/netboost ]; then
    case "${SCENARIO}" in
        boost|train|crowd|weak|wifi|game)
            echo "scenario=${SCENARIO}" > /proc/netboost 2>>"${LOG}" && \
                log "applied scenario=${SCENARIO}" || log "FAILED to apply scenario"
            ;;
        *)
            log "unknown scenario '${SCENARIO}', keeping module default"
            ;;
    esac
    cat /proc/netboost >> "${LOG}"
else
    # fallback: netboost_core.ko missing/failed - switch algo via sysctl
    # directly so at least the congestion control change still happens.
    case "${SCENARIO}" in
        crowd) NB_ALGO="cubic" ;;
        weak)  NB_ALGO="westwood" ;;
        *)     NB_ALGO="bbr3" ;;
    esac
    echo "${NB_ALGO}" > /proc/sys/net/ipv4/tcp_congestion_control 2>>"${LOG}" && \
        log "fallback: algo=${NB_ALGO} via sysctl" || \
        log "fallback failed: algo ${NB_ALGO} not available"
fi

# --- 3. common TCP tuning (applies to ALL scenarios, zero-config) ----
# Disable slow start after idle: keeps throughput after idle periods.
sysctlw /proc/sys/net/ipv4/tcp_slow_start_after_idle 0 tcp_slow_start_after_idle

# Do not save metrics: avoids stale RTT/cwnd from previous connections
# (important after base-station handover).
sysctlw /proc/sys/net/ipv4/tcp_no_metrics_save 1 tcp_no_metrics_save

# TCP Fast Open: shave one RTT off repeat connections.
sysctlw /proc/sys/net/ipv4/tcp_fastopen 3 tcp_fastopen

# MTU black-hole probing: if an intermediate hop drops large packets
# (CGNAT / roaming paths), fall back to a smaller MSS instead of stalling.
# Fixes the "stuck at game login, works when there is an update" pattern.
sysctlw /proc/sys/net/ipv4/tcp_mtu_probing 1 tcp_mtu_probing

# Aggressive TCP keepalive: keep NAT/conntrack mappings alive so sessions
# are not silently dropped by short CGNAT timeouts (common on roaming MVNOs).
sysctlw /proc/sys/net/ipv4/tcp_keepalive_time 60 tcp_keepalive_time
sysctlw /proc/sys/net/ipv4/tcp_keepalive_intvl 15 tcp_keepalive_intvl
sysctlw /proc/sys/net/ipv4/tcp_keepalive_probes 3 tcp_keepalive_probes

# Socket buffers: raise the ceiling so a high-BDP path (5G / wide-area
# peering) can actually fill its window instead of being capped.
sysctlw /proc/sys/net/ipv4/tcp_rmem "262144 524288 16777216" tcp_rmem
sysctlw /proc/sys/net/ipv4/tcp_wmem "262144 524288 16777216" tcp_wmem
sysctlw /proc/sys/net/core/rmem_max 16777216 rmem_max
sysctlw /proc/sys/net/core/wmem_max 16777216 wmem_max

# NOTE: tcp_ecn intentionally left at kernel default. CN carrier middleboxes
# frequently blackhole ECN-marked packets; forcing ECN on causes stalls.

# --- 4. qdisc per scenario -------------------------------------------
# BBR needs fq for pacing; fq_codel suits loss-driven algos.
case "${SCENARIO}" in
    boost|train|wifi|game)
        sysctlw /proc/sys/net/core/default_qdisc fq default_qdisc
        ;;
    crowd|weak)
        sysctlw /proc/sys/net/core/default_qdisc fq_codel default_qdisc
        ;;
esac

# --- 5. refresh manager display (live status at the front) ----------
if [ -f "${MODDIR}/update-display.sh" ]; then
    sh "${MODDIR}/update-display.sh" "${SCENARIO}" >> "${LOG}" 2>&1
fi

log "=== NetBoost boot service done ==="
