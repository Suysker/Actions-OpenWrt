# R4S 与 N5105 OpenWrt 构建架构

## 1. 文档状态

- 状态：设计修订 3，实施与验收中
- 日期：2026-08-02
- 源码基线：Lean `master`
- 防火墙：firewall3 / iptables
- 工具链：Lean 原生 GCC 15
- 目标设备：NanoPi R4S、N5105 PVE
- 正式交付：同一次 source lock 下的双平台固件与一个经回下载复验的 Release

本文描述仓库当前应有的稳定架构。构建是否完成，以第 15 节的本地门禁和一次新的 GitHub Actions `profile=all` 完整事务为准。

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
- BBRv3 是内核能力，运行时名称保持 `bbr`，package 名保持 Lean 的 `kmod-tcp-bbr`。
- GitHub 官方 Actions 使用 `actions/*@main`，每次运行直接使用其最新默认分支。
- HAProxy LTS、AdGuardHome stable、GeoIP、Geosite、feeds、BBRv3 port 都按“每轮解析最新、轮内冻结”处理。
- DNS 端口、上游、缓存、节点、订阅和凭据属于用户常用的运行时配置，不进入跨设备固件默认。

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
| 自定义 feeds | `feeds.custom.conf` |
| package provider | `profiles/common/providers.tsv` |
| Geo 数据角色与可信来源 | `profiles/common/geodata-sources.json` |
| 官方源码窄同步 | `profiles/common/source-overlays.json` |
| 源码兼容规则 | `profiles/common/source-compatibility.json` |
| BBRv3 provider 策略 | `patchsets/common/kernel/bbr3-sources.json` |
| BBRv3 module version 兼容 | `patchsets/common/kernel/bbr3-module-version.json` |
| 当轮动态版本、commit、hash | 运行时生成的 `source-lock.json` |

文档、workflow 和测试只引用这些声明，不复制设备名、包清单、版本或 hash。

## 4. 总体数据流

```text
repository declarations + floating upstreams
  -> source_lock.py resolve/validate/materialize
  -> one immutable source-lock artifact
  -> render common + device profile
  -> locked Lean + feeds + source overlays
  -> apply controlled metadata and narrow compatibility
  -> defconfig -> normalize exact-forbidden children -> defconfig
  -> one final profile contract
  -> make download -> make world
  -> collect one build-provenance.json
  -> verify one profile delivery
  -> release_assets.py verifies and assembles both profiles
  -> draft Release upload
  -> download every asset -> reconstruct both deliveries -> verify again
  -> publish the same draft -> retain six verified production Releases
```

正式路径只有四层门禁：

1. `resolve-lock`：解析和冻结所有浮动输入。
2. `check-final-config`：验证最终 `.config`、package、provider、target、kernel 和源码语义。
3. `verify-firmware`：验证真实固件、manifest、SBOM、模块、工具链、provenance 和 hash。
4. `verify-release`：从 draft Release 回下载，重建每个平台目录并复用同一个固件 verifier。

## 5. 模块划分与依赖关系

### 5.1 模块职责

| 模块 | 职责 |
|---|---|
| `scripts/source_lock.py` | 上游解析、schema 校验、digest、BBRv3 物化、feeds 与 source overlay 投影 |
| `scripts/profile_model.py` | profile 发现、common/device 合并、Kconfig 派生、package 合同计算 |
| `scripts/profile_contract.py` | 最终 config、seed drift、package、provider、target、kernel、rootfs/source 语义验收 |
| `scripts/apply_source_lock_artifacts.py` | 把 lock 中的精确 release metadata 写入唯一 package provider |
| `scripts/apply-profile-patches.sh` | 应用仓库 patch、源码兼容规则和本轮 BBRv3 patch stack |
| `scripts/collect-build-provenance.sh` | 从真实 build tree 生成平台交付目录和 `build-provenance.json` |
| `scripts/verify-firmware-artifacts.sh` | 平台交付的唯一验收器 |
| `scripts/release_assets.py` | 双平台聚合、资产命名、delivery index、回下载重建和复验 |
| `.github/workflows/openwrt-builder.yml` | 编排四层门禁，不解释领域 schema |
| `.github/workflows/update-checker.yml` | 定时调用同一个 resolver；source digest 变化时派发双平台构建 |

### 5.2 复用接口

- shell 只编排进程与文件，JSON/schema 解释由 Python 模块拥有。
- `render-profile.sh`、`check-profile-contract.sh`、`resolve-source-lock.sh`、`assemble-release.sh` 和 `verify-release-assets.sh` 都是薄 CLI。
- build、aggregate 和 release-download 三个边界复用 `verify-firmware-artifacts.sh`。
- 失败日志属于 diagnostics；正式资产只保留可复核交付及一个结构化 provenance。

### 5.3 命名与风格

- profile 与文件名使用 kebab-case，例如 `x86-n5105-pve`。
- JSON 字段与 Python 标识符使用 snake_case。
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
- Lean 本轮 target stable kernel
- 与该 kernel series 匹配的最新受信任 BBRv3 port

resolver 随即把 commit、精确 URL 和 SHA256 写入同一个 schema 4 lock。两个 build job 只消费该 lock，不在构建中再次查询 `latest` 或 branch HEAD。

这意味着：

- 仓库不永久钉死普通上游版本/hash。
- 同一轮 R4S 与 N5105 不会解析到不同版本。
- Release 中的 lock 能解释固件实际使用了什么。
- 新上游若与当前 Lean 不兼容，构建明确失败，不静默回退。

### 6.2 schema 4 内容

顶层字段固定为：

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

GitHub Actions 不写入 source lock。Action 在 workflow 开始时已由 GitHub 解析，运行中查询其 HEAD 不能证明已执行的字节。仓库只约束复用 Action 必须是官方 `actions/*@main`；最新行为由 GitHub 在每次运行时直接解析。

### 6.3 hash 策略

- release asset 必须有真实 SHA256。
- Geo 数据同时校验发布方 checksum 资产。
- BBRv3 patch 下载后计算 hash，并对精确 Linux version clean-apply。
- package metadata 不允许 `PKG_HASH:=skip` 或 `releases/latest/download`。
- `make download -j8` 是 OpenWrt 全部 source 的统一 hash 门禁。

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

首次 `make defconfig` 后，normalizer 只处理 exact-forbidden 父应用遗留的已选子项；第二次 `defconfig` 后，`profile_contract.py` 一次性验证：

- rendered seed 的正选择未消失或变值；负选择未被重新选中。
- required/forbidden package 和 config。
- package provider 唯一性。
- target 与 image pattern。
- Lean stable kernel series 与 source lock。
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

dnsmasq-full、AdGuardHome、MosDNS、SmartDNS 和 PassWall 可以同时安装，但实际设备必须用 UCI/YAML、socket、iptables redirect 和查询链共同验证不存在端口冲突、WAN 暴露或环路。

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
- packet steering 开启，不再叠加通用 irqbalance 作为第二所有者。
- 移除该路由器不需要的 Rockchip DRM/GPU 选择。

R4S 验收关注 target 源码的真实语义，不永久绑定某个 kernel patch 文件名。

## 12. N5105 PVE 专属优化

N5105 profile 面向固定虚拟化合同：

- x86_64 generic、squashfs combined EFI gzip image。
- `-O2 -pipe -march=x86-64-v2 -mtune=tremont`。
- VirtIO NET/SCSI 使用 Lean x86_64 kernel built-in。
- WAN 使用 I225/igc PCIe passthrough。
- 唯一 `virtio_net` 识别为 LAN，唯一 `igc` 识别为 WAN。
- 两侧都设置为 4 combined queues，启用 irqbalance，关闭 RPS/packet steering。
- 接口缺失、重复或不能达到 4 队列时保留首次启动脚本并重试，不猜测接口角色。
- 验证 I225 EEE disable 与 igc VLAN offload 语义仍在本轮 Lean stable kernel patch stack。
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

## 13. BBRv3 合同

BBRv3 不能作为与内核无关的普通 kmod 下载。正确路径是：

1. 从 Lean target 解析 stable kernel 的精确 version 与 source hash。
2. 从受信任 provider 策略解析匹配 series 的最新 BBRv3 port。
3. 下载 patch，计算 SHA256，并对精确 pristine Linux tag clean-apply。
4. 把当轮 patch 物化到 source-lock artifact。
5. 安装进 Lean 对应 `hack-*`/`backport-*` patch stack。
6. 继续使用 Lean `kmod-tcp-bbr`、`tcp_bbr.ko` 和运行名 `bbr`，保持 TurboACC 依赖关系。
7. 从 build tree 的每一份 `tcp_bbr.ko` ELF `.modinfo` 读取 `version=3` 和 vermagic。
8. 同时验证 `sch_fq.ko` 与同一 locked kernel vermagic。

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

## 15. GitHub Actions 事务

### 15.1 prepare / resolve-lock

- 从 profile 目录自动发现目标。
- 解析或接收一个完整 source lock。
- incoming lock 必须属于当前 repository commit 且 digest 与 dispatch metadata 一致。
- 物化 BBRv3 patch，并对每个目标 kernel version clean-apply。
- 上传一个 `source-lock` artifact 供两个 build job 共用。

### 15.2 build / check-final-config / verify-firmware

每个平台：

1. checkout locked Lean commit。
2. 使用 locked feeds 与 source overlays。
3. 选择唯一 package providers，并只安装 required package 闭包。
4. 应用受控 release metadata、源码兼容和 BBRv3 patch。
5. 渲染 profile rootfs 与 config。
6. 两次 `make defconfig`，中间收敛 exact-forbidden 子选项。
7. 执行一次最终 profile contract。
8. `make download -j8`。
9. 一次并行 `make world`；失败时仅对首个安全 package target 收集 `-j1 V=sc` 诊断。
10. 收集并验证交付目录。

diagnostics 只在失败时上传。成功路径只上传 verified firmware artifact。

### 15.3 aggregate / verify-release / publish

- `release_assets.py assemble` 要求输入 profile 集合与 lock 完全一致。
- assembler 在复制前先对每个平台运行唯一 firmware verifier。
- 通用文件加 `<profile>--` 前缀，`delivery-index.json` 保存原名、资产名、大小和 SHA256。
- 创建 draft Release 后，从 GitHub 重新下载所有资产。
- verifier 校验顶层 SHA256、index 覆盖范围，重建两套原始目录并再次运行 firmware verifier。
- 全部通过后公开同一个 draft。
- 成功发布后只清理超出最近六个的已发布 `openwrt-*` Release。

任何 build、aggregate 或回下载失败都不会公开半套固件，也不会清理已有生产 Release。

## 16. 交付内容与 provenance

每个平台 delivery 包含：

- 固件 image。
- OpenWrt 生成的 manifest、config/version/feeds buildinfo、profiles.json、CycloneDX SBOM 和 `sha256sums`。
- 本轮 `source-lock.json`。
- 最终 `openwrt.config`。
- 单一 `build-provenance.json`。
- 覆盖交付目录全部文件的项目级 `SHA256SUMS`。

`build-provenance.json` 记录：

- profile、生成时间、source-lock digest、kernel version。
- 受控 artifact metadata 变换证据。
- patch/源码兼容/BBRv3 断言。
- runner 事实。
- GCC path、GCC 15 version、是否外部预编译工具链。
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

- source-lock resolve/validate/digest/materialize。
- feeds 与 source overlay 投影。
- profile common/device 合并和 seed drift。
- provider、artifact metadata 与源码兼容。
- BBRv3 module-version 状态机与 ELF metadata。
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

该步骤访问真实上游并验证受控 release 与 BBRv3 port。

### 17.3 真机验收

R4S：

- sysupgrade、overlay 与 reboot 正常。
- LAN/WAN 映射正确。
- 网口 IRQ 分别由 target 策略放到 CPU4/CPU5。
- zram 512 MiB、LZ4、swappiness 5。
- PWM fan、R8168、cpufreq 正常。

N5105 PVE：

- OVMF/EFI 启动和 sysupgrade 正常。
- VirtIO LAN 与 igc WAN 唯一识别。
- 两个接口均为 4 combined queues，irqbalance 生效，packet steering 关闭。
- I225 passthrough、VLAN 和 PPPoE 路径正常。

共同：

- `/sys/module/tcp_bbr/version` 为 `3`。
- `tcp_congestion_control=bbr`，默认 qdisc 为 `fq`。
- TurboACC software flow offload、iptables、PassWall 与 nlbwmon 行为一致。
- IPv4/IPv6、DHCPv6 relay、DNS 实际查询链、端口和 NAT redirect 正确。
- 必选 LuCI 页面、服务、升级保留配置和签名校验正常。

## 18. 完成条件

以下条件全部成立才算完成：

1. 本地全部现有测试、语法检查和两个静态 profile contract 通过。
2. source-lock 不包含永久动态版本、Action 伪执行身份或跳过 hash 的输入。
3. workflow 中不存在 package 专用下载硬编码、文件大小启发式或成功态 diagnostics。
4. R4S 与 N5105 在同一新 source lock 下都完成 `make world`。
5. 两个平台都通过最终 config、firmware、manifest、SBOM、GCC15、BBRv3/sch_fq 和 SHA256 验证。
6. aggregate 只接受 lock 声明的完整 profile 集合。
7. draft Release 的全部资产回下载后再次通过同一 verifier。
8. 同一 draft 成功公开，cleanup 仅在发布成功后执行。

## 19. 维护规则与风险

- 更新 package 或功能时，只修改对应 profile 声明；不在 workflow/checker 增加设备分支。
- 新动态上游必须进入 resolver 与 source lock；不能把 `latest/download` 直接交给 package build。
- 新兼容规则必须有当前 profile 构建失败证据、稳定语义锚点和 fixture。
- 上游已包含等价实现时，兼容执行器应 no-op；出现半实现或漂移时失败。
- 真机性能结论必须由可重复基准支持；配置和源码语义通过只证明优化已落地，不代表已有量化收益。
- `actions/*@main`、Lean master 和 feeds master 都会带来上游行为变化；本项目选择直接跟踪最新，因此依靠四层交付门禁阻止不兼容结果发布。
- source-lock schema 4 是当前内部接口；更改字段时同步升级 schema、消费者、fixture 和本文。

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
