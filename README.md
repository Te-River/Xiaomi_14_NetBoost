# NetBoost - 小米14 内核级网络加速模块

针对小米 14（SM8650 / 骁龙 8 Gen3，`android14-6.1` GKI 内核）的内核级网络协议优化 KernelSU 模块。

## 核心思路

GKI 内核默认只编译了 CUBIC 等少量 TCP 拥塞控制算法，BBR/Westwood 等更适合移动网络的算法并未内置。NetBoost 通过**内核模块（.ko）**把 BBRv3 等算法补进内核，并提供**场景感知**的算法切换能力，针对中国移动网络的不同使用场景选择最合适的算法。

## 场景-算法选型（基于调研）

| 场景 | 网络特征 | 推荐算法 | 理由 |
|---|---|---|---|
| `boost` 全能默认 | 中国移动网络通用 | **BBRv3 + fq** | 地铁/高铁/人群密集场景综合表现最好，遇真实拥塞收敛、随机丢包不误判 |
| `train` 高铁/地铁 | 高频基站切换、RTT 剧烈波动、吞吐骤降 | **BBRv3** | 基于带宽/RTT 建模，切换后快速恢复，不依赖丢包信号 |
| `crowd` 演唱会/高密度 | 基站过载、带宽被压缩、严重拥塞 | **CUBIC** | 丢包驱动+公平性好，多用户竞争下不激进抢占 |
| `weak` 卫生间/弱信号 | 高随机丢包、低带宽、RTT 抖动 | **Westwood** | 专为无线随机丢包设计，丢包不盲目减窗 |
| `wifi` 家用 WiFi | bufferbloat、多设备、延迟抖动 | **BBRv3 + fq** | 低排队延迟，配合 fq qdisc 效果最佳 |
| `game` 游戏登录卡死 | 互联带宽窄的运营商（如广电 192）单流 ~500KB/s，登录同步慢到像卡死 | **BBRv3 + 专项调优** | 见下方"游戏登录卡死"说明 |

> 注意：BBRv3 在高 RTT/高丢包跨境链路下带宽利用率可能低于 BBRv1 系变体，故保留手动切换能力。

## 游戏登录卡死（已并入默认配置）

针对"点击登录后一直转圈，但游戏有更新时反而能进去"的模式（典型：广电 192 玩国服游戏）。根因是登录后的配置/资源同步走**单条 TLS 长连接**，被运营商互联瓶颈压在 ~500KB/s；而更新走 CDN 多连接不受影响。这些调优现在是默认 `boost` 场景的一部分，装完即生效，无需手动切到 `game`：

- `tcp_mtu_probing=1`：绕开 MTU 黑洞（CGNAT 路径大包被丢导致 TLS 握手卡死）
- `tcp_keepalive` 60s/15s/3 次：防 CGNAT 短超时把登录会话静默掐断
- `rmem_max/wmem_max=16MB` + `tcp_rmem/tcp_wmem` 上限 16MB：让高 BDP 路径真正填满窗口而不是被接收窗口卡死
- BBRv3 + fq：丢包/抖动下维持单流吞吐，不像 CUBIC 一丢包就减半

> 诚实声明：如果瓶颈是运营商在互联点的**硬性单流限速**，内核参数无法突破，只能靠游戏自身多连接。以上调优对"丢包/窗口受限"型瓶颈有效。

## 模块组成

```
netboost/
├── kernel/
│   ├── tcp_bbr3/          # BBRv3 拥塞控制 backport（GPL-2.0，来自 hrimfaxi/tcp_bbr_modules）
│   ├── tcp_bbr/           # BBRv1（原样移植 android14-6.1 树内 net/ipv4/tcp_bbr.c）
│   └── tcp_westwood/      # Westwood+（原样移植 android14-6.1 树内 net/ipv4/tcp_westwood.c）
├── module/                # KernelSU 模块包
│   ├── module.prop        # 模块元数据（描述行 = 实时状态）
│   ├── customize.sh       # 安装脚本
│   ├── service.sh         # 开机加载模块+应用场景
│   ├── nb.sh              # 场景/算法切换 CLI + stock 一键恢复（纯 sysctl）
│   ├── netboost.conf      # 默认场景配置
│   ├── webroot/           # KernelSU WebUI
│   └── uninstall.sh       # 卸载清理
├── scripts/build.sh       # 一键构建脚本
└── docs/                  # 技术文档
```

> v2.6.0 起不再有 `netboost_core` 管理模块：其依赖的 `filp_open`/`kernel_read`/`kernel_write` 未被小米 14 官方内核导出（insmod 必失败），场景管理全部移入 `nb.sh`（纯 sysctl，行为完全一致且更透明）。

## 构建

### 方式一：DDK 容器（推荐）

```bash
./scripts/build.sh                 # 默认 android14-6.1
./scripts/build.sh --kmi android14-6.1
```

需要 docker 或 podman。镜像为 `ghcr.io/ylarod/ddk-min:<kmi>-<日期tag>`（默认 `20260313`，可用 `DDK_TAG=` 覆盖），容器内自动探测内核树 `/opt/ddk/kdir/<kmi>` 和 clang 工具链，以 GKI 同款 clang（LLVM=1）编译。产物在 `out/netboost-android14-6.1.zip`。

### 方式二：本地内核树

```bash
./scripts/build.sh --local
./scripts/build.sh --kdir /path/to/kernel
```

模块 Makefile 也支持双模式：传 `KDIR=` 走 gcc 经典路径，传 `KERNEL_SRC=... CLANG_DIR=...` 走 clang/DDK 路径。

### 方式三：GitHub Actions

推送到 `main` 分支自动构建；打 `v*` tag（如 `v2.3.0`）自动构建并发布 Release（附带模块 zip + 自动变更记录）。

## 安装

1. 在 KernelSU Manager 中安装 `out/netboost-android14-6.1.zip`
2. 重启
3. **完成。无需任何手动配置。**

默认 `boost` 场景开机自动应用：BBRv3 + fq + MTU 黑洞探测 + NAT 保活 + 16MB 缓冲，覆盖地铁/高铁/人群密集/弱信号/家用 WiFi/游戏登录全部场景。想确认生效可验证：

```bash
su -c "/data/adb/modules/netboost/nb.sh status"
su -c "cat /proc/sys/net/ipv4/tcp_congestion_control"   # 应显示 bbr3
```

## 使用（全部可选，进阶玩家才需要）

默认零配置已覆盖所有场景。以下仅在你想精细控制时使用：

### 切换场景

```bash
su -c "/data/adb/modules/netboost/nb.sh train"   # 高铁/地铁
su -c "/data/adb/modules/netboost/nb.sh crowd"   # 演唱会/高密度
su -c "/data/adb/modules/netboost/nb.sh weak"    # 卫生间/弱信号
su -c "/data/adb/modules/netboost/nb.sh wifi"    # 家用 WiFi（原厂保活参数）
```

### 手动切换算法

```bash
su -c "/data/adb/modules/netboost/nb.sh algo bbr3"
su -c "/data/adb/modules/netboost/nb.sh algo bbr"        # BBRv1，限速路径（如广电）实测备选
su -c "/data/adb/modules/netboost/nb.sh algo cubic"
su -c "/data/adb/modules/netboost/nb.sh algo westwood"
```

### 临时恢复原厂参数（A/B 排查）

```bash
su -c "/data/adb/modules/netboost/nb.sh stock"   # 恢复本机原厂 sysctl（首次调优前自动备份）
```

重启或 `nb.sh <场景>` 会重新应用调优。排查"WiFi 变慢 / 支付宝风控是否与模块有关"就用它做对照实验。

BBRv1 内置速率限制探测器，在被 policer 限速的路径上重传率明显低于 BBRv3（吞吐相近）；广电这类互联带宽被压缩的网络建议实测对比（对上行/游戏包效果更直接）。

### 更换开机默认场景

编辑 `/data/adb/modules/netboost/netboost.conf`，改 `SCENARIO=` 后重启。一般不需要动。

## WebUI（管理器内直接打开）

KernelSU 管理器中打开本模块 → 点「WebUI」按钮，即可在图形界面里：

- 查看实时状态：当前算法/场景/qdisc/模块逐个加载状态/vermagic 匹配情况/全部调优参数
- 一键切换：6 个场景（算法+队列组合）、4 个算法（未注册的自动置灰）
- 诊断：**重试加载模块**（现场复现 insmod 并显示内核报错）、运行日志、内核日志（unknown symbol / CRC 不匹配等真实原因都在这里）
- 3 秒自动刷新，可关闭

WebUI 通过 KernelSU 官方 `kernelsu` JS 接口以 root 执行命令，无外部依赖、离线可用。

## 管理器实时状态显示

KernelSU 管理器中，模块描述的第一段就是实时状态（开机后由 `update-display.sh` 自动写入）：

```
[模式:boost|算法:bbr3|qdisc:fq|LKM:3/3] ...
```

- `LKM:3/3` 表示三个算法内核模块全部加载成功；显示 `0/3` 或更小 = 模块没加载上（大概率 vermagic 不匹配，见下方故障排查），此时自动回退 `cubic`，MTU/保活/缓冲调优不受影响
- 运行时切换场景会同步刷新显示：

```bash
su -c /data/adb/modules/netboost/nb.sh train   # 切场景
su -c /data/adb/modules/netboost/nb.sh status  # 查看实时状态
```

## 故障排查

- **`tcp_congestion_control` 显示 cubic / `LKM:0/3`**：内核模块没加载成功。内核要求模块的 vermagic 与设备 `uname -r` **完全一致**，否则 `insmod` 报 `Invalid module format`。诊断：

```bash
su -c "uname -r"                                    # 设备内核版本
su -c "tail -20 /data/adb/modules/netboost/netboost.log"
su -c "insmod /data/adb/modules/netboost/kernel/tcp_bbr3.ko"   # 直接看报错
```

  确认是 vermagic 不匹配后，把 `uname -r` 的完整字符串写入仓库 `kernel/TARGET_RELEASE`（或构建时传 `NB_KERNEL_RELEASE=`），重新构建即可；安装时 `customize.sh` 也会自动比对 `BUILD_RELEASE` 并在管理器日志里警告不匹配。

- **当前构建已钉扎**：`kernel/TARGET_RELEASE` = `6.1.138-android14-11-g0c3d559bcd85-ab14529422`（小米 14 官方内核）。**系统 OTA 更新若变更内核版本，`uname -r` 随之改变，模块将无法加载**（管理器显示 `LKM:0/3`）——此时更新 `TARGET_RELEASE` 重新构建即可。容器内构建后会逐一断言三个 `.ko` 的 vermagic，不匹配直接失败，不会发出坏包。

- **WiFi 下感觉变慢 / 支付宝等 App 提示网络风险**：
  - v2.5.x 曾设置 `tcp_no_metrics_save=1`（不复用路径度量），导致每个新连接都完整慢启动，WiFi 下大量短连接（网页/图片/视频分片）会明显变慢。**v2.6.0 已彻底移除该参数**，恢复内核默认的度量缓存。
  - 支付宝的"网络环境风险"提示基于**出口 IP 信誉/网络环境指纹**判定。本模块不修改 IP/DNS/VPN/TLS，切到移动数据不再提示是因为换了出口 IP——原厂未 root 手机连某些 WiFi 同样会提示。
  - 拿不准就做对照实验：`nb.sh stock` 恢复原厂参数后重开支付宝复测；若仍提示，则与模块无关。

## 技术要点

- **官方内核只有 reno + cubic**：android14-6.1 的 `gki_defconfig` 与小米 14（shennong）的 `pineapple_GKI.config` 均无任何 `CONFIG_TCP_CONG_*` 条目，BBR/Westwood 都不在官方内核里。本模块自带 BBRv3 + BBRv1 + Westwood+ 三个算法 LKM，开机由 `service.sh` 加载、`nb.sh` 按场景偏好选择。
- **纯 sysctl 管理**：`android14-6.1` 内核未向模块导出 `tcp_set_default_congestion_control`（以及 `filp_open` 等文件 I/O），故 v2.6.0 起所有场景/算法管理走标准 sysctl 接口（`/proc/sys/net/ipv4/tcp_congestion_control` 等），由 `nb.sh` 在用户态完成，零内核符号依赖。
- **算法可用性检测**：可用算法列表在 `/proc/sys/net/ipv4/tcp_available_congestion_control`（`nb.sh` 用它做偏好回退：bbr3 → bbr → cubic）。
- **原厂快照**：首次调优前 `nb.sh` 把本机所有被改动的 sysctl 备份到 `netboost.orig`，`nb.sh stock` / 卸载脚本据此精确还原，不依赖硬编码的"默认值"。
- **BBRv3 适配**：`struct bbr`（约 200B）放不进 104B 的 `icsk_ca_priv`，backport 用动态分配解决；探测式兼容层自动适配 5.4~6.6+ 内核。
- **符号裁剪适配**：设备内核的 KMI 裁剪会砍掉构建树里存在的导出符号（`__tcp_send_ack`、`minmax_running_max`、`register_btf_kfunc_id_set`），backport 分别用 deny-list、本地实现、删除调用适配。
- **容错**：`.ko` 加载失败时自动回退下一个可用算法（最终 cubic），MTU/保活/缓冲调优不受影响；安装包在 CI 中自动校验完整性。

## 兼容性

- 目标：小米 14 / 14 Pro（SM8650），内核 `6.1.138-android14-...`（android14-6.1 GKI）
- 理论兼容所有 `android14-6.1` GKI 设备
- 已在本机 5.15 内核验证编译通过（API 与 GKI 6.1 一致）

## 许可证

- 项目代码：GPL-2.0-only
- BBRv3 backport：GPL-2.0-only（来自 [hrimfaxi/tcp_bbr_modules](https://github.com/hrimfaxi/tcp_bbr_modules)）
