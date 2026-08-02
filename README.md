# Actions-OpenWrt

这个仓库从 Lean `master` 构建两套共享同一源码锁的精简路由固件：

- NanoPi R4S：RK3399、原生 Lean 启动链与网口 IRQ 策略、ARMv8 CRC/crypto、R8168、PWM fan、512 MiB LZ4 zram。
- N5105 PVE：`x86-64-v2 + mtune=tremont`、squashfs combined EFI、VirtIO NET/SCSI、I225/igc 直通、4 队列与 irqbalance。

两者共用 firewall3/iptables、用户明确固定的 GCC 15、精简应用 allowlist、Lean testing kernel channel 和按所选内核系列动态解析的 BBRv3。仓库不写死 Linux point release：每轮从同一份 Lean master 分别解析目标的 channel/series/version/source hash，当前 R4S 与 x86 都选择 Linux 6.18。当前配置实际使用的通用 package 统一来自每轮锁定的 `openwrt/packages@master`；GMP、PCRE2、MTD 以及 Lean 缺失的官方 CycloneDX image generator 从同一轮锁定的 OpenWrt 官方 core 窄同步。`libsepol`、旧 `wol` CLI、current `small/tcping`、R4S ZRAM backend guard 和共享 image manifest 只保留经真实构建证明必要的窄语义兼容；系列相关规则只消费本轮 source-lock 的 selected kernel，不固定 point release，不降低全局编译器，也不覆盖整份 Lean 核心文件。完整设计、取舍依据和验收规范见 [docs/build-architecture.md](docs/build-architecture.md)。

## 构建模型

一次 `all` 构建遵循同一条事务链：

```text
解析 Lean/feeds/最新稳定产物 -> source-lock.json
                              -> R4S 完整构建与验证
                              -> N5105 完整构建与验证
                              -> 聚合为 draft Release
                              -> 重新下载全部资产并验 SHA/契约
                              -> 公开同一个 Release
                              -> 成功后保留最近 6 个生产 Release
```

`prepare` 只解析一次所有浮动输入。两个 build job 随后只使用完整 Git commit、精确 release URL 和 64 位 SHA256，不读取 branch HEAD、GitHub `latest/download`，也不接受 `PKG_HASH:=skip`。正式路径固定为 source lock、最终 config、固件交付、Release 回下载四层门禁；失败只保留诊断 artifact 或 draft，不公开半套固件，也不清理已有生产版本。

## 使用方法

1. 在 GitHub Actions 中选择 `OpenWrt Builder`。
2. 点击 `Run workflow`。
3. 任意分支选择 `profile=all` 都会构建两个平台并发布正式 Release；`r4s` 或 `x86-n5105-pve` 只构建对应 Actions artifact。
4. 通常把四个版本输入留空，resolver 会选择：
   - 仍受支持的最高 HAProxy LTS 分支最新 patch release；
   - 最新 AdGuardHome stable；
   - `Loyalsoldier/geoip` 的最新 `geoip.dat` 和 `Loyalsoldier/v2ray-rules-dat` 的最新 `geosite.dat`。
5. 需要故障回滚时才填写精确 `haproxy_version`、`adguardhome_version`、`geoip_tag` 或 `geosite_tag`；resolver 仍会获取并验证真实 hash。

默认分支发布使用 GitHub 内置 token。当非默认分支相对默认分支修改了 workflow，GitHub API 要求一个同时具有仓库与 workflow 写权限的凭据；workflow 只在 Release jobs 中使用仓库已配置的 `ACTIONS_TRIGGER_PAT`。

定时 `Update Checker` 使用同一个 resolver。Lean、任一 feed、四类上游产物、profile 或 patch digest 变化时，它会把已经解析好的完整 source lock 交给一次双平台构建，避免 update checker 与 builder 各自维护一套版本查询逻辑。

## Profile 如何维护

仓库只有三层配置名，不保留旧 `x86` 别名：

```text
profiles/common/             两个平台共享的包、工具链、契约和 rootfs overlay
profiles/r4s/                R4S target、CPU flags、硬件包和运行时设置
profiles/x86-n5105-pve/      N5105 PVE target、CPU flags、硬件包和运行时设置
```

- 共享/设备必选包与值为 `y` 的公开 Kconfig 只写入对应 `required-packages.txt`，renderer 自动生成正选择；不在 `config.seed` 再抄一份。
- target、镜像布局、CPU flags、数值/字符串和不能由 package 清单表达的功能选项写入 common 或设备 `config.seed`；renderer 会拒绝与派生 symbol 重复所有权。
- 不允许进入 manifest 的包只写入 `forbidden-packages.txt`；其中 `exact:` 规则自动成为 Kconfig 负选择。首次 `make defconfig` 后还会统一清理已禁父包遗留的 `CONFIG_PACKAGE_<parent>_*` 正选择，再次 defconfig 并复验；普通精简不删除源码。
- rootfs 文件放在对应 `files/`。common 与设备层同路径会直接失败，不允许静默覆盖。
- 同一 Kconfig symbol 或 required/forbidden 规则不能同时归 common 与设备层所有。
- 稳定行为语义与其所有者放在同一目录的 `semantics.json`：common 只影响共享意图，设备文件只影响对应 profile。规则使用动态 `{kernel_series}`/`{kernel_version}` 与语义 glob，不保存某轮 kernel 版本、commit、hash 或 patch 文件名；静态检查验证 rootfs，`target/linux/prepare` 后再验证本轮锁定 Lean tree、feeds 和已经应用 patch 的 kernel source。backport 消失但同等能力已经进入 upstream source 时，可以由同一条 alternatives 合同证明。
- `scripts/profile_model.py` 是 profile 发现、common/device 合并、env、正负 Kconfig 派生和最终 package 集合判定的唯一实现；`render-profile.sh` 与 `check-profile-contract.sh` 只是薄 CLI。workflow、update checker 与测试都从 profile 目录自动发现集合，没有 R4S/N5105、包名、CPU flags 或网络值分支。

`profiles/common/providers.tsv` 是当前产品重复 package provider 的唯一合同。HAProxy 来自官方 packages；PassWall app 来自 canonical `passwall` feed；MosDNS app/core 来自 `sbwml`；SmartDNS 与 AdGuardHome 来自 `kenzo`；PassWall 依赖按合同在 `xiaorouji` 与 `small` 中唯一选择。真实冲突目录会被精确移除，随后从 source-lock 枚举并重建全部 feed 索引。Geo 数据角色与来源映射只定义在 `profiles/common/geodata-sources.json`：`v2ray-geodata` 同时产出 `v2ray-geoip` 与 `v2ray-geosite`，resolver、validator 和 applicator 共用该合同，把两个 download block 改写成 Loyalsoldier 载荷的当轮精确 tag、URL 与 SHA256。

feed 索引覆盖全部锁定源，但安装阶段只提交当前 profile 的 required package，并由 OpenWrt feeds installer 递归展开 source/build/runtime dependency。未使用应用不会进入 Kconfig，也不会因为它们自身陈旧而扩大维护范围。

自定义 Feed 统一从 `feeds.custom.conf` 解析并在每轮冻结 commit。同名 `packages` 条目明确覆盖 Lean 默认 packages 为 OpenWrt 官方 master；`small`、`kenzo`、`sbwml` 使用用户指定上游，PassWall 使用 canonical `Openwrt-Passwall` 组织。配置中的 `main`/`master`/默认分支是浮动跟踪策略，不是永久版本锁；incoming source-lock 必须逐项匹配这些静态身份。

## 固件内容与边界

共同应用包括 LuCI、PassWall（Xray/Hysteria/HAProxy/geodata）、MosDNS、SmartDNS、AdGuardHome、ddns-go、nlbwmon、ARP 绑定、自动重启、内存释放、ttyd、TurboACC、iptables UPnP、WOL、CoreMark、htop、lsof 和 SFTP server。

明确排除 default-settings、Docker、Samba、旧 DDNS scripts、VLMCS、VSFTP、OpenList、qBittorrent、ZeroTier、HomeProxy、Nikki、Mihomo、SSR Plus、firewall4/nftables、natflow、SFE 和第二套 BBR package provider 等不在需求内的组件。

固件只拥有安全、可解释的出厂默认：

- LAN `192.168.2.1/24`，DHCP 从 `.32` 开始、`limit=232`、租期 12 小时；WAN DHCP、WAN6 DHCPv6；LAN DHCPv6/NDP 使用 relay，WAN 为 relay master；不写死物理 `ethX`。
- `Asia/Shanghai` 和启用 NTP client，保留上游 NTP server 列表。
- `fq`、16 MiB socket buffer 上限。
- 只有确认 `/sys/module/tcp_bbr/version=3`、`sch_fq` 存在且 TurboACC 已探测到 software flow offload 后，才一次性把 factory CCA 设为 `bbr`；以后尊重用户在 TurboACC 中的选择。
- 不内置固定 root 密码、不关闭签名校验、不添加私有软件源、不开放 WAN 管理入口。

AdGuardHome、MosDNS、SmartDNS、dnsmasq-full 和 PassWall 都会被编译，但 DNS 端口、上游、缓存、规则、节点、订阅和凭据是用户常用的设备运行时配置，不烘焙进两台设备共用的镜像。它们应按设备实际 UCI/YAML、socket、iptables redirect 和完整查询链验收。

BBRv3 同时适用于本机 IPv4 TCP 与 IPv6 TCP。Linux 的 IPv6 TCP socket 同样进入通用 `tcp_init_sock()` 和 `tcp_congestion_ops`，所以源码位于 `net/ipv4/tcp_bbr.c` 不代表“只支持 IPv4”。它不接管 UDP/QUIC，也不会改变普通 NAT 转发连接在 LAN 客户端/远端服务器上的端到端拥塞控制；PassWall/Xray 在路由器本机建立的 TCP outbound 才会直接使用它。

Lean 会通过 `CONFIG_MODULE_STRIPPED` 剥离普通 `MODULE_VERSION`。构建保留这项全局体积优化，只在本轮 BBRv3 provider 仍使用该宏时自动安装一个单行 companion，以 direct `MODULE_INFO` 保留 BBRv3 的 `version=3`；若上游已经处理则自动跳过。随后对构建树中每一份 `tcp_bbr.ko` 直接读取 `.modinfo`，不会仅凭源码文本判定成功。

## N5105 PVE 前置条件

推荐 VM 合同：

```text
machine: q35
bios: ovmf
cpu: host
sockets: 1
cores: 4
balloon: 0
disk: VirtIO SCSI single + iothread + discard
LAN: 一个 VirtIO NIC，multiqueue=4
WAN: 一个 I225/igc PCIe passthrough
serial0: socket
```

首次启动脚本按 `ethtool -i` 识别唯一 `virtio_net=LAN`、唯一 `igc=WAN`，把两侧设为 4 combined queues 后关闭 packet steering。缺接口、重复接口或任何一侧无法达到 4 队列时脚本保留并在下次启动重试，不用 RPS fallback 掩盖错误的 PVE 配置。

该固件要求 x86-64-v2；正式 guest 应确认 SSE3、SSSE3、SSE4.1、SSE4.2、POPCNT 和 CMPXCHG16B。`cpu: host` 还应暴露 AES/PCLMUL/SHA，供 OpenSSL runtime dispatch 使用。

## 本地验证

仓库静态与 fixture 测试：

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
```

真实 resolver（会访问上游并下载受控 release 做 hash 验证）：

```sh
profiles="$(bash scripts/render-profile.sh list | paste -sd, -)"
bash scripts/resolve-source-lock.sh resolve \
  "$profiles" /tmp/source-input/source-lock.json
bash scripts/resolve-source-lock.sh materialize \
  /tmp/source-input/source-lock.json /tmp/source-input
bash scripts/resolve-source-lock.sh digest /tmp/source-input/source-lock.json
```

GitHub build 还会执行两次 `make defconfig` 及 forbidden 子选项收敛、一次最终 required/forbidden/provider/seed/source contract、完整 `make download`、一次并行编译、直接读取全部 `tcp_bbr.ko` ELF `.modinfo` 并验证 version 3/vermagic、一致的 `sch_fq.ko`、GCC 15、镜像 gzip payload 与可选 OpenWrt fwtool metadata/signature trailer、manifest、buildinfo、SBOM 和所有 SHA256 验证。

## 产物与迁移说明

每个平台 artifact 包含固件、原始 manifest/buildinfo/SBOM、规范化的 `openwrt-sha256sums`、source lock、最终 `.config`、单一 `build-provenance.json` 和覆盖整个目录的 `SHA256SUMS`。不再保留只有大小写区别、会使 Windows 解压冲突的文件名。

正式 Release 只展示两个可直接刷写的专业命名镜像、每平台一个 `-full.tar.gz` 完整包，以及 `release-index.json`、`source-lock.json` 和顶层 `SHA256SUMS`。完整包保留全部 provenance 和原始产物；发布前会从 GitHub 回下载并重建两套交付目录，证明直接镜像与包内原件一致后复用同一 verifier。

Breaking changes：

- `profiles/x86` 和 workflow 输入 `x86` 已改名为 `x86-n5105-pve`，没有兼容别名。
- workflow 的 `profile` 输入由静态下拉框改为字符串：填 `all` 或任一 `profiles/<device>` 目录名；matrix、update checker、静态检查和 Release 聚合均自动发现目录，不再维护第二份 profile 名单。
- source lock 当前为 schema 5，profile 内完整记录 selected kernel channel/target/series/version/source hash；Action 执行身份不属于 source lock，feeds/source overlays/kernel/BBRv3 等消费者统一通过 `source_lock.py` 解释。其他 schema 的 incoming lock 需重新运行 resolver，设备配置与 sysupgrade 行为不受影响。
- 生产 profile 共同选择 Lean testing channel，但不永久写死 6.18 或任一 point release；`patchsets/common/kernel/bbr3-sources.json` 只保存 provider 策略，每轮自动解析与目标 series 匹配的最新可信 BBRv3 port、物化并锁定 commit/hash。缺少兼容 port 时构建明确失败，不静默降级。
- GitHub 官方复用 Actions 直接使用 `actions/*@main`，按用户选择追踪最新默认分支；任何上游 runtime/行为不兼容会使门禁直接失败。
- `diy-part2.sh` 不再做可变 release 查询、`sed` 服务策略或 `PKG_HASH:=skip`；它只应用 source lock 中已经验证的 metadata。
- 正式 Release 必须由同一 source lock 下两台设备同时通过；任意分支的 `all` 都发布，单 profile 仅提供 Actions artifact。

## Credits

- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [sbwml/builder](https://github.com/sbwml/builder)
- [sbwml/r4s_build_script](https://github.com/sbwml/r4s_build_script)
- [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches)
- [google/bbr](https://github.com/google/bbr)

## License

[MIT](LICENSE)
