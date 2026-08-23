#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost uninstaller - Xiaomi 14
#
# Unloads the kernel modules (best effort) and restores default TCP settings.
# A reboot right after uninstall gives a fully clean state anyway.

MODDIR="${0%/*}"

# unload modules if loaded
for m in netboost_core tcp_bbr3; do
    if lsmod | grep -q "^${m}"; then
        rmmod "${m}" 2>/dev/null
    fi
done

# restore conservative defaults (mirrors what service.sh sets)
echo cubic > /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null
echo 1 > /proc/sys/net/ipv4/tcp_slow_start_after_idle 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_no_metrics_save 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null
echo 0 > /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null
echo 7200 > /proc/sys/net/ipv4/tcp_keepalive_time 2>/dev/null
echo 75 > /proc/sys/net/ipv4/tcp_keepalive_intvl 2>/dev/null
echo 9 > /proc/sys/net/ipv4/tcp_keepalive_probes 2>/dev/null
echo "131072 262144 4194304" > /proc/sys/net/ipv4/tcp_rmem 2>/dev/null
echo "16384 16384 4194304" > /proc/sys/net/ipv4/tcp_wmem 2>/dev/null
echo 4194304 > /proc/sys/net/core/rmem_max 2>/dev/null
echo 4194304 > /proc/sys/net/core/wmem_max 2>/dev/null
echo fq_codel > /proc/sys/net/core/default_qdisc 2>/dev/null
# NOTE: tcp_ecn intentionally not touched - service.sh never modifies it.

exit 0
