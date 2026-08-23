#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Rewrite module.prop description so the KernelSU manager shows the LIVE
# status (scenario / algo / qdisc / loaded LKMs) at the very front.
# Called by service.sh at boot and by nb.sh after runtime switches.
#
# usage: update-display.sh [scenario-label]

MODDIR="${0%/*}"
[ -f "${MODDIR}/module.prop" ] || exit 1

# scenario label: argument > netboost.conf > boost
SC="${1:-$(sed -n 's/^SCENARIO=//p' "${MODDIR}/netboost.conf" 2>/dev/null)}"
[ -n "${SC}" ] || SC="boost"

ALGO="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
[ -n "${ALGO}" ] || ALGO="unknown"
QD="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
[ -n "${QD}" ] || QD="unknown"
MODS="$(grep -cE '^(tcp_bbr3|tcp_bbr|tcp_westwood|netboost_core) ' /proc/modules 2>/dev/null)"
case "${MODS}" in ''|*[!0-9]*) MODS=0 ;; esac

# NOTE: keep this string free of '#' and '&' (sed replacement safety).
DESC="[模式:${SC}|算法:${ALGO}|qdisc:${QD}|LKM:${MODS}/4] 小米14内核网络加速(BBRv3+fq+MTU探测+NAT保活+16MB缓冲). 进阶: su -c 'echo scenario=train|crowd|weak|wifi > /proc/netboost'; 重启自动恢复默认boost."

sed -i "s#^description=.*#description=${DESC}#" "${MODDIR}/module.prop" 2>/dev/null
echo "netboost display: ${SC} / ${ALGO}+${QD} / LKM ${MODS}/4"
