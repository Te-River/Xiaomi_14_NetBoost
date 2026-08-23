#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost CLI v2 - pure-sysctl scenario engine.
#
# The former netboost_core LKM was removed (its file-I/O helpers are not
# exported by the stock Xiaomi 14 kernel), so ALL scenario logic lives
# here in shell: algo preference, qdisc, keepalive and socket buffers.
#
# usage (root):
#   nb.sh                    show this help
#   nb.sh status             show live status
#   nb.sh <scenario>         boost|train|crowd|weak|wifi|game  (runtime
#                            switch; reboot re-applies netboost.conf)
#   nb.sh apply <scenario>   internal - used by service.sh at boot
#   nb.sh algo <name>        bbr3|bbr|westwood|cubic
#   nb.sh stock              restore ALL touched sysctls to the per-device
#                            backup taken before the first tune (A/B test
#                            aid; a reboot re-applies the module tuning)

MODDIR="${0%/*}"
CONF="${MODDIR}/netboost.conf"
ORIG="${MODDIR}/netboost.orig"
SCENF="${MODDIR}/scenario"
LOG="${MODDIR}/netboost.log"

# sysctls this module touches (relative to /proc/sys/)
TOUCHED="
net/ipv4/tcp_congestion_control
net/ipv4/tcp_slow_start_after_idle
net/ipv4/tcp_fastopen
net/ipv4/tcp_mtu_probing
net/ipv4/tcp_keepalive_time
net/ipv4/tcp_keepalive_intvl
net/ipv4/tcp_keepalive_probes
net/ipv4/tcp_rmem
net/ipv4/tcp_wmem
net/core/rmem_max
net/core/wmem_max
net/core/default_qdisc
"

log() { echo "[$(date '+%F %T')] $*" >> "${LOG}"; }

sysctlw() {
    # sysctlw <relpath> <value> <label>
    echo "$2" > "/proc/sys/$1" 2>>"${LOG}" && log "$3=$2" || \
        log "FAILED $3 (/proc/sys/$1)"
}

save_orig() {
    # one-time snapshot of every value we touch - the ONLY source of truth
    # for "stock" on this specific device (created before the first tune).
    [ -s "${ORIG}" ] && return 0
    for p in ${TOUCHED}; do
        v="$(cat "/proc/sys/${p}" 2>/dev/null)" || continue
        echo "${p}=${v}" >> "${ORIG}"
    done
    log "saved per-device stock sysctls -> netboost.orig"
}

orig_get() {
    # orig_get <relpath> -> stock value (empty when no backup / no entry)
    [ -s "${ORIG}" ] || return 0
    val="$(sed -n "s|^$1=||p" "${ORIG}" | head -1)"
    [ -n "${val}" ] && echo "${val}"
}

# --- per-scenario preferences ----------------------------------------
scn_prefs() {      # congestion-control preference, first available wins
    case "$1" in
        crowd) echo "cubic" ;;
        weak)  echo "westwood cubic" ;;
        *)     echo "bbr3 bbr cubic" ;;   # boost|train|wifi|game
    esac
}

scn_qdisc() {
    case "$1" in
        crowd|weak) echo "fq_codel" ;;
        *)          echo "fq" ;;
    esac
}

set_algo() {       # set_algo <prefs...>; echoes the algo that took effect
    AVAIL="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    for a in "$@"; do
        case " ${AVAIL} " in
            *" ${a} "*)
                if echo "${a}" > /proc/sys/net/ipv4/tcp_congestion_control 2>>"${LOG}"; then
                    echo "${a}"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

# --- scenario engine --------------------------------------------------
apply_scenario() {
    scn="$1"
    save_orig

    # algorithm
    if a="$(set_algo $(scn_prefs "${scn}"))"; then
        log "scenario=${scn} algo=${a}"
    else
        log "scenario=${scn} algo: none of the preferred algos available, keeping current"
    fi

    # qdisc
    sysctlw net/core/default_qdisc "$(scn_qdisc "${scn}")" default_qdisc

    # common tuning (all scenarios)
    # - keep cwnd after idle: no re-slow-start after app pauses
    sysctlw net/ipv4/tcp_slow_start_after_idle 0 tcp_slow_start_after_idle
    # - TCP Fast Open, client side only: full benefit for outbound
    #   connections while staying as close to the stock TCP fingerprint
    #   as possible (bit 2 "server" is pointless on a phone)
    sysctlw net/ipv4/tcp_fastopen 1 tcp_fastopen
    # - MTU black-hole probing: recover from CGNAT / roaming paths that
    #   silently drop large segments (fixes the "game login stuck" pattern)
    sysctlw net/ipv4/tcp_mtu_probing 1 tcp_mtu_probing
    # - 16MB buffer ceiling so high-BDP paths can actually fill the window
    sysctlw net/ipv4/tcp_rmem "262144 524288 16777216" tcp_rmem
    sysctlw net/ipv4/tcp_wmem "262144 524288 16777216" tcp_wmem
    sysctlw net/core/rmem_max 16777216 rmem_max
    sysctlw net/core/wmem_max 16777216 wmem_max

    # keepalive: aggressive probing only for cellular-leaning scenarios
    # (short CGNAT/NAT timeouts, e.g. on roaming MVNOs). Home-WiFi NAT
    # mappings live for hours - use the device's stock keepalive there
    # (fewer radio wake-ups, zero risk of tripping idle-state heuristics).
    case "${scn}" in
        wifi)
            kt="$(orig_get net/ipv4/tcp_keepalive_time)";   [ -n "${kt}" ] || kt=7200
            ki="$(orig_get net/ipv4/tcp_keepalive_intvl)";  [ -n "${ki}" ] || ki=75
            kp="$(orig_get net/ipv4/tcp_keepalive_probes)"; [ -n "${kp}" ] || kp=9
            ;;
        *)
            kt=60; ki=15; kp=3
            ;;
    esac
    sysctlw net/ipv4/tcp_keepalive_time   "${kt}" tcp_keepalive_time
    sysctlw net/ipv4/tcp_keepalive_intvl  "${ki}" tcp_keepalive_intvl
    sysctlw net/ipv4/tcp_keepalive_probes "${kp}" tcp_keepalive_probes

    # NOTE: tcp_no_metrics_save is intentionally NOT touched any more.
    # v2.5.x forced it to 1 ("never cache path metrics"), which throws
    # away the learned RTT/ssthresh and forces EVERY new connection into
    # a full slow start - reported as noticeably slower browsing on WiFi,
    # where traffic is dominated by short-lived connections. Metric
    # caching is stock kernel behavior and speeds up repeat connections.

    echo "${scn}" > "${SCENF}"
    sh "${MODDIR}/update-display.sh" "${scn}" >/dev/null 2>&1
}

stock() {
    if [ ! -s "${ORIG}" ]; then
        echo "ERROR: netboost.orig not found (tuning never applied)"
        exit 1
    fi
    while IFS='=' read -r p v; do
        [ -n "${p}" ] || continue
        if echo "${v}" > "/proc/sys/${p}" 2>/dev/null; then
            echo "restored ${p}=${v}"
        else
            echo "FAILED  ${p}=${v}"
        fi
    done < "${ORIG}"
    echo "stock" > "${SCENF}"
    sh "${MODDIR}/update-display.sh" "stock" >/dev/null 2>&1
    log "stock sysctls restored from netboost.orig (A/B test; reboot re-applies)"
    echo "OK: stock restored (temporary - reboot or nb.sh <scenario> re-applies)"
}

status() {
    scn="$(cat "${SCENF}" 2>/dev/null)"
    [ -n "${scn}" ] || scn="?"
    conf="$(sed -n 's/^SCENARIO=//p' "${CONF}" 2>/dev/null | tail -1)"
    echo "scenario  : ${scn}   (boot default from netboost.conf: ${conf:-boost})"
    echo "algo      : $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
    echo "available : $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    echo "qdisc     : $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
    echo "LKM       : $(grep -cE '^(tcp_bbr3|tcp_bbr|tcp_westwood) ' /proc/modules 2>/dev/null)/3"
    echo "keepalive : time=$(cat /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null) intvl=$(cat /proc/sys/net/ipv4/tcp_keepalive_intvl 2>/dev/null) probes=$(cat /proc/sys/net/ipv4/tcp_keepalive_probes 2>/dev/null)"
    echo "buffers   : rmem_max=$(cat /proc/sys/net/core/rmem_max 2>/dev/null) wmem_max=$(cat /proc/sys/net/core/wmem_max 2>/dev/null)"
}

help() {
    echo "NetBoost CLI"
    echo "  nb.sh status           show live status"
    echo "  nb.sh <scenario>       boost|train|crowd|weak|wifi|game"
    echo "  nb.sh algo <name>      bbr3|bbr|westwood|cubic"
    echo "  nb.sh stock            restore stock sysctls (A/B test, temporary)"
}

case "$1" in
    apply)
        case "$2" in
            boost|train|crowd|weak|wifi|game) apply_scenario "$2" ;;
            *) echo "ERROR: unknown scenario '$2'"; exit 1 ;;
        esac
        ;;
    boost|train|crowd|weak|wifi|game)
        apply_scenario "$1"
        echo "scenario applied: $1 (new connections)"
        ;;
    algo)
        case "$2" in
            bbr3|bbr|westwood|cubic) ;;
            *) echo "usage: nb.sh algo bbr3|bbr|westwood|cubic"; exit 1 ;;
        esac
        AVAIL="$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
        case " ${AVAIL} " in
            *" $2 "*)
                if echo "$2" > /proc/sys/net/ipv4/tcp_congestion_control 2>>"${LOG}"; then
                    log "algo=$2 (manual override)"
                    sh "${MODDIR}/update-display.sh" "custom($2)" >/dev/null 2>&1
                    echo "algo set: $2 (new connections)"
                else
                    echo "ERROR: failed to set algo"; exit 1
                fi
                ;;
            *)
                echo "ERROR: '$2' not available (module not loaded?)"; exit 1
                ;;
        esac
        ;;
    stock)  stock ;;
    status) status ;;
    *)      help ;;
esac
