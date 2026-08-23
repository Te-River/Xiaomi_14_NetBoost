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
load_failed=0
for mod in tcp_bbr3 tcp_bbr tcp_westwood netboost_core; do
    if [ -f "${KERNEL_DIR}/${mod}.ko" ]; then
        if ! grep -q "^${mod} " /proc/modules 2>/dev/null; then
            insmod "${KERNEL_DIR}/${mod}.ko" 2>>"${LOG}" && \
                log "loaded ${mod}.ko" || { log "FAILED to load ${mod}.ko"; load_failed=1; }
        fi
    fi
done
if [ "${load_failed}" -ne 0 ]; then
    # insmod only says "failed"; the real reason (unknown symbol / CRC
    # mismatch) lands in the kernel log - capture it for diagnosis.
    dmesg 2>/dev/null | grep -iE 'netboost|bbr|westwood|unknown symbol|disagrees about version' \
        | tail -n 30 >> "${LOG}" 2>/dev/null
    log "(captured kernel log for failed insmod, see lines above)"
fi

# --- 2. apply scenario preset ----------------------------------------
# Expected algo preference per scenario (first available wins).
case "${SCENARIO}" in
    crowd) PREF="cubic" ;;
    weak)  PREF="westwood cubic" ;;
    *)     PREF="bbr3 bbr" ;;
esac

# 2a. let netboost_core apply the preset (algo + qdisc) when present
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
fi

# 2b. verify + repair: if the desired algo did not take effect (e.g. an
# algo LKM failed to load), pick the best available one directly via
# sysctl so we still end up on the best achievable algorithm.
AVAIL="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
CUR="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
for a in ${PREF}; do
    case " ${AVAIL} " in
        *" ${a} "*)
            if [ "${a}" != "${CUR}" ]; then
                echo "${a}" > /proc/sys/net/ipv4/tcp_congestion_control 2>>"${LOG}" && \
                    log "algo=${a} (set via sysctl verify/repair)" || \
                    log "FAILED to set algo=${a} via sysctl"
            fi
            break
            ;;
    esac
done

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
