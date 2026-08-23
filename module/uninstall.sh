#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost uninstaller - Xiaomi 14
#
# Unloads the three congestion-control LKMs and restores every sysctl the
# module touched. Restore values come from the per-device snapshot
# (netboost.orig, taken before the very first tune). If that snapshot is
# missing, fall back to android14-6.1 GKI stock defaults. A reboot right
# after uninstall gives a fully clean state anyway.

MODDIR="${0%/*}"
ORIG="${MODDIR}/netboost.orig"

# unload modules if loaded (no dependencies between them)
for m in tcp_westwood tcp_bbr tcp_bbr3; do
    if grep -q "^${m} " /proc/modules 2>/dev/null; then
        rmmod "${m}" 2>/dev/null
    fi
done

restore() { echo "$2" > "/proc/sys/$1" 2>/dev/null; }

if [ -s "${ORIG}" ]; then
    # exact per-device stock values
    while IFS='=' read -r p v; do
        [ -n "${p}" ] && restore "${p}" "${v}"
    done < "${ORIG}"
else
    # best-effort stock defaults (android14-6.1 GKI)
    restore net/ipv4/tcp_congestion_control cubic
    restore net/ipv4/tcp_slow_start_after_idle 1
    restore net/ipv4/tcp_fastopen 1
    restore net/ipv4/tcp_mtu_probing 0
    restore net/ipv4/tcp_keepalive_time 7200
    restore net/ipv4/tcp_keepalive_intvl 75
    restore net/ipv4/tcp_keepalive_probes 9
    restore net/ipv4/tcp_rmem "4194304 131072 6291456"
    restore net/ipv4/tcp_wmem "4096 16384 4194304"
    restore net/core/rmem_max 212992
    restore net/core/wmem_max 212992
    restore net/core/default_qdisc fq_codel
fi
# NOTE: tcp_ecn is never modified by this module (kernel default = 2).

exit 0
