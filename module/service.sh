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

# default scenario if no config file: wifi (safe for most users)
SCENARIO="wifi"

# load user config if present
if [ -f "${CONF}" ]; then
    . "${CONF}" 2>/dev/null
fi

log() {
    echo "[$(date '+%F %T')] $*" >> "${LOG}"
}

log "=== NetBoost boot service (scenario=${SCENARIO}) ==="

# --- 1. load kernel modules -----------------------------------------
# tcp_bbr3.ko must be loaded first so netboost_core can set it as default.
if [ -f "${KERNEL_DIR}/tcp_bbr3.ko" ]; then
    if ! lsmod | grep -q '^tcp_bbr3'; then
        insmod "${KERNEL_DIR}/tcp_bbr3.ko" 2>>"${LOG}" && \
            log "loaded tcp_bbr3.ko" || log "FAILED to load tcp_bbr3.ko"
    fi
fi

if [ -f "${KERNEL_DIR}/netboost_core.ko" ]; then
    if ! lsmod | grep -q '^netboost_core'; then
        insmod "${KERNEL_DIR}/netboost_core.ko" 2>>"${LOG}" && \
            log "loaded netboost_core.ko" || log "FAILED to load netboost_core.ko"
    fi
fi

# --- 2. apply scenario preset ---------------------------------------
if [ -r /proc/netboost ]; then
    case "${SCENARIO}" in
        train|crowd|weak|wifi)
            echo "scenario=${SCENARIO}" > /proc/netboost 2>>"${LOG}" && \
                log "applied scenario=${SCENARIO}" || log "FAILED to apply scenario"
            ;;
        *)
            log "unknown scenario '${SCENARIO}', keeping module default"
            ;;
    esac
    cat /proc/netboost >> "${LOG}"
fi

# --- 3. TCP stack tuning (safe values) ------------------------------
# Disable slow start after idle: keeps throughput after idle periods.
echo 0 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>>"${LOG}" && \
    log "tcp_slow_start_after_idle=0"

# Do not save metrics: avoids stale RTT/cwnd from previous connections.
echo 1 > /proc/sys/net/ipv4/tcp_no_metrics_save 2>>"${LOG}" && \
    log "tcp_no_metrics_save=1"

# TCP Fast Open: shave one RTT off repeat connections.
echo 3 > /proc/sys/net/ipv4/tcp_fastopen 2>>"${LOG}" && \
    log "tcp_fastopen=3"

# Explicit Congestion Notification (works well with BBRv3).
echo 1 > /proc/sys/net/ipv4/tcp_ecn 2>>"${LOG}" && \
    log "tcp_ecn=1"

# Increase socket receive/send buffer defaults for higher throughput.
echo "262144 524288 4194304" > /proc/sys/net/ipv4/tcp_rmem 2>>"${LOG}" && \
    log "tcp_rmem tuned"
echo "262144 524288 4194304" > /proc/sys/net/ipv4/tcp_wmem 2>>"${LOG}" && \
    log "tcp_wmem tuned"

# BBR works best with fq qdisc (pacing). Apply per scenario.
case "${SCENARIO}" in
    train|wifi)
        echo fq > /proc/sys/net/core/default_qdisc 2>>"${LOG}" && \
            log "default_qdisc=fq"
        ;;
    crowd|weak)
        echo fq_codel > /proc/sys/net/core/default_qdisc 2>>"${LOG}" && \
            log "default_qdisc=fq_codel"
        ;;
esac

log "=== NetBoost boot service done ==="
