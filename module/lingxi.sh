#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# LingXi - 灵犀式自动场景引擎 for NetBoost (Xiaomi 14 / android14-6.1)
#
# 参考华为"灵犀算法"的策略层, 在 NetBoost 的 nb.sh 场景引擎之上增加
# 感知(采样)与决策(状态机)两层, 四项核心能力:
#
#   1. 场景智能预判  : RSRP 快速衰减检测, 提前进入 weak 策略
#   2. 网络择优      : 自动识别场景并调用 nb.sh <scenario> (复用执行层)
#   3. 弱信号快速恢复: "出电梯"检测 -> 清悬挂 TCP 连接 + 刷新路由缓存
#   4. 自主学习      : cellmap 记录历史弱信号小区, 二次进入免预热直切
#
# 不可复现部分(天线/射频/基带参数)不在此模块范围内, 见 README。
#
# usage (root):
#   lingxi.sh start        启动守护进程 (service.sh 在开机时调用)
#   lingxi.sh stop         停止
#   lingxi.sh status       当前判定状态与依据
#   lingxi.sh once         单次采样+输出 (调试用)
#   lingxi.sh reset-map    清空基站学习库 (cellmap)

MODDIR="${0%/*}"
CONF="${MODDIR}/netboost.conf"
LOG="${MODDIR}/netboost.log"
PIDF="${MODDIR}/lingxi.pid"

# ---- 持久化数据目录 (模块目录之外, 模块更新/重装不触碰) ----
DATA_DIR="/data/adb/netboost_data"
STATE="${DATA_DIR}/lingxi.state"
MAP="${DATA_DIR}/cellmap.csv"
persist_init() {
    mkdir -p "${DATA_DIR}" 2>/dev/null
    chmod 700 "${DATA_DIR}" 2>/dev/null
    # 兜底迁移: 旧版本把 state/cellmap 放在模块目录 (模块更新会清掉)
    [ -s "${MODDIR}/cellmap.csv" ] && [ ! -s "${MAP}" ] && \
        mv -f "${MODDIR}/cellmap.csv" "${MAP}" 2>/dev/null
    [ -s "${MODDIR}/lingxi.state" ] && [ ! -s "${STATE}" ] && \
        mv -f "${MODDIR}/lingxi.state" "${STATE}" 2>/dev/null
}
persist_init

# ---- 配置 (可在 netboost.conf 覆盖) ----
[ -f "${CONF}" ] && . "${CONF}" 2>/dev/null

LINGXI_ENABLE="${LINGXI_ENABLE:-1}"
LINGXI_INTERVAL_ON="${LINGXI_INTERVAL_ON:-5}"       # 亮屏采样间隔(s)
LINGXI_INTERVAL_OFF="${LINGXI_INTERVAL_OFF:-15}"    # 灭屏采样间隔(s)
LINGXI_WEAK_RSRP="${LINGXI_WEAK_RSRP:--105}"        # 弱信号阈值 dBm
LINGXI_BAD_RSRP="${LINGXI_BAD_RSRP:--112}"          # 极弱阈值(恢复检测起点)
LINGXI_GOOD_RSRP="${LINGXI_GOOD_RSRP:--95}"         # 恢复阈值("出电梯")
LINGXI_DROP_DB="${LINGXI_DROP_DB:-8}"               # 单周期衰减量(预判弱区)
LINGXI_TRAIN_SWITCHES="${LINGXI_TRAIN_SWITCHES:-3}" # 60s 内小区切换次数 -> train
LINGXI_RTT_CROWD="${LINGXI_RTT_CROWD:-250}"         # 拥塞判定 RTT(ms)
LINGXI_LOSS_CROWD="${LINGXI_LOSS_CROWD:-20}"        # 拥塞判定丢包率(%)
LINGXI_MIN_HOLD="${LINGXI_MIN_HOLD:-30}"            # 场景最小保持(s)
LINGXI_PING_TARGET="${LINGXI_PING_TARGET:-223.5.5.5}"
LINGXI_PING_EVERY="${LINGXI_PING_EVERY:-30}"        # RTT 探测间隔(s)
LINGXI_MAP_MAX="${LINGXI_MAP_MAX:-1024}"             # 学习库上限(行)
LINGXI_LOG_SAMPLES="${LINGXI_LOG_SAMPLES:-0}"       # 1=每次采样写日志(调试)

log() { echo "[$(date '+%F %T')] [lingxi] $*" >> "${LOG}"; }

is_wifi() {
    case "$1" in
        wlan*) return 0 ;;
        *)     return 1 ;;
    esac
}

# ---------------------------------------------------------------- sampling
iface_of() {
    ip route get "${LINGXI_PING_TARGET}" 2>/dev/null \
        | sed -n 's/.*dev \([a-z0-9]*\).*/\1/p' | head -n1
}

# 蜂窝 RSRP: dumpsys telephony.registry, 多级解析, 失败输出空
# NOTE: AOSP SignalStrength.toString() prints mLteRsrp=-95 / mNrRsrp=-105
# (capital R!) -- a case-sensitive 'rsrp=' match silently misses them and
# the whole engine goes blind. Match case-insensitively, NR first.
rsrp_of() {
    local t v
    t=$(timeout 4 dumpsys telephony.registry 2>/dev/null) || return 0
    for pat in 'mNrRsrp=[-0-9]+' 'mLteRsrp=[-0-9]+' \
               'rsrp[= ][ ]*[-0-9]+' 'dbm[= ][ ]*[-0-9]+'; do
        # iterate ALL matches: on dual-SIM phones the first entry can be
        # the IDLE SIM's "unknown" sentinel (2147483647) - keep scanning
        for v in $(echo "${t}" | grep -ioE "${pat}" | grep -oE '[-0-9]+$'); do
            case "${v}" in -*) echo "${v}"; return 0 ;; esac
        done
    done
    return 0
}

# 当前小区 ID (学习库主键), 失败输出空 -> 学习功能自动降级
# AOSP CellIdentity.toString(): LTE '{ mMcc=460 mMnc=11 mCi=123456789 ... }',
# NR '{ mMcc=460 mMnc=11 mNci=987654321 ... }' (HyperOS 同源, 字段一致)
cell_of() {
    local t v
    t=$(timeout 4 dumpsys telephony.registry 2>/dev/null) || return 0
    for pat in 'mNci=[0-9a-fA-F]+' 'mCi=[0-9a-fA-F]+' \
               'nci=[0-9a-fA-F]+' '\bci=[0-9a-fA-F]+' \
               'mCid=[0-9a-fA-F]+' 'cid=[0-9a-fA-F]+'; do
        for v in $(echo "${t}" | grep -ioE "${pat}" | grep -oE '[0-9a-fA-F]+$'); do
            # skip the unknown sentinel and placeholder -1
            [ "${v}" != "2147483647" ] && [ "${v}" != "-1" ] && [ -n "${v}" ] && \
                { echo "${v}"; return 0; }
        done
    done
    return 0
}

# 原始样本回写: 字段名因 ROM/版本而异, 猜不如抓。学习库为空时把
# telephony.registry 的关键原始行落盘, 供 WebUI"学习库明细"展示,
# 用于按真实格式修正解析 (限 4KB, 仅在 cellmap 尚未建立时写一次)。
DIAG="${DATA_DIR}/diag_dump.txt"
diag_dump() {
    [ -s "${DIAG}" ] && return 0
    timeout 4 dumpsys telephony.registry 2>/dev/null \
        | grep -iE 'SignalStrength|CellIdentity|mCellInfo|Phone Id|ServiceState' \
        | head -c 4096 > "${DIAG}" 2>/dev/null
}

wifi_rssi_of() {
    local v=""
    v=$(timeout 3 iw dev wlan0 link 2>/dev/null \
        | grep -o 'signal[: ]*-[0-9]\+' | head -n1 | grep -o '\-[0-9]\+')
    if [ -n "${v}" ]; then echo "${v}"; return 0; fi
    timeout 4 dumpsys wifi 2>/dev/null \
        | grep -o 'RSSI=[-0-9]\+' | head -n1 | cut -d= -f2
}

# RTT(ms) 与丢包率(%), 低频调用
probe_rtt() {
    local out rtt loss
    out=$(timeout 5 ping -c 3 -W 1 "${LINGXI_PING_TARGET}" 2>/dev/null) \
        || { echo "0 100"; return 0; }
    rtt=$(echo "${out}" | grep -o '/[0-9.]\+/' | head -n1 | tr -d '/')
    loss=$(echo "${out}" | grep -o '[0-9]\+%' | head -n1 | tr -d '%')
    [ -n "${rtt}" ] || rtt=0
    [ -n "${loss}" ] || loss=0
    echo "${rtt} ${loss}"
}

screen_on() {
    [ "$(timeout 4 dumpsys power 2>/dev/null \
        | grep -m1 -o 'mWakefulness=[0-9]' | cut -d= -f2)" = "1" ]
}

# ---------------------------------------------------------------- cellmap
# 行格式: cell_id,hits,weak_hits,last_seen  (仅存本地, 不上传)
map_touch() {  # map_touch <cell>  -> 命中数自增/新增
    [ -n "$1" ] || return 0
    local now tmp
    now=$(date +%s)
    tmp="${MAP}.tmp"
    awk -F, -v OFS=, -v c="$1" -v t="${now}" '
        $1==c {found=1; $2=$2+1; $4=t; print; next}
        NF>=4 {print}
        END   {if(!found) print c",1,0",t}
    ' "${MAP}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${MAP}" || \
        printf '%s,1,0,%s\n' "$1" "${now}" > "${MAP}" 2>/dev/null
    # 超限淘汰: 按最近活跃保留一半
    if [ -s "${MAP}" ] && [ "$(wc -l < "${MAP}" 2>/dev/null)" -gt "${LINGXI_MAP_MAX}" ]; then
        sort -t, -k4 -nr "${MAP}" | head -n $((LINGXI_MAP_MAX / 2)) > "${tmp}" \
            && mv -f "${tmp}" "${MAP}"
    fi
}

map_is_weak() {  # exit 0 = 历史弱信号小区 (weak_hits >= 3)
    [ -n "$1" ] && [ -s "${MAP}" ] || return 1
    awk -F, -v c="$1" '
        $1==c { f=1; if ($3>=3) ok=1 }
        END   { exit (f && ok) ? 0 : 1 }
    ' "${MAP}" 2>/dev/null
}

map_mark_weak() {  # map_mark_weak <cell> -> weak_hits 自增
    [ -n "$1" ] && [ -s "${MAP}" ] || return 0
    local tmp="${MAP}.tmp"
    awk -F, -v OFS=, -v c="$1" -v t="$(date +%s)" '
        $1==c {$3=$3+1; $4=t} {print}
    ' "${MAP}" > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${MAP}"
}

# ---------------------------------------------------------------- recovery
# 灵犀"出电梯 1 秒回网"的应用层近似:
#   - ip route flush cache : 丢弃失效路由缓存
#   - ss -K 清悬挂态连接    : fin-wait-1/last-ack/close-wait 属半死连接,
#     清掉后应用侧 socket 立即报错重连; 不动 syn-* 以免误杀建连中的新连接
do_recovery() {
    log "recovery: rsrp ${prev_rsrp}dBm -> ${rsrp}dBm, flushing stale state"
    ip route flush cache 2>/dev/null
    if command -v ss >/dev/null 2>&1; then
        ss -K state fin-wait-1  >/dev/null 2>&1
        ss -K state last-ack    >/dev/null 2>&1
        ss -K state close-wait  >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------- decision
# 读取全局采样值 (iface/rsrp/cellid/rssi/rtt/loss) -> 判定 candidate 并执行
decide() {
    # 状态变量 (由 run_loop 维护): current last_cand cand_streak since
    #        prev_rsrp prev_cell drops switches window_start recov_cd
    local candidate="" reason=""

    if is_wifi "${iface}"; then
        candidate="wifi"; reason="iface=${iface} rssi=${rssi:-?}dBm"
    else
        # --- 灵犀1: 衰减率预判 (灵敏度优先, 单 tick 生效) ---
        if [ -n "${rsrp}" ] && [ -n "${prev_rsrp}" ]; then
            d=$((rsrp - prev_rsrp))
            if [ "${d}" -le "-${LINGXI_DROP_DB}" ]; then
                drops=$((drops + 1))
            else
                drops=0
            fi
            if [ "${drops}" -ge 2 ]; then
                candidate="weak"
                reason="pred: rsrp drop ${d}dB x${drops} (${prev_rsrp}->${rsrp})"
            fi
        fi
        # --- 灵犀4: 学习库命中 (免预热直切) ---
        if [ -z "${candidate}" ] && map_is_weak "${cellid}"; then
            candidate="weak"; reason="learn: cell ${cellid} known-weak"
        fi
        # --- 当前状态识别 ---
        if [ -z "${candidate}" ] && [ -n "${rsrp}" ]; then
            if [ "${rsrp}" -le "${LINGXI_WEAK_RSRP}" ]; then
                candidate="weak"; reason="rsrp=${rsrp} <= ${LINGXI_WEAK_RSRP}"
            elif [ "${switches}" -ge "${LINGXI_TRAIN_SWITCHES}" ]; then
                candidate="train"; reason="cell switches x${switches}/60s"
            elif [ "${rtt}" -ge "${LINGXI_RTT_CROWD}" ] \
              || [ "${loss}" -ge "${LINGXI_LOSS_CROWD}" ]; then
                candidate="crowd"; reason="rtt=${rtt}ms loss=${loss}%"
            else
                candidate="boost"; reason="rsrp=${rsrp} rtt=${rtt}ms"
            fi
        fi
    fi
    [ -n "${candidate}" ] || return 0

    # --- 防抖: 普通场景需连续 2 tick 一致; 弱区预判立即生效 ---
    if [ "${candidate}" = "${last_cand}" ]; then
        cand_streak=$((cand_streak + 1))
    else
        cand_streak=1; last_cand="${candidate}"
    fi
    held=$(( $(date +%s) - since ))
    if [ "${candidate}" != "${current}" ] && [ "${held}" -ge "${LINGXI_MIN_HOLD}" ] \
       && { [ "${candidate}" = "weak" ] || [ "${cand_streak}" -ge 2 ]; }; then
        log "scene: ${current} -> ${candidate} (${reason})"
        sh "${MODDIR}/nb.sh" "${candidate}" >> "${LOG}" 2>&1
        current="${candidate}"; since=$(date +%s)
        [ "${candidate}" = "weak" ] && [ -n "${cellid}" ] && map_mark_weak "${cellid}"
        write_state
    fi

    # --- 灵犀3: 快速回网检测 (极弱 -> 达标, 60s 冷却, 单次触发) ---
    if ! is_wifi "${iface}" && [ -n "${rsrp}" ] && [ -n "${prev_rsrp}" ] \
       && [ "${prev_rsrp}" -le "${LINGXI_BAD_RSRP}" ] \
       && [ "${rsrp}" -ge "${LINGXI_GOOD_RSRP}" ] \
       && [ "$(date +%s)" -ge "${recov_cd}" ]; then
        do_recovery
        recov_cd=$(( $(date +%s) + 60 ))
    fi

    prev_rsrp="${rsrp}"; prev_cell="${cellid}"

    # persist candidate transitions immediately. Previously the state file
    # was written only on actual scenario switches, so the WebUI panel
    # showed a STALE candidate - e.g. lingering "wifi" long after leaving
    # Wi-Fi (worsened by the pre-v2.7.4 blind RSRP parsing, when蜂窝判定
    # never produced a new candidate at all).
    if [ "${last_cand}" != "${written_cand}" ]; then
        write_state
        written_cand="${last_cand}"
    fi
}

write_state() {
    cat > "${STATE}" <<EOF
scenario=${current}
since=${since}
candidate=${last_cand}
updated="$(date '+%F %T')"
EOF
}

# ---------------------------------------------------------------- main loop
run_loop() {
    current=""; last_cand=""; cand_streak=0; written_cand=""
    drops=0; switches=0; window_start=$(date +%s)
    prev_rsrp=""; prev_cell=""; rtt=0; loss=0; rssi=""
    recov_cd=0; last_rtt_probe=0
    if [ -f "${STATE}" ]; then
        . "${STATE}" 2>/dev/null && current="${scenario:-}"
    fi
    [ -n "${current}" ] || current="$(cat "${MODDIR}/scenario" 2>/dev/null || echo boost)"
    since=$(date +%s)
    write_state
    log "daemon started (base=${current}, map=$( [ -s "${MAP}" ] && wc -l < "${MAP}" || echo 0) cells)"
    [ -s "${MAP}" ] || diag_dump

    while :; do
        if screen_on; then interval="${LINGXI_INTERVAL_ON}"
        else interval="${LINGXI_INTERVAL_OFF}"; fi

        iface=$(iface_of)
        [ -n "${iface}" ] || { sleep "${interval}"; continue; }

        # 60s 小区切换滑窗
        now=$(date +%s)
        if [ $((now - window_start)) -ge 60 ]; then
            switches=0; window_start="${now}"
        fi

        if is_wifi "${iface}"; then
            rssi=$(wifi_rssi_of); rsrp=""; cellid=""
        else
            rsrp=$(rsrp_of); cellid=$(cell_of)
            # sanitize: mksh aborts the whole script on arithmetic with a
            # non-numeric operand -- a dirty rsrp value must never kill us
            case "${rsrp}" in ''|*[!0-9-]*) rsrp="" ;; esac
            if [ -n "${cellid}" ] && [ "${cellid}" != "${prev_cell}" ]; then
                switches=$((switches + 1))
            fi
            [ -n "${cellid}" ] && map_touch "${cellid}"
            now=$(date +%s)
            if [ $((now - last_rtt_probe)) -ge "${LINGXI_PING_EVERY}" ]; then
                read -r rtt loss <<EOF2
$(probe_rtt)
EOF2
                last_rtt_probe="${now}"
            fi
        fi

        [ "${LINGXI_LOG_SAMPLES}" = "1" ] && \
            log "sample: iface=${iface} rsrp=${rsrp:-na} cell=${cellid:-na} rtt=${rtt} loss=${loss}% rssi=${rssi:-na}"

        decide
        sleep "${interval}"
    done
}

# ---------------------------------------------------------------- cli
status() {
    . "${STATE}" 2>/dev/null
    echo "daemon    : $([ -f "${PIDF}" ] && kill -0 "$(cat "${PIDF}")" 2>/dev/null && echo running || echo stopped)"
    echo "scenario  : ${scenario:-?} (since ${since:-?})"
    echo "candidate : ${candidate:-?}"
    echo "cells     : $([ -s "${MAP}" ] && wc -l < "${MAP}" || echo 0) learned, $( [ -s "${MAP}" ] && awk -F, '$3>=3{n++}END{print n+0}' "${MAP}" || echo 0) known-weak"
    echo "thresholds: weak<=${LINGXI_WEAK_RSRP}dBm drop=${LINGXI_DROP_DB}dB/cycle train=${LINGXI_TRAIN_SWITCHES}/60s crowd rtt>=${LINGXI_RTT_CROWD}ms"
    echo "hint      : tail -f ${LOG} | grep lingxi"
}

case "$1" in
    start)
        [ "${LINGXI_ENABLE}" = "1" ] || { log "disabled by config"; exit 0; }
        if [ -f "${PIDF}" ] && kill -0 "$(cat "${PIDF}")" 2>/dev/null; then
            echo "already running"; exit 0
        fi
        # supervisor mode: setsid detaches the engine from the service.sh
        # session (survives Android phantom process cleanup of the parent),
        # SIGHUP ignored, and the engine auto-restarts 5s after any death
        # (phantom killer / LMK / aborted arithmetic).
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "${0}" __daemon >/dev/null 2>&1 &
        else
            sh "${0}" __daemon >/dev/null 2>&1 &
        fi
        echo $! > "${PIDF}"
        echo "started (pid $(cat "${PIDF}"))"
        # sync module.prop desc so the KSU manager shows 灵犀:on
        [ -f "${MODDIR}/update-display.sh" ] && sh "${MODDIR}/update-display.sh" >/dev/null 2>&1
        ;;
    stop)
        if [ -f "${PIDF}" ]; then
            P=$(cat "${PIDF}")
            # negative pid kills the whole process group (supervisor+engine)
            kill -- -"${P}" 2>/dev/null || kill "${P}" 2>/dev/null
        fi
        rm -f "${PIDF}"; echo stopped
        # sync module.prop desc so the KSU manager shows 灵犀:off
        [ -f "${MODDIR}/update-display.sh" ] && sh "${MODDIR}/update-display.sh" >/dev/null 2>&1 ;;
    __daemon)
        trap '' HUP
        # re-entry guard: the pid file may briefly hold the (exited)
        # setsid wrapper pid instead of ours, or start may be invoked
        # twice while the first supervisor is booting - only one may run
        OLD="$(cat "${PIDF}" 2>/dev/null)"
        if [ -n "${OLD}" ] && [ "${OLD}" != "$$" ] \
           && kill -0 "${OLD}" 2>/dev/null; then
            log "supervisor already running (pid ${OLD}), exit"
            exit 0
        fi
        echo $$ > "${PIDF}"
        while :; do
            run_loop
            log "engine exited (rc=$?), restart in 5s"
            sleep 5
        done ;;
    once)
        iface=$(iface_of)
        if is_wifi "${iface}"; then
            echo "iface=${iface} (wifi) rssi=$(wifi_rssi_of)dBm"
        else
            rsrp=$(rsrp_of); cellid=$(cell_of)
            read -r rtt loss <<EOF2
$(probe_rtt)
EOF2
            echo "iface=${iface} rsrp=${rsrp:-na}dBm cell=${cellid:-na} rtt=${rtt}ms loss=${loss}%"
        fi
        ;;
    status)  status ;;
    reset-map) rm -f "${MAP}"; log "cellmap reset"; echo "cellmap cleared" ;;
    *) echo "usage: lingxi.sh start|stop|status|once|reset-map" ;;
esac
