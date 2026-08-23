# NetBoost 技术架构说明

## 1. 背景与目标

小米 14（SM8650 / 骁龙 8 Gen3）出厂搭载 `android14-6.1` GKI 内核。GKI（Generic Kernel Image）为保持 KMI 稳定，默认只编译少量 TCP 拥塞控制算法（CUBIC 等），更适合移动网络的 BBR / Westwood 等算法并未内置。

NetBoost 的目标：以 KernelSU 内核模块（.ko）形式，把 BBRv3 等算法补进内核，并提供**场景感知**的算法切换能力，针对中国移动网络的不同使用场景选择最合适的算法。

## 2. 场景调研结论

### 2.1 高铁 / 地铁（`train`）

**网络特征**：列车高速移动导致高频基站切换（高铁 30km 内可达 23 个基站），切换瞬间吞吐骤降甚至归零；RTT 毫秒级跃变（可超 300ms）；带宽亚秒级坍塌。

**算法选型**：BBRv3。BBR 系基于带宽/RTT 建模，不依赖丢包信号，切换后能快速重新探测带宽并恢复吞吐。相比丢包驱动的 CUBIC（切换丢包会触发窗口减半），BBRv3 恢复更快。

### 2.2 演唱会 / 高密度人群（`crowd`）

**网络特征**：数万人聚集导致基站过载（单小区用户数暴增数十倍），空口资源被挤爆，回传链路拥塞。这是**纯物理瓶颈**，任何算法都无法创造带宽。

**算法选型**：CUBIC。在严重拥塞下，CUBIC 的丢包驱动+公平性设计不会激进抢占带宽，避免加剧他人拥塞，整体体验更稳定。BBR 系在过度拥塞下可能因激进探测加剧不公平。

### 2.3 卫生间 / 弱信号（`weak`）

**网络特征**：信号弱导致高随机丢包（非拥塞丢包）、低带宽、RTT 抖动。传统丢包驱动算法会把随机丢包误判为拥塞，盲目减半窗口，导致吞吐极低。

**算法选型**：Westwood。专为无线随机丢包设计，通过 ACK 到达速率估计可用带宽，丢包时按带宽估计恢复窗口而非盲目减半，在弱信号下吞吐更高。

### 2.4 家用 WiFi（`wifi`）

**网络特征**：bufferbloat（缓冲膨胀）、多设备竞争、延迟抖动。Wi-Fi 弱网体现在 RTT 抖动和高丢包率，接入终端越多越弱。

**算法选型**：BBRv3 + fq。BBR 系低排队延迟特性配合 fq qdisc 的 pacing 机制，能有效降低 bufferbloat 带来的延迟。fq 为每条流维护独立队列，多设备下公平性更好。

## 3. 架构设计

```
┌─────────────────────────────────────────────┐
│              KernelSU Manager               │
└──────────────────┬──────────────────────────┘
                   │ 安装 zip
┌──────────────────▼──────────────────────────┐
│           /data/adb/modules/netboost        │
│  module.prop / customize.sh / service.sh    │
│  netboost.conf (SCENARIO=boost) / nb.sh     │
└──────────────────┬──────────────────────────┘
                   │ insmod (开机加载)
┌──────────────────▼──────────────────────────┐
│      tcp_bbr3.ko / tcp_bbr.ko /            │
│      tcp_westwood.ko (算法提供者)           │
│  注册 "bbr3" / "bbr" / "westwood"           │
└──────────────────┬──────────────────────────┘
                   │ nb.sh 写 sysctl（用户态）
┌──────────────────▼──────────────────────────┐
│  /proc/sys/net/ipv4/tcp_congestion_control  │
│  (内核标准接口，切换默认算法)                │
└─────────────────────────────────────────────┘
```

> v2.6.0 起**没有管理核心模块**：原 `netboost_core.ko` 依赖的 `filp_open` /
> `kernel_read` / `kernel_write` 未被小米 14 官方内核导出（insmod 报
> `Unknown symbol`，必失败），场景/算法管理全部移入 `nb.sh`（纯 sysctl）。

## 4. 关键技术决策

### 4.1 GKI 符号约束

调研确认：`android14-6.1` 内核的 `net/ipv4/tcp_cong.c` 只导出了 `tcp_register_congestion_control` / `tcp_unregister_congestion_control` / `tcp_slow_start` 等，**未导出** `tcp_set_default_congestion_control` / `tcp_get_default_congestion_control` / `tcp_get_allowed_congestion_control`；同时内核态文件 I/O（`filp_open` 等）也未导出。

因此算法切换、场景管理一律走**标准 sysctl 接口**（`/proc/sys/net/ipv4/tcp_congestion_control` 等），由 `nb.sh` 在用户态完成，零内核符号依赖。

### 4.2 BBRv3 适配

`struct bbr`（约 200B）放不进内核标准的 104B `icsk_ca_priv` 私有区。backport 方案：
- `icsk_ca_priv` 只存一个指针，`bbr_init()` 里 `kzalloc(GFP_ATOMIC)` 动态分配
- `bbr_release()` 释放，所有回调带 NULL 防护
- 探测式兼容层（`gen_kconfig.py` + `kapi_checklist` + `kapi_deny`）自动适配 5.4~6.6+ 内核，并屏蔽设备 KMI 已裁剪的符号

### 4.3 加载顺序与回退

`service.sh` 依次 `insmod` 三个算法 LKM（相互独立，单个失败不影响其它）。随后 `nb.sh apply <场景>` 按偏好选择算法：`bbr3` → `bbr` → `cubic`（依据 `tcp_available_congestion_control`）。模块全部失败时仍保持 cubic，MTU/保活/缓冲调优不受影响。

## 5. 模块接口

### `nb.sh` CLI（v2.6.0）

```
usage:
  nb.sh <boost|train|crowd|weak|wifi|game>   切换场景（运行时，重启恢复 conf 默认）
  nb.sh algo <bbr3|bbr|westwood|cubic>       手动切换算法
  nb.sh stock                                恢复本机原厂 sysctl（A/B 测试）
  nb.sh status                               查看实时状态
```

| 场景 | 算法偏好 | qdisc | keepalive |
|---|---|---|---|
| `boost` | bbr3→bbr→cubic | fq | 60s/15s/3（对抗 CGNAT） |
| `train` | bbr3→bbr→cubic | fq | 60s/15s/3 |
| `crowd` | cubic | fq_codel | 60s/15s/3 |
| `weak` | westwood→cubic | fq_codel | 60s/15s/3 |
| `wifi` | bbr3→bbr→cubic | fq | **原厂**（家宽 NAT 无需激进探测） |
| `game` | bbr3→bbr→cubic | fq | 60s/15s/3 |

状态文件：`/data/adb/modules/netboost/scenario`（当前场景，WebUI 读取）；
原厂快照：`netboost.orig`（首次调优前自动备份，`stock`/卸载据此还原）。

## 6. 构建流程

```
源码 → DDK容器(ghcr.io/ylarod/ddk-min:android14-6.1)
     → tcp_bbr3.ko + tcp_bbr.ko + tcp_westwood.ko
     → 打包 KernelSU zip (module/ + .ko)
     → out/netboost-android14-6.1.zip
```

DDK 容器携带与 GKI 匹配的内核头文件和 clang 工具链，确保 KMI 兼容（避免 `insmod: Exec format error`）。

## 7. 验证方法

```bash
# 模块加载
su -c "lsmod | grep -E 'netboost|tcp_bbr3|tcp_bbr |tcp_westwood'"

# 算法状态
su -c "/data/adb/modules/netboost/nb.sh status"
su -c "cat /proc/sys/net/ipv4/tcp_congestion_control"
su -c "cat /proc/sys/net/ipv4/tcp_available_congestion_control"

# 场景切换
su -c "/data/adb/modules/netboost/nb.sh weak"

# 吞吐测试（建议）
# 安装 iperf3 或使用 Speedtest 对比切换前后
```

## 8. 已知边界与风险

- **BBRv3 跨境场景**：高 RTT/高丢包跨境链路下带宽利用率可能低于 BBRv1 系变体，故保留手动切换。
- **Westwood 可用性**：`westwood` 算法依赖内核是否编译 `TCP_CONG_WESTWOOD`。若 GKI 内核未编译，`scenario=weak` 会回退到当前算法。可在自定义内核中开启。
- **算法切换仅影响新连接**：`tcp_congestion_control` 只影响新建 TCP 连接，已建立的连接不受影响。
- **模块签名**：若内核开启 `CONFIG_MODULE_SIG_FORCE`，模块需签名。KSU 内核通常未强制。
