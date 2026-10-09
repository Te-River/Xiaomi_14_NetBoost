#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Rewrite module.prop description so the KernelSU manager shows the LIVE
# status (scenario / algo / qdisc / loaded LKMs) at the very front.
# Called by nb.sh after every scenario/stock/algo switch.
#
# usage: update-display.sh [scenario-label]

MODDIR="${0%/*}"
[ -f "${MODDIR}/module.prop" ] || exit 1

# scenario label: argument > state file > netboost.conf > boost
SC="${1:-$(cat "${MODDIR}/scenario" 2>/dev/null)}"
[ -n "${SC}" ] || SC="$(sed -n 's/^SCENARIO=//p' "${MODDIR}/netboost.conf" 2>/dev/null)"
[ -n "${SC}" ] || SC="boost"

ALGO="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)"
[ -n "${ALGO}" ] || ALGO="unknown"
QD="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null)"
[ -n "${QD}" ] || QD="unknown"
MODS="$(grep -cE '^(tcp_bbr3|tcp_bbr|tcp_westwood) ' /proc/modules 2>/dev/null)"
case "${MODS}" in ''|*[!0-9]*) MODS=0 ;; esac

# LingXi daemon status (v2.7.0+): on = auto-scenario engine running
LX="off"
if [ -f "${MODDIR}/lingxi.pid" ] && kill -0 "$(cat "${MODDIR}/lingxi.pid")" 2>/dev/null; then
    LX="on"
fi

# NOTE: keep this string free of '#' and '&' (sed replacement safety).
DESC="[模式:${SC}|算法:${ALGO}|qdisc:${QD}|LKM:${MODS}/3|灵犀:${LX}] 小米14内核网络加速+灵犀式自动场景(RSRP预判/小区学习/快速回网/场景择优). nb.sh wifi 手动切场景, lingxi.sh status 查看自动判定, nb.sh stock 恢复原厂."

sed -i "s#^description=.*#description=${DESC}#" "${MODDIR}/module.prop" 2>/dev/null
echo "netboost display: ${SC} / ${ALGO}+${QD} / LKM ${MODS}/3"
