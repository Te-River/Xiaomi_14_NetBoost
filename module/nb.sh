#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# NetBoost CLI - switch scenarios at runtime and keep the manager
# display (module.prop description) in sync.
#
# usage (root):
#   nb.sh                  show this help
#   nb.sh status           show /proc/netboost status
#   nb.sh <scenario>       boost | train | crowd | weak | wifi | game
#   nb.sh algo <name>      bbr3 | bbr | cubic | westwood

MODDIR="${0%/*}"

case "$1" in
    boost|train|crowd|weak|wifi|game)
        echo "scenario=$1" > /proc/netboost 2>&1 || {
            echo "ERROR: cannot write /proc/netboost (module loaded?)"; exit 1; }
        sh "${MODDIR}/update-display.sh" "$1"
        ;;
    algo)
        if [ -z "$2" ]; then
            echo "usage: nb.sh algo bbr3|bbr|cubic|westwood"; exit 1
        fi
        echo "algo=$2" > /proc/netboost 2>&1 || {
            echo "ERROR: cannot write /proc/netboost (module loaded?)"; exit 1; }
        sh "${MODDIR}/update-display.sh" "custom($2)"
        ;;
    status)
        cat /proc/netboost 2>/dev/null || \
            echo "netboost_core not loaded (see netboost.log)"
        echo "algo: $(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
        echo "qdisc: $(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
        echo "LKM loaded: $(grep -cE '^(tcp_bbr3|tcp_bbr|tcp_westwood|netboost_core) ' /proc/modules 2>/dev/null)/4"
        ;;
    *)
        echo "NetBoost CLI"
        echo "  nb.sh status          show live status"
        echo "  nb.sh <scenario>      boost|train|crowd|weak|wifi|game"
        echo "  nb.sh algo <name>     bbr3|bbr|cubic|westwood"
        ;;
esac
