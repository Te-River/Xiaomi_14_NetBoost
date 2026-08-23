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
│   ├── netboost_core/     # 管理核心模块：场景切换、算法管理（/proc/netboost）
│   └── tcp_bbr3/          # BBRv3 拥塞控制 backport（GPL-2.0，来自 hrimfaxi/tcp_bbr_modules）
├── module/                # KernelSU 模块包
│   ├── module.prop        # 模块元数据
│   ├── customize.sh       # 安装脚本
│   ├── service.sh         # 开机加载模块+应用场景
│   ├── netboost.conf      # 默认场景配置
│   └── uninstall.sh       # 卸载清理
├── scripts/build.sh       # 一键构建脚本
└── docs/                  # 技术文档
```

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

推送到 `main` 分支自动构建；打 `v*` tag 自动发布 Release。

## 安装

1. 在 KernelSU Manager 中安装 `out/netboost-android14-6.1.zip`
2. 重启
3. **完成。无需任何手动配置。**

默认 `boost` 场景开机自动应用：BBRv3 + fq + MTU 黑洞探测 + NAT 保活 + 16MB 缓冲，覆盖地铁/高铁/人群密集/弱信号/家用 WiFi/游戏登录全部场景。想确认生效可验证：

```bash
su -c "cat /proc/netboost"
su -c "cat /proc/sys/net/ipv4/tcp_congestion_control"   # 应显示 bbr3
```

## 使用（全部可选，进阶玩家才需要）

默认零配置已覆盖所有场景。以下仅在你想精细控制时使用：

### 切换场景

```bash
su -c "echo 'scenario=train' > /proc/netboost"   # 高铁/地铁
su -c "echo 'scenario=crowd' > /proc/netboost"   # 演唱会/高密度
su -c "echo 'scenario=weak'  > /proc/netboost"   # 卫生间/弱信号
su -c "echo 'scenario=wifi'  > /proc/netboost"   # 家用 WiFi
```

### 手动切换算法

```bash
su -c "echo 'algo=bbr3' > /proc/netboost"
su -c "echo 'algo=cubic' > /proc/netboost"
su -c "echo 'algo=westwood' > /proc/netboost"
```

### 更换开机默认场景

编辑 `/data/adb/modules/netboost/netboost.conf`，改 `SCENARIO=` 后重启。一般不需要动。

## 技术要点

- **GKI 符号约束**：`android14-6.1` 内核未向模块导出 `tcp_set_default_congestion_control` 等函数，故 `netboost_core` 通过标准 sysctl 接口（`/proc/sys/net/ipv4/tcp_congestion_control`）切换算法。
- **BBRv3 适配**：`struct bbr`（约 200B）放不进 104B 的 `icsk_ca_priv`，backport 用动态分配解决；探测式兼容层自动适配 5.4~6.6+ 内核。
- **加载顺序**：`tcp_bbr3.ko` 必须先于 `netboost_core.ko` 加载，否则 BBRv3 不可用。

## 兼容性

- 目标：小米 14 / 14 Pro（SM8650），内核 `6.1.138-android14-...`（android14-6.1 GKI）
- 理论兼容所有 `android14-6.1` GKI 设备
- 已在本机 5.15 内核验证编译通过（API 与 GKI 6.1 一致）

## 许可证

- 项目代码：GPL-2.0-only
- BBRv3 backport：GPL-2.0-only（来自 [hrimfaxi/tcp_bbr_modules](https://github.com/hrimfaxi/tcp_bbr_modules)）
