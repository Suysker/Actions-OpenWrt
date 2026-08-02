# R4S 与 N5105 OpenWrt 构建架构

## 1. 文档状态

- 状态：设计修订 5；Linux 6.18 通道代码与本地 fixture 已完成，双平台 CI/Release 验收中
- 日期：2026-08-02
- 源码基线：Lean `master`
- 防火墙：firewall3 / iptables
- 工具链：Lean 原生 GCC 15
- 目标设备：NanoPi R4S、N5105 PVE
- 正式交付：同一次 source lock 下的双平台固件与一个经回下载复验的 Release

本文是唯一实施方案，不另建 Linux 6.18、R4S 或 N5105 的平行设计。当前 6.12 构建与发布闭环已经由 GitHub Actions 完整事务证明；整个仓库目标是否完成，以第 17 节的自动验证和第 18 节完成条件为准。

## 2. 目标与边界

项目解决四个问题：

1. 持续跟踪 Lean、feeds 和受控上游的最新版本，同时让同一轮构建可复核。
2. R4S 与 N5105 共用应用和安全默认，各自保留硬件相关优化。
3. 固件只包含用户实际需要的功能，不为未选择 package 维护兼容补丁。
4. 只有两套固件都通过字节级验收，且 draft Release 回下载复验成功，才公开发布。

稳定产品决策如下：

- 跟踪 Lean `master`，不切换到固定稳定分支。
- 使用 firewall3/iptables，不引入 firewall4/nftables 平行栈。
- `CONFIG_GCC_USE_VERSION_15=y` 是明确的工具链代际合同。
- common 只声明 selected kernel channel，不永久写死 Linux point release；目标配置选择 Lean testing channel，当前由 Lean 动态解析为 Linux 6.18。
- BBRv3 是内核能力，运行时名称保持 `bbr`，package 名保持 Lean 的 `kmod-tcp-bbr`。
- GitHub 官方 Actions 使用 `actions/*@main`，每次运行直接使用其最新默认分支。
- HAProxy LTS、AdGuardHome stable、GeoIP、Geosite、feeds、BBRv3 port 都按“每轮解析最新、轮内冻结”处理。
- DNS 端口、上游、缓存、节点、订阅和凭据属于用户常用的运行时配置，不进入跨设备固件默认。
- 普通 NAT、PassWall 和当前应用闭包没有 MPTCP 产品需求；production common 显式关闭 `CONFIG_KERNEL_MPTCP` 与 `CONFIG_KERNEL_MPTCP_IPV6`，以后只有明确用例和验收才重新纳入。

### 2.1 当前实施与验收状态

| 范围 | 当前状态 | 目标状态 |
|---|---|---|
| Lean master、iptables/firewall3、GCC15 | 已实现 | 保持 |
| 精简 package 闭包、provider、source lock、provenance | 已实现 | 保持 |
| 双平台构建、固件验收、Release 回下载复验 | Linux 6.12 已通过 | Linux 6.18 迁移后重新完整通过 |
| BBRv3 + `fq` + TurboACC factory default | Linux 6.12 已通过 | selected kernel 的 port 必须 clean-apply 并保留 module version 3 |
| R4S target、IRQ、OPP、zram、r8168、ARM crypto | 配置与源码语义已实现 | 保留 Lean 原生 steering |
| N5105 VirtIO、igc、4 queues、irqbalance | 配置与源码语义已实现 | 保持 `x86-64-v2` + Tremont tune；固件不配置 PVE host |
| Linux 6.18 | selected-kernel/schema 5、本地 fixture 已实现 | 同一 source lock 下完成双平台 CI/Release 验收 |

方案验收覆盖源码解析、配置闭包、双平台编译、成品检查和 Release 回下载复验。

Linux 6.12 当前交付证据为 [GitHub Actions run 30740478414](https://github.com/Suysker/Actions-OpenWrt/actions/runs/30740478414) 和 [openwrt-2026.08.02-r870](https://github.com/Suysker/Actions-OpenWrt/releases/tag/openwrt-2026.08.02-r870)。两个静态 profile contract 已通过；Linux 6.18 迁移后必须产生新的构建与 Release 证据。

### 2.2 sbwml 审计与采纳边界

`sbwml/r4s_build_script` 与 `sbwml/builder` 只作为公开优化意图和兼容经验来源，不作为可直接覆盖 Lean target 的第二基座：

- 采纳并持续验证 ARMv8 crypto/CRC、schedutil、RK3399 OPP、r8168、zram、PWM fan、原生 IRQ affinity、BBRv3 分系列 port、Linux 6.18 package 兼容和 PPP/PPPoE 网络改进。
- 保留本项目更适合 RK3399 big.LITTLE 的 `-mtune=cortex-a72.cortex-a53`、六个 CoreMark 线程、精简 package 闭包和无 DRM/Panfrost 的路由器定位。
- 不启用 sbwml 的 `CONFIG_ALL_KMODS`、`CONFIG_ALL_NONSHARED`、GPU、Docker、Samba、qBittorrent、NGINX/QUIC 等宽功能集。
- sbwml 启用的 `CONFIG_KERNEL_PSI` 属于内存压力观测能力，不是吞吐优化；当前没有 PSI consumer，production 保持关闭，只有未来引入明确监控/内存治理用例时再评审。
- O3、全局 LTO、Clang ThinLTO、Mold、LRNG、BPF/XDP、DPDK、PREEMPT_RT 等只可作为有独立指标的实验，不因上游列为“优化”就进入 production。Mold 主要优化构建耗时，不是固件运行时性能证据。
- Lean 已原生提供 sbwml 常用的大部分基础 sysctl；sbwml 的额外 UDP buffer 上限约 7.5 MiB，本项目已采用 16 MiB socket buffer，并只保留 `fq` 和 R4S swappiness 等产品语义，不复制整份 sysctl。
- 不接受删除整个 `target/linux/rockchip`、`target/linux/generic` 或 `package/kernel/linux` 后从私有 Gitea/远程脚本替换的做法，也不把授权凭据、私有 target 或争议源码带入公开生产链。
- sbwml point release 比 Lean 更新时也不单独覆盖 Lean 的 kernel version/hash；selected kernel 必须使用本轮锁定 Lean target 已集成并验证的精确版本。

## 3. 唯一事实源

每类事实只允许一个声明所有者：

| 领域 | 唯一事实源 |
|---|---|
| profile 集合 | `profiles/<device>/config.seed` 目录发现 |
| 共用/设备 Kconfig | `profiles/common/config.seed` 与 `profiles/<device>/config.seed` |
| 必选 package/布尔 config | 对应层的 `required-packages.txt` |
| 禁止 package | 对应层的 `forbidden-packages.txt` |
| 设备环境与目标 | 对应层的 `profile.env` |
| rootfs 默认 | 对应层的 `files/` |
| rootfs/锁定源码语义 | 对应层的 `semantics.json` |
| selected kernel channel | `profiles/common/config.seed` 中的 `CONFIG_TESTING_KERNEL` |
| 自定义 feeds | `feeds.custom.conf` |
| package provider | `profiles/common/providers.tsv` |
| Geo 数据角色与可信来源 | `profiles/common/geodata-sources.json` |
| 官方源码窄同步 | `profiles/common/source-overlays.json` |
| 源码兼容规则 | `profiles/common/source-compatibility.json` |
| BBRv3 provider 策略 | `patchsets/common/kernel/bbr3-sources.json` |
| BBRv3 module version 兼容 | `patchsets/common/kernel/bbr3-sources.json` 的兼容声明与 `patchsets/common/kernel/bbr3-module-version.patch` |
| 当轮动态版本、commit、hash | 运行时生成的 `source-lock.json` |

文档、workflow 和测试只引用这些声明，不复制设备名、包清单、版本或 hash。

## 4. 总体数据流

```text
repository declarations + rendered common/device intent + floating upstreams
  -> kernel_selection.py selects stable/testing metadata from locked Lean
  -> source_lock.py resolve/validate/materialize
  -> one immutable source-lock artifact
  -> locked Lean + feeds + source overlays
  -> apply controlled metadata and narrow compatibility
  -> defconfig -> normalize exact-forbidden children -> defconfig
  -> make download -> target/linux/prepare
  -> one final profile contract including prepared kernel source semantics
  -> make world reusing the prepared tree
  -> collect one build-provenance.json
  -> verify one profile delivery
  -> release_assets.py verifies and assembles both profiles
  -> draft Release upload
  -> download every asset -> reconstruct both deliveries -> verify again
  -> publish the same draft -> retain six verified production Releases
```

正式路径只有四层门禁：

1. `resolve-lock`：解析和冻结所有浮动输入。
2. `check-final-config`：验证最终 `.config`、package、provider、target、selected kernel 和 target/prepared-kernel 源码语义。
3. `verify-firmware`：验证真实固件、manifest、SBOM、模块、工具链、provenance 和 hash。
4. `verify-release`：从 draft Release 回下载，重建每个平台目录并复用同一个固件 verifier。

## 5. 模块划分与依赖关系

### 5.1 模块职责

| 模块 | 职责 |
|---|---|
| `scripts/source_lock.py` | 上游解析、schema 校验、digest、BBRv3 物化、feeds 与 source overlay 投影 |
| `scripts/kernel_selection.py` | 从渲染 Kconfig 与锁定 Lean target 唯一解析 channel、series、version 和 source hash；向所有消费者提供同一结构 |
| `scripts/kernel_patch.py` | 识别 Git/OpenWrt quilt patch、规范化 touched paths、拒绝危险路径并供 resolver/clean-apply 复用 |
| `scripts/profile_model.py` | profile 发现、common/device 合并、Kconfig 派生、package 合同计算 |
| `scripts/profile_contract.py` | 最终 config、seed drift、package、provider、target、kernel、rootfs/source 语义验收 |
| `scripts/profile_semantics.py` | 声明式验证 rootfs、Lean target patch 与 prepared kernel upstream 等价语义 |
| `scripts/apply_source_lock_artifacts.py` | 把 lock 中的精确 release metadata 写入唯一 package provider |
| `scripts/apply-source-compatibility.py` | 按声明式规则处理当前编译闭包内的非内核源码兼容，并以 selected kernel series 驱动系列相关 Kconfig 守卫 |
| `scripts/apply-profile-patches.sh` | 应用仓库 patch、源码兼容规则和本轮 BBRv3 patch stack |
| `scripts/collect-build-provenance.sh` | 从真实 build tree 生成平台交付目录和 `build-provenance.json` |
| `scripts/verify-firmware-artifacts.sh` | 平台交付的唯一验收器 |
| `scripts/release_assets.py` | 双平台聚合、专业资产命名、完整包/release index、回下载重建和复验 |
| `.github/workflows/openwrt-builder.yml` | 编排四层门禁，不解释领域 schema |
| `.github/workflows/update-checker.yml` | 定时调用同一个 resolver；source digest 变化时派发双平台构建 |

### 5.2 复用接口

- shell 只编排进程与文件，JSON/schema 解释由 Python 模块拥有。
- `source_lock.py`、`profile_contract.py` 和 patch applicator 不再分别用正则解释 `KERNEL_PATCHVER`；它们只消费 `kernel_selection.py` 的统一结果。
- BBRv3 resolver 与 clean-apply checker 不再分别解析 patch 路径；它们只消费 `kernel_patch.py` 的同一规范化 touched-path 集合。
- `apply-profile-patches.sh` 把 source-lock 中已经解析完成的 `kernel_series` 传给源码兼容执行器；兼容规则不得重新读取 target Makefile、猜测版本或维护第二份 series 映射。
- `render-profile.sh`、`check-profile-contract.sh`、`resolve-source-lock.sh`、`assemble-release.sh` 和 `verify-release-assets.sh` 都是薄 CLI。
- build、aggregate 和 release-download 三个边界复用 `verify-firmware-artifacts.sh`。
- 失败日志属于 diagnostics；正式资产只保留可复核交付及一个结构化 provenance。

### 5.3 命名与风格

- profile 与文件名使用 kebab-case，例如 `x86-n5105-pve`。
- Release tag 使用 `openwrt-YYYY.MM.DD-r<run>[.<attempt>]`；用户直接刷写的镜像使用 `openwrt-<profile>-<release-id>-<image-role>.img.gz`。
- Release 不暴露内部 `<profile>--<file>` 名称。每个 profile 只提供一个主刷写镜像和一个 `-full.tar.gz` 完整可复核包。
- JSON 字段与 Python 标识符使用 snake_case。
- 内核选择统一使用 `kernel_channel`、`kernel_series`、`kernel_version` 和 `kernel_source_sha256`；channel 只允许 `stable`/`testing`，不把 selected kernel 统称为 stable。
- report schema 使用明确整数版本；不为旧内部 schema 保留平行解释器。
- 路径安全检查位于真正执行 clone、copy、remove、archive reconstruction 的边界。
- 新设备只增加 `profiles/<device>` 声明，不修改 checker 或 matrix 分支。

## 6. 最新追踪与 source lock

### 6.1 “最新”与“可复核”同时成立

每次 prepare 都从浮动策略解析当前值：

- Lean `master`
- `feeds.custom.conf` 中每个 feed 的目标分支或默认分支
- OpenWrt 官方 core source overlay
- 当前受支持的最高 HAProxy LTS 分支最新 patch release
- 最新 AdGuardHome stable release
- `Loyalsoldier/geoip` 最新 `geoip.dat`
- `Loyalsoldier/v2ray-rules-dat` 最新 `geosite.dat`
- Lean 本轮 profile 所选 channel 对应的 target kernel
- 与该 kernel series 匹配的最新受信任 BBRv3 port

resolver 随即把 commit、精确 URL 和 SHA256 写入同一个 schema 5 lock。两个 build job 只消费该 lock，不在构建中再次查询 `latest` 或 branch HEAD。

这意味着：

- 仓库不永久钉死普通上游版本/hash。
- 同一轮 R4S 与 N5105 不会解析到不同版本。
- Release 中的 lock 能解释固件实际使用了什么。
- 新上游若与当前 Lean 不兼容，构建明确失败，不静默回退。

### 6.2 schema 5 内容

Linux 6.18 通道迁移把 source-lock 从 schema 4 升为 schema 5，不保留两个内部 schema 的平行解释器。顶层字段保持：

```text
schema
resolved_at
repository_commit
openwrt
feeds
source_overlays
upstream_artifacts
profiles
kernel_features
profile_digests
patch_digest
```

每个 `profiles.<name>` 至少记录：

```text
kernel_channel
kernel_target
kernel_series
kernel_version
kernel_source_sha256
target_check_regex
image_pattern
```

`kernel_features.bbr3.profile_kernel_series` 必须与 profile 的 selected kernel 完全一致；channel 变化即改变 profile digest 和 source-lock digest。

GitHub Actions 不写入 source lock。Action 在 workflow 开始时已由 GitHub 解析，运行中查询其 HEAD 不能证明已执行的字节。仓库只约束复用 Action 必须是官方 `actions/*@main`；最新行为由 GitHub 在每次运行时直接解析。

### 6.3 hash 策略

- release asset 必须有真实 SHA256。
- Geo 数据同时校验发布方 checksum 资产。
- BBRv3 patch 下载后计算 hash，并对精确 Linux version clean-apply。
- package metadata 不允许 `PKG_HASH:=skip` 或 `releases/latest/download`。
- `make download -j8` 是 OpenWrt 全部 source 的统一 hash 门禁。

### 6.4 selected kernel channel 与 Linux 6.18

selected kernel 只有一条解析路径：

1. `profiles/common/config.seed` 唯一表达 `CONFIG_TESTING_KERNEL`；两个设备 seed 不重复拥有该 symbol。
2. `kernel_selection.py` 从渲染结果确定 `stable` 或 `testing`。
3. resolver 从本轮锁定 Lean 的 `target/linux/<target>/Makefile` 分别读取 `KERNEL_PATCHVER` 或 `KERNEL_TESTING_PATCHVER`，再从 `include/kernel-<series>` 解析精确 version/hash。
4. 同一轮两个 profile 由 common 选择同一 channel；各 target 独立解析该 channel 对应的 series。当前 Rockchip/x86 都得到 6.18；未来若 Lean 为两个 target 提供不同 testing series，source-lock 分别记录并为每个 series 解析 BBRv3 port，不要求为了表面对齐而降级其中一个平台。
5. build 在最终 `.config`、target metadata、source-lock 和 provenance 四处复核同一个 selection；任何一处不同立即失败。

2026-08-02 审计时，Lean `f9dcc54b24e3f7fc7e8cd6db05f9e545eff67486` 为 Rockchip/x86 同时提供 stable 6.12、testing 6.18，精确 testing version 为 6.18.38；Linux 6.18 已是 kernel.org longterm。它们是可行性证据而不是永久构建输入，后续仍由 Lean master 动态解析。即使 sbwml 已更新到更高的 6.18 point release，本项目也不越过 Lean target 独立改 kernel hash。

testing channel 以后可能按 target 前进到其他 series。任一 profile 的 selected series 缺少可信 BBRv3 port、target patch 或当前闭包兼容性时，整轮构建必须停止且不发布；不得静默切回 6.12、普通 BBR 或其他 provider。

Lean 6.18 patch stack 当前还包含 PPP TX scatter-gather、PPPoE GRO/GSO、R4S target/OPP 与 I225/I226 EEE disable；仓库验证这些能力的源码语义与成品落地。

### 6.5 schema 5/6.18 迁移结果

当前实现已经完成以下收敛，不再保留旧路径：

- common 唯一声明 `CONFIG_TESTING_KERNEL=y` 与 MPTCP/MPTCP IPv6 负选择；两个设备 seed 不再重复拥有 kernel channel。
- `source_lock.py`、`profile_contract.py` 与 patch applicator 统一消费 `kernel_selection.py`；生产代码只有该模块解释 `KERNEL_PATCHVER`/`KERNEL_TESTING_PATCHVER`。
- BBRv3 resolver、materializer 与 clean-apply checker 统一消费 `kernel_patch.py`，同时接受真实 Git/quilt 格式并拒绝危险或不完整路径。
- source-lock schema 5 在 profile entry 中完整记录 channel/target/series/version/source hash；resolver、validator、digest、summary、applicator、provenance、firmware/Release verifier 与 fixtures 已同步升级，schema 4 明确拒绝。
- N5105 igc VLAN 合同使用 backport/prepared-upstream alternatives；common 直接检查 prepared kernel source 中的 PPP TX scatter-gather 与 PPPoE IPv4/IPv6 GRO/GSO 语义。
- workflow 在 `make download` 后执行 `make target/linux/prepare`，再运行唯一 final profile contract；`make world` 复用已验收的 prepared tree。

## 7. Profile 合并模型

### 7.1 common 与 device

```text
profiles/common/             两个平台共享
profiles/r4s/                NanoPi R4S 专属
profiles/x86-n5105-pve/      N5105 PVE 专属
```

renderer 按以下规则合并：

- 相同 Kconfig symbol 不能同时由 common 与 device 拥有。
- required/forbidden 规则不能跨层重复。
- common 与 device 的 rootfs 同路径不能覆盖。
- required package 自动派生 `CONFIG_PACKAGE_<name>=y`。
- required config 自动派生 `<symbol>=y`。
- exact-forbidden package 自动派生对应负选择。
- `config.seed` 只保存 target、CPU flags、数值、字符串和不能由 package 合同表达的选项。
- common 拥有两个设备共同的 `CONFIG_TESTING_KERNEL=y` 以及 MPTCP 负选择；设备 seed 不重复声明 kernel channel。

首次 `make defconfig` 后，normalizer 只处理 exact-forbidden 父应用遗留的已选子项；第二次 `defconfig` 后，`profile_contract.py` 一次性验证：

- rendered seed 的正选择未消失或变值；负选择未被重新选中。
- required/forbidden package 和 config。
- package provider 唯一性。
- target 与 image pattern。
- Lean selected kernel channel/series/version/hash 与 source lock。
- common/device rootfs 与锁定源码的稳定语义。

## 8. Feeds、provider 与精简闭包

自定义 feeds 保持用户指定的源头：

- `small`：`kenzok8/small`
- `kenzo`：`kenzok8/openwrt-packages`
- `sbwml`：`sbwml/luci-app-mosdns`
- `xiaorouji`：`Openwrt-Passwall/openwrt-passwall-packages`
- `passwall`：`Openwrt-Passwall/openwrt-passwall`
- `packages`：`openwrt/packages@master`

`source_lock.py` 解析并排序 feeds，`manage-custom-feeds.sh` 只消费其投影。provider selector 根据 `providers.tsv` 精确保留当前产品所需实现，再从 lock 重建全部 feed 索引。

安装阶段只把当前 profile 的 required package 交给 OpenWrt feeds installer，由 OpenWrt 展开真实 source/build/runtime dependency。未选择应用不会进入 Kconfig，也不会因为其 recipe 陈旧而成为本项目维护对象。

GeoIP 与 Geosite 的角色只在 `geodata-sources.json` 定义。resolver、validator 和 applicator 共用该合同；`v2ray-geodata` package 最终打包 Loyalsoldier 的两个当轮精确资产。

## 9. 共同固件策略

完整 package 集以 `profiles/common/required-packages.txt` 和各设备 required 文件为准。稳定功能意图包括：

- LuCI 与简体中文。
- firewall3/iptables、dnsmasq-full、IPv4/IPv6、PPPoE、iptables UPnP。
- PassWall 的 Xray、Hysteria、HAProxy、GeoIP/Geosite。
- MosDNS、SmartDNS、AdGuardHome。
- ddns-go、nlbwmon、ARP 绑定、自动重启、内存释放、ttyd、TurboACC、WOL。
- CoreMark、htop、lsof、SFTP server。
- signed packages、signature check、TLS certificate check、CycloneDX SBOM。

不在产品范围内的应用和替代栈由 `forbidden-packages.txt` 统一约束。精简通过 Kconfig 与最终 manifest 完成，不删除无关源码目录。

common 的内核/构建策略同样遵循精简原则：

- `CONFIG_TESTING_KERNEL=y` 只选择 Lean 的 testing channel；精确 series/version/hash 仍由当轮 lock 决定。
- `CONFIG_KERNEL_MPTCP` 与 `CONFIG_KERNEL_MPTCP_IPV6` 显式关闭。MPTCP 不加速普通 NAT 转发，也不是当前 PassWall 运行合同。
- 继续使用 `-O2`、GCC15、OpenSSL ASM/runtime dispatch；生产路径不启用全局 LTO、GC sections、Mold 或 Clang ThinLTO。
- 新的编译器/链接器选项必须分别证明运行性能、镜像体积或构建耗时收益，不能混称为“固件优化”。

## 10. 出厂配置与运行时边界

共同出厂默认：

- LAN `192.168.2.1/24`。
- DHCP 从 `.32` 开始，`limit=232`，租期 12 小时。
- WAN 使用 DHCP，WAN6 使用 DHCPv6。
- LAN DHCPv6/NDP 为 relay，WAN 为 relay master；LAN 保持 RA server 以发布前缀。
- 不写死跨设备的 `ethX`。
- 时区 `Asia/Shanghai`，启用 NTP client，保留上游 server 列表。
- 默认 qdisc 为 `fq`，socket receive/send buffer 上限 16 MiB。

固件不写入：

- 固定 root 密码。
- 私有软件源或跳过签名验证。
- WAN 管理入口。
- DNS 监听端口、上游、缓存、过滤规则和完整查询链。
- PassWall 节点、订阅和凭据。

dnsmasq-full、AdGuardHome、MosDNS、SmartDNS 和 PassWall 可以同时安装；监听端口、转发路径和缓存关系属于运行时配置，不进入跨设备固件默认。

## 11. R4S 专属优化

R4S 使用 Lean 当前原生 target 能力，并把可验证的 sbwml 优化意图纳入设备合同：

- RK3399 NanoPi R4S squashfs sysupgrade image。
- `-O2 -pipe -march=armv8-a+crc+crypto -mtune=cortex-a72.cortex-a53`。
- ARM64 AES/GHASH/CRC 加速。
- schedutil governor 与 Lean/R4S OPP patch 语义。
- R8168 驱动、PWM fan、cpufreq。
- 512 MiB LZ4 zram，`vm.swappiness=5`。
- 使用 target 自带网口映射：LAN `eth1`、WAN `eth0`。
- 使用 target 自带 IRQ affinity：两个网口分别固定在 CPU4/CPU5。
- 当前 packet steering 开启，不再叠加通用 irqbalance 作为第二所有者。
- 移除该路由器不需要的 Rockchip DRM/GPU 选择。

这些条目中，`CONFIG_TARGET_OPTIMIZATION` 控制 target userland，不能证明内核本身按 RK3399 微架构重新编译。sbwml 的 A72-only `CONFIG_KERNEL_CFLAGS` 不适用于同时包含 Cortex-A72 与 Cortex-A53 的 R4S，因此不复制，也不引入额外 kernel-specific flags。

### 11.1 OPP 超频风险

当前 Lean OPP 语义不是普通 governor 调整，而是把 RK3399 大核提升到 2.208 GHz、小核提升到 1.8 GHz，最高声明电压 1.325 V。项目跟随并验证该公开 target 的源码语义，明确记录其超频属性，不额外提高电压/频率、不删除温度保护，也不为此替换整个 Rockchip target。

### 11.2 IRQ、RPS 与 XPS 所有权

Lean 原生 R4S hotplug 把 eth0/eth1 IRQ 分配给 CPU4/CPU5，通用 packet steering 把物理设备的 RPS/XPS mask 写为全部六核 `0x3f`。production 固定复用这一套原生所有权，不叠加 irqbalance 或其他 steering 覆盖。

R4S 源码验收关注 target/prepared-kernel 的真实语义，不永久绑定 kernel point release 或某个 patch 文件名。

## 12. N5105 PVE 专属优化

N5105 profile 面向固定虚拟化合同：

- x86_64 generic、squashfs combined EFI gzip image。
- `-O2 -pipe -march=x86-64-v2 -mtune=tremont`。
- VirtIO NET/SCSI 使用 Lean x86_64 kernel built-in。
- WAN 使用 I225/igc PCIe passthrough。
- 唯一 `virtio_net` 识别为 LAN，唯一 `igc` 识别为 WAN。
- 两侧都设置为 4 combined queues，启用 irqbalance，关闭 RPS/packet steering。
- 接口缺失、重复或不能达到 4 队列时保留首次启动脚本并重试，不猜测接口角色。
- 验证 I225 EEE disable 与 igc VLAN offload 语义存在于本轮 Lean target patch stack 或 selected upstream kernel source。
- 排除未使用的通用物理网卡、USB、音频、GPU 和磁盘镜像格式。

推荐 PVE 配置：

```text
machine: q35
bios: ovmf
cpu: host
sockets: 1
cores: 4
balloon: 0
disk: VirtIO SCSI single + iothread + discard
LAN: VirtIO NIC, multiqueue=4
WAN: I225/igc PCIe passthrough
serial0: socket
```

`x86-64-v2` 要求 guest 可见 SSE3、SSSE3、SSE4.1、SSE4.2、POPCNT 和 CMPXCHG16B。`cpu: host` 还应暴露 AES/PCLMUL/SHA，供 OpenSSL runtime dispatch 使用。

N5105 属于 Jasper Lake/Tremont，四核四线程、无 AVX/AVX2。production 固定使用 `-march=x86-64-v2 -mtune=tremont`：针对 Tremont 调度，同时保留 guest/迁移兼容性；不使用 `-march=tremont`，也禁止需要 AVX 的 `x86-64-v3`。

PVE host 是 N5105 数据路径的一部分，但不属于固件可配置范围。方案只给出 OVMF/q35、`cpu: host`、vhost、VirtIO multiqueue=4、IOMMU、I225 passthrough 和无 balloon 的部署参数；guest 内不添加无法控制物理 CPU 的重复 cpufreq 策略。

## 13. BBRv3 合同

BBRv3 不能作为与内核无关的普通 kmod 下载。正确路径是：

1. 从 Lean target 解析 selected kernel channel、series、精确 version 与 source hash。
2. 从受信任 provider 策略解析匹配 series 的最新 BBRv3 port。
3. 下载 patch，计算 SHA256，并对精确 pristine Linux tag clean-apply。
4. 把当轮 patch 物化到 source-lock artifact。
5. 安装进 Lean 对应 `hack-*`/`backport-*` patch stack。
6. 继续使用 Lean `kmod-tcp-bbr`、`tcp_bbr.ko` 和运行名 `bbr`，保持 TurboACC 依赖关系。
7. 从 build tree 的每一份 `tcp_bbr.ko` ELF `.modinfo` 读取 `version=3` 和 vermagic。
8. 同时验证 `sch_fq.ko` 与同一 locked kernel vermagic。

BBRv3 provider patch 允许两种真实格式：

- Git format-patch：包含 `diff --git a/<path> b/<path>`。
- OpenWrt/quilt unified diff：使用配对的 `--- a/<path>` 与 `+++ b/<path>`，可以没有 `diff --git`。

`kernel_patch.py` 必须从两种格式生成同一 touched-path 集合，拒绝 NUL、绝对路径、`..`、不配对 header、空 patch 和逃逸目标。resolver、materializer 与 clean-apply checker 复用该解析结果；测试不能只用 `diff --git` 的一行伪 fixture。

2026-08-02 可行性审计已把 sbwml 当前 6.18 公开 port 的 20 个 quilt patch 顺序应用到 pristine Linux v6.18.38：20/20 clean-apply，通过 17 个 touched source paths；随后本项目 module-version companion 同样 clean-apply，最终保留 `BBR_VERSION=3` 与 `MODULE_INFO(version, ...)`。该结果证明 6.18 迁移可做，但正式构建仍必须按每轮 selected version 重新解析、冻结和验证，不能把本次 commit/hash 写成永久输入。

Lean 的 module stripping 会去掉普通 `MODULE_VERSION`。兼容合同仅在 provider 仍受影响时追加 direct `MODULE_INFO(version, ...)`；provider 已经保留时自动使用上游实现。

BBRv3 适用于路由器本机 IPv4 与 IPv6 TCP socket。它不控制 UDP/QUIC，也不改变普通 NAT 转发连接的端到端拥塞算法。PassWall/Xray 在路由器本机建立的 TCP outbound 会直接使用它。

首次启动只有在以下条件同时成立时才把 factory CCA 设置为 BBR：

- `/sys/module/tcp_bbr/version` 为 `3`。
- `sch_fq` 已加载。
- kernel 报告可用 CCA 包含 `bbr`。
- TurboACC 已选择 software flow offload，hardware flow offload 关闭。

脚本写入一次性标记；以后尊重用户的 TurboACC/CCA 选择。

## 14. 源码兼容策略

持续追踪 Lean master 与 GCC15 时，只有当前两套 profile 编译闭包内、且有真实失败证据的兼容项可以进入 `source-compatibility.json`。

执行器对每条规则只接受三种状态：

- 上游已经包含等价完整语义：记录为 upstream。
- 已知基线缺少该语义：执行最小、幂等变换。
- 文件或 recipe 漂移到不再可证明：明确失败并要求重新审计。

当前官方 source overlay 只同步产品闭包需要的窄路径，包括 GMP、PCRE2、MTD 和隔离的官方 CycloneDX generator 文件。同步目标由 `source-overlays.json` 决定，既不覆盖整份 Lean 核心目录，也不维护未选择 package。

### 14.1 target backport 与 upstream 等价语义

内核能力不能永久要求“必须存在某个 backport 文件”。每条 kernel source semantic 只接受三种结果：

- selected Lean patch stack 含有合同要求的完整语义：记录为 `backport`。
- patch 不再存在，但 `make target/linux/prepare` 后的 selected upstream kernel source 含有同一完整语义：记录为 `upstream`。
- 两边都不存在、只存在半实现或无法定位 prepared source：明确失败。

N5105 的 igc VLAN tag insertion/stripping 是首个必须使用该模型的合同：6.12 可由 backport 提供，6.18 已在 upstream `drivers/net/ethernet/intel/igc/igc_main.c` 中默认启用。判断必须检查真实源码锚点，不能只按“版本大于 6.16”推断，也不能因为 patch 文件消失就放弃验证。

最终 profile contract 在 `make download` 与 `make target/linux/prepare` 之后运行一次，同时检查最终 Kconfig、Lean target patch 和 prepared kernel source。这样没有第二个 checker，也不需要 resolver/build 各维护一套版本特判。

### 14.2 selected-kernel package Kconfig 兼容

Lean master 的 `package/kernel/linux/modules/other.mk` 当前只在 `LINUX_6_12` 条件内声明 `KERNEL_ZRAM_BACKEND_LZ4`，而 6.18 kernel 仍要求先启用 `ZRAM_BACKEND_LZ4` 才能选择 `ZRAM_DEF_COMP_LZ4`。直接删除 R4S 的 backend 合同会让界面配置看似收敛、实际内核却回落到其他压缩后端；替换整份 modules 文件则会把无关 package 和上游漂移一起纳入维护。

该兼容使用一条声明式 `kernel-series-config-guard` 规则，依赖链固定为：

```text
rendered profile intent
  -> source-lock selected kernel_series
  -> apply-profile-patches.sh
  -> apply-source-compatibility.py
  -> KernelPackage/zram/config
```

执行器只在目标 `define` 中定位声明 `KERNEL_ZRAM_BACKEND_LZ4` 的最内层 kernel-series guard，并接受三种状态：

- guard 已包含本轮 `LINUX_<major>_<minor>`：记录 `upstream`，不修改。
- backend 已由上游无条件声明：记录 `upstream-unconditional`，不修改。
- backend 仍只受其他明确 kernel series 保护：把本轮 token 幂等追加到同一 guard，并验证后置条件。

缺少声明、存在多个声明、条件结构不闭合或 guard 不是可证明的纯 kernel-series 表达式时必须失败。series token 只能从同一 source-lock 结果生成，规则文件不保存 `6.18.38`、kernel hash 或未来 series 枚举。R4S 继续同时要求 backend/default 两个 LZ4 Kconfig 和实际 `kmod-lib-lz4` package；x86 不因此选择 zram 或增加固件闭包。

## 15. GitHub Actions 事务

### 15.0 构建与发布授权边界

构建选择与 Release 授权是两个独立职责：

- `prepare / Select profiles` 只从 profile 目录发现构建矩阵；选择 `all` 就进入完整 Release 事务，不枚举或特判分支名。
- `build` 只依赖 profile 矩阵和 source lock，不理解发布令牌、tag 或资产命名。
- Release jobs 由当前 ref 自动选择授权：默认分支使用内置 `GITHUB_TOKEN`；非默认分支使用仓库已有的 `ACTIONS_TRIGGER_PAT`，因为当目标 commit 相对默认分支修改 workflow 时，GitHub 不允许内置 token 创建或更新指向该 commit 的 Release。

依赖图为 `profile 目录 -> prepare 矩阵 -> build artifacts -> aggregate -> draft -> re-download -> publish`。令牌选择只存在于 Release jobs 的 `GH_TOKEN` 环境边界，不新增第二套发布逻辑。tag 始终指向真实构建 commit，不得为规避权限而错挂到默认分支。

### 15.1 prepare / resolve-lock

- 从 profile 目录自动发现目标。
- 渲染 common/device kernel intent，并由共享 resolver 解析或接收一个完整 schema 5 source lock。
- incoming lock 必须属于当前 repository commit 且 digest 与 dispatch metadata 一致。
- 物化两种受支持格式的 BBRv3 patch，并对每个 selected kernel version clean-apply。
- 上传一个 `source-lock` artifact 供两个 build job 共用。

### 15.2 build / check-final-config / verify-firmware

每个平台：

1. checkout locked Lean commit。
2. 使用 locked feeds 与 source overlays。
3. 选择唯一 package providers，并只安装 required package 闭包。
4. 应用受控 release metadata、源码兼容和 BBRv3 patch。
5. 渲染 profile rootfs 与 config。
6. 两次 `make defconfig`，中间收敛 exact-forbidden 子选项。
7. `make download -j8`，随后 `make target/linux/prepare` 生成 selected prepared kernel tree。
8. 执行一次最终 profile contract，覆盖 config、package、provider、selected kernel、target backport 与 upstream source semantics。
9. 一次并行 `make world`，复用已准备的 kernel tree；失败时仅对首个安全 package target 收集 `-j1 V=sc` 诊断。
10. 收集并验证交付目录。

diagnostics 只在失败时上传。成功路径只上传 verified firmware artifact。

### 15.3 aggregate / verify-release / publish

- `release_assets.py assemble` 要求输入 profile 集合与 lock 完全一致。
- assembler 在复制前先对每个平台运行唯一 firmware verifier。
- assembler 从 lock 的 `image_pattern` 找到每个 profile 唯一主刷写镜像，发布为带 release id 的直接下载文件；完整平台交付打包为同名 `-full.tar.gz`。
- `release-index.json` 只保存 profile、主镜像原名/资产名、完整包名、大小和 SHA256，不向 Release 平铺内部 metadata 文件。
- 创建 draft Release 后，从 GitHub 重新下载所有资产。
- verifier 校验顶层 SHA256、index 覆盖范围和 tar 安全边界，从完整包重建两套原始目录，证明直接下载镜像与包内原件字节一致，再复用 firmware verifier。
- 全部通过后公开同一个 draft。
- 成功发布后只清理超出最近六个的已发布 `openwrt-*` Release。

任何 build、aggregate 或回下载失败都不会公开半套固件，也不会清理已有生产 Release。

## 16. 交付内容与 provenance

每个平台 delivery 包含：

- 固件 image。
- OpenWrt 生成的 manifest、config/version/feeds buildinfo、profiles.json、CycloneDX SBOM 和规范化为 `openwrt-sha256sums` 的上游校验表。
- 本轮 `source-lock.json`。
- 最终 `openwrt.config`。
- 单一 `build-provenance.json`。
- 覆盖交付目录全部文件的项目级 `SHA256SUMS`。

`build-provenance.json` 记录：

- profile、生成时间、source-lock digest、kernel channel/series/version/source hash。
- 受控 artifact metadata 变换证据。
- patch/源码兼容/BBRv3 断言。
- runner 事实。
- GCC path、GCC 15 version、target/kernel compiler flags、是否外部预编译工具链。
- 每一份 `tcp_bbr.ko` 与 `sch_fq.ko` 的路径、SHA256、vermagic；BBR 另含 module version。

正式 Release 不依赖工作流内临时日志。失败诊断仍保留 provider、patch、config、build log、ccache 和 module candidate 原始信息。

## 17. 验证方法

### 17.1 本地静态与 fixture 测试

```sh
bash -n diy-part1.sh diy-part2.sh scripts/*.sh tests/test-*.sh
find profiles -type f \( -path '*/etc/uci-defaults/*' -o -path '*/etc/hotplug.d/*' \) \
  -print0 | xargs -0 bash -n
python3 -m py_compile scripts/*.py tests/*.py
for test in tests/test-*.sh; do bash "$test"; done
for test in tests/test-*.py; do python3 "$test"; done
while IFS= read -r profile; do
  bash scripts/check-profile-contract.sh "$profile"
done < <(bash scripts/render-profile.sh list)
git diff --check
```

fixture 必须覆盖：

- schema 5 source-lock resolve/validate/digest/materialize，以及 schema 4 被明确拒绝。
- stable/testing channel 解析、缺失/重复 Kconfig、target 缺少对应变量、同 channel 不同 target series 的独立锁定，以及 final config/lock 不一致。
- feeds 与 source overlay 投影。
- profile common/device 合并和 seed drift。
- provider、artifact metadata 与源码兼容。
- selected-kernel package Kconfig guard 的当前系列原生、自动扩展、重复执行幂等和非规范条件漂移拒绝；R4S 必须在真实 Lean `make defconfig` 后同时保留 LZ4 backend/default 与 `kmod-lib-lz4`。
- Git format-patch 与 OpenWrt/quilt patch 的等价 touched-path 解析，以及绝对路径、`..`、NUL、空 patch、不配对 header 的拒绝。
- BBRv3 module-version 状态机、selected 6.18 directory provider 与 ELF metadata。
- kernel semantic 的 `backport`、`upstream`、missing/partial 三种状态，至少覆盖 6.12 backport 与 6.18 prepared-source 两条 igc VLAN 路径。
- common 的 testing channel 与 MPTCP 负选择不能在 defconfig 后漂移。
- firmware gzip/fwtool 容器。
- build provenance、固件 verifier、Release assemble 与 Release reconstruct verifier 的端到端闭环。

### 17.2 真实 resolver

```sh
profiles="$(bash scripts/render-profile.sh list | paste -sd, -)"
bash scripts/resolve-source-lock.sh resolve \
  "$profiles" /tmp/source-input/source-lock.json
bash scripts/resolve-source-lock.sh materialize \
  /tmp/source-input/source-lock.json /tmp/source-input
bash scripts/resolve-source-lock.sh digest \
  /tmp/source-input/source-lock.json
```

该步骤访问真实上游并验证受控 release、selected channel/series/version/hash、两 profile 同代和对应 BBRv3 port。Linux 6.18 首次迁移必须在 resolver 输出中同时看到 R4S/x86 的 `kernel_channel=testing`、同一 `kernel_series=6.18`，精确 point release 由当轮 Lean 决定。

## 18. 实施顺序与完成条件

### 18.1 一次性实施顺序

本次迁移作为一个完整变更实施，不建立长期阶段分支：

1. 把 testing channel 与 MPTCP 负选择收敛到 common，先实现 `kernel_selection.py` 和 schema 5，再切换所有消费者。
2. 实现共享 `kernel_patch.py`，让 BBRv3 resolver/materializer/clean-apply 同时支持 Git 与 quilt patch，并补齐安全 fixture。
3. 扩展声明式 kernel semantics 为 backport/prepared-upstream alternatives，修复 igc VLAN 6.18 误报。
4. 调整 build 顺序为 download、target prepare、唯一 final contract、world；同步 provenance 与固件/Release verifier。
5. 一次运行全部现有和新增测试，再使用真实 resolver 生成同一份双平台 6.18 source-lock。
6. 执行一次 GitHub Actions `profile=all`，完成双平台构建、聚合、draft 回下载复验和发布。
7. 全部通过后更新本节状态与实际 Action/Release 证据，移除实施期间的临时覆盖。

### 18.2 完成条件

以下条件全部成立才算完成：

1. 本地全部现有测试、语法检查和两个静态 profile contract 通过，并新增 selected-kernel、双 patch 格式和 upstream-or-backport fixtures。
2. common 唯一拥有 `CONFIG_TESTING_KERNEL=y` 与 MPTCP 负选择；设备 seed 不再声明 stable/testing。
3. schema 5 source-lock 记录两个 profile 的 channel/series/version/source hash，且不包含永久动态版本、Action 伪执行身份或跳过 hash 的输入。
4. workflow 中不存在 package 专用下载硬编码、文件大小启发式、成功态 diagnostics 或重复 kernel/patch 解释器。
5. R4S 与 N5105 在同一新 source lock 下选择 Linux 6.18 并都完成 `target/linux/prepare`、最终 source semantics 和 `make world`。
6. 对本轮精确 6.18 tag，BBRv3 provider patch 与 module-version compatibility clean-apply；两套成品都验证 BBRv3/sch_fq ELF metadata。
7. 两个平台都通过最终 config、firmware、manifest、SBOM、GCC15、selected kernel、SHA256 和 provenance 验证。
8. aggregate 只接受 lock 声明的完整 profile 集合；draft Release 只包含两个专业命名主镜像、两个完整包和全局 index/lock/SHA256，全部回下载后再次通过同一 verifier。
9. 任意分支的 `all` 都成功公开指向当次构建 commit 的同一 draft，cleanup 仅在发布成功后执行。
10. 文档状态更新为 Linux 6.18 双平台 CI/Release 已验收，并附实际 Action 与 Release 证据。

## 19. 维护规则与风险

- 更新 package 或功能时，只修改对应 profile 声明；不在 workflow/checker 增加设备分支。
- 新动态上游必须进入 resolver 与 source lock；不能把 `latest/download` 直接交给 package build。
- 新兼容规则必须有当前 profile 构建失败证据、稳定语义锚点和 fixture。
- 上游已包含等价实现时，兼容执行器应 no-op；出现半实现或漂移时失败。
- Linux upstream 的 longterm 身份不等于 Lean target 已将其设为 stable；selected channel 以锁定 Lean metadata 为准。
- testing channel 前进且没有可信 BBRv3/target/package 适配时允许构建失败，不允许静默降级或发布半兼容固件。
- 不因为 sbwml 或 kernel.org 出现更新 point release 就越过 Lean 单独改 version/hash；不引入私有 target、授权凭据或远程覆盖脚本。
- R4S 2.208/1.8 GHz 是 selected Lean target 的显式超频风险；项目不在其上继续增加电压或频率。N5105 固定使用 `x86-64-v2` + Tremont tune，不引入严格 Tremont 或 x86-64-v3 候选。
- R4S IRQ/RPS/XPS 与 N5105 queues/irqbalance 各只有一个 production 所有者，不积累开关和 fallback。
- MPTCP 当前明确关闭；Lean master 默认变化不得把未拥有的内核功能重新带入最终 config。
- `actions/*@main`、Lean master 和 feeds master 都会带来上游行为变化；本项目选择直接跟踪最新，因此依靠四层交付门禁阻止不兼容结果发布。
- source-lock schema 5 是 6.18 架构目标内部接口；迁移时同步升级所有消费者、fixture 和本文，不保留 schema 4 兼容分支。

## 20. 上游致谢

- `coolsnowwolf/lede`
- `sbwml/builder`
- `sbwml/r4s_build_script`
- `openwrt/openwrt`
- `openwrt/packages`
- `Openwrt-Passwall/*`
- `sbwml/luci-app-mosdns`
- `Loyalsoldier/geoip`
- `Loyalsoldier/v2ray-rules-dat`
- `google/bbr`
- `CachyOS/kernel-patches`

### 20.1 2026-08-02 上游审计记录

以下只记录本次方案依据，不参与构建解析；production 始终由 source-lock 重新锁定：

- Lean `f9dcc54b24e3f7fc7e8cd6db05f9e545eff67486`：[Rockchip](https://github.com/coolsnowwolf/lede/blob/f9dcc54b24e3f7fc7e8cd6db05f9e545eff67486/target/linux/rockchip/Makefile) 与 [x86](https://github.com/coolsnowwolf/lede/blob/f9dcc54b24e3f7fc7e8cd6db05f9e545eff67486/target/linux/x86/Makefile) 均声明 stable 6.12、testing 6.18；[`include/kernel-6.18`](https://github.com/coolsnowwolf/lede/blob/f9dcc54b24e3f7fc7e8cd6db05f9e545eff67486/include/kernel-6.18) 为 6.18.38。
- `sbwml/r4s_build_script@565ec5f5c880ac3b2402c2f32c449dbf96084118`：公开 [6.18 BBRv3 20-patch port](https://github.com/sbwml/r4s_build_script/tree/565ec5f5c880ac3b2402c2f32c449dbf96084118/openwrt/patch/kernel-6.18/bbr3)、6.18.40 metadata、R4S/PVE 优化意图，以及 [不可纳入的私有 target 替换路径](https://github.com/sbwml/r4s_build_script/blob/565ec5f5c880ac3b2402c2f32c449dbf96084118/openwrt/scripts/01-prepare_base-mainline.sh)。
- [`sbwml/builder@71a27b5a5244f6b509d048cdb6eb93ccb976cb8d`](https://github.com/sbwml/builder/blob/71a27b5a5244f6b509d048cdb6eb93ccb976cb8d/README.md)：GCC16、O3/LTO、Clang ThinLTO、LRNG/BPF/DPDK 和宽 package 集仅作为实验目录，不改变本项目 GCC15/精简生产决策。
- [kernel.org](https://www.kernel.org/category/releases.html)：Linux 6.18 是预计维护到 2028-12 的 longterm；与 Lean 的 testing/stable channel 身份分开判断。
- [Intel N5105](https://www.intel.com/content/www/us/en/products/sku/212328/intel-celeron-processor-n5105-4m-cache-up-to-2-90-ghz/specifications.html)、[Jasper Lake 数据手册](https://edc.intel.com/content/www/us/en/design/ipla/software-development-platforms/servers/platforms/intel-pentium-silver-and-intel-celeron-processors-datasheet-volume-1-of-2/001/features-supported_1/) 与 [GCC x86 options](https://gcc.gnu.org/onlinedocs/gcc-16.1.0/gcc/x86-Options.html)：N5105 是 Jasper Lake/Tremont，production 固定使用 `x86-64-v2` + Tremont tune，不使用严格 Tremont 或需要 AVX/AVX2 的 `x86-64-v3`。
- [Linux v6.18.38 upstream igc](https://github.com/gregkh/linux/blob/v6.18.38/drivers/net/ethernet/intel/igc/igc_main.c#L7238-L7242) 已包含 VLAN tag insertion/stripping 默认语义，证明语义合同必须支持 backport/upstream 二选一。
