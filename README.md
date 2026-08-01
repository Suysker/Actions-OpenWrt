# Actions-OpenWrt

这个仓库从 Lean `master` 构建两套共享同一源码锁的精简路由固件：

- NanoPi R4S：RK3399、原生 Lean 启动链与网口 IRQ 策略、ARMv8 CRC/crypto、R8168、PWM fan、512 MiB LZ4 zram。
- N5105 PVE：`x86-64-v2 + mtune=tremont`、squashfs combined EFI、VirtIO NET/SCSI、I225/igc 直通、4 队列与 irqbalance。

两者共用 firewall3/iptables、用户明确固定的 GCC 15、精简应用 allowlist、稳定 target kernel 和按内核系列动态解析的 BBRv3。Lean master 的 `libsepol` 仅在该包内保持 GNU17 兼容语义，不降低全局编译器；`nlbwmon` 与 Go 从同一份当轮锁定的官方 `openwrt/packages` commit 同步，子树名单只在 common `profile.env` 声明一次。完整设计、取舍依据和验收规范见 [docs/build-architecture.md](docs/build-architecture.md)。

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

`prepare` 只解析一次所有浮动输入。两个 build job 随后只使用完整 Git commit、精确 release URL 和 64 位 SHA256，不读取 branch HEAD、GitHub `latest/download`，也不接受 `PKG_HASH:=skip`。失败只保留诊断 artifact 或 draft，不公开半套固件，也不清理已有生产版本。

## 使用方法

1. 在 GitHub Actions 中选择 `OpenWrt Builder`。
2. 点击 `Run workflow`。
3. 正式发布选择 `profile=all`；`r4s` 或 `x86-n5105-pve` 只构建可下载 artifact，不创建 Release。
4. 通常把四个版本输入留空，resolver 会选择：
   - 仍受支持的最高 HAProxy LTS 分支最新 patch release；
   - 最新 AdGuardHome stable；
   - `Loyalsoldier/geoip` 的最新 `geoip.dat` 和 `Loyalsoldier/v2ray-rules-dat` 的最新 `geosite.dat`。
5. 需要故障回滚时才填写精确 `haproxy_version`、`adguardhome_version`、`geoip_tag` 或 `geosite_tag`；resolver 仍会获取并验证真实 hash。

定时 `Update Checker` 使用同一个 resolver。Lean、任一 feed、四类上游产物、profile 或 patch digest 变化时，它会把已经解析好的完整 source lock 交给一次双平台构建，避免 update checker 与 builder 各自维护一套版本查询逻辑。

## Profile 如何维护

仓库只有三层配置名，不保留旧 `x86` 别名：

```text
profiles/common/             两个平台共享的包、工具链、契约和 rootfs overlay
profiles/r4s/                R4S target、CPU flags、硬件包和运行时设置
profiles/x86-n5105-pve/      N5105 PVE target、CPU flags、硬件包和运行时设置
```

- 共享应用只修改 `profiles/common/config.seed`。
- 设备 target、镜像、CPU flags、驱动和设备调优只修改对应设备的 `config.seed`。
- 每个必需包或 Kconfig 进入 `required-packages.txt`。
- 不允许进入 manifest 的包写入 `forbidden-packages.txt`；其中 `exact:` 规则会自动成为 Kconfig 负选择，并在 `make defconfig` 后及最终 manifest 再次校验，普通精简不删除源码。
- rootfs 文件放在对应 `files/`。common 与设备层同路径会直接失败，不允许静默覆盖。
- 同一 Kconfig symbol 或 required/forbidden 规则不能同时归 common 与设备层所有。
- `profiles/optimization-contracts.json` 是运行时调优及 Lean 继承优化的唯一语义合同。它使用动态 `{kernel_series}` 和 patch 目录 glob，不保存某轮 kernel 版本、commit、hash 或 patch 文件名；静态检查验证 rootfs，构建检查再验证本轮锁定 Lean tree/feeds。它进入两套 profile digest，修改共同性能意图会同时改变两个 profile digest；完整 source-lock 仍独立包含仓库 commit。

`profiles/common/providers.tsv` 是关键 package provider 的唯一合同。当前明确选择默认 packages feed 的 HAProxy、kenzo 的 AdGuardHome、xiaorouji 的 `v2ray-geodata` 和 Lean LuCI 的 TurboACC；真实冲突 provider 会在 feed checkout 后被精确移除并重新索引。Geo 数据角色与来源映射则只定义在 `profiles/common/geodata-sources.json`：`v2ray-geodata` 是同时产出 `v2ray-geoip` 与 `v2ray-geosite` 的 package recipe，不是第三份规则数据；resolver、validator 和 applicator 共用该合同，把两个 download block 改写成对应 Loyalsoldier 载荷的当轮精确 tag、URL 与 SHA256，执行代码不再各自枚举仓库和字段。

自定义 Feed 统一从 `feeds.custom.conf` 解析并在每轮冻结 commit。`small`、`kenzo`、`sbwml` 使用用户指定的上游；PassWall 使用旧 `xiaorouji` 地址当前指向的 canonical `Openwrt-Passwall` 组织，避免依赖重定向或已不存在的旧仓库。配置中的 `main`/默认分支是浮动跟踪策略，不是永久版本锁。

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
bash -n diy-part1.sh diy-part2.sh scripts/*.sh profiles/*/files/etc/uci-defaults/*
python3 -m py_compile scripts/*.py
bash tests/test-profile-renderer.sh
python3 tests/test-optimization-contract.py
bash tests/test-resolve-source-lock.sh
bash tests/test-apply-source-lock-artifacts.sh
bash tests/test-apply-profile-patches.sh
bash tests/test-locked-feeds.sh
bash tests/test-sync-official-packages.sh
bash scripts/check-profile-contract.sh r4s
bash scripts/check-profile-contract.sh x86-n5105-pve
```

真实 resolver（会访问上游并下载受控 release 做 hash 验证）：

```sh
bash scripts/resolve-source-lock.sh resolve \
  'r4s,x86-n5105-pve' /tmp/source-input/source-lock.json
bash scripts/resolve-source-lock.sh materialize \
  /tmp/source-input/source-lock.json /tmp/source-input
bash scripts/resolve-source-lock.sh digest /tmp/source-input/source-lock.json
```

GitHub build 还会执行 `make defconfig`、required/forbidden/provider 契约、锁定源码的优化语义合同、定向下载、完整 `make download`、一次并行编译、实际 `tcp_bbr.ko` module version 3、`sch_fq.ko`、GCC 15、镜像 gzip、manifest、buildinfo、SBOM 和所有 SHA256 验证。

## 产物与迁移说明

每个平台 artifact 包含固件、原始 manifest/buildinfo/SBOM/sha256sums，以及 source lock、物化的 BBRv3 patch archive、artifact override、patch、module、runner、toolchain 和构建 provenance。生产 Release 的通用文件统一加 profile 前缀，并由 `delivery-index.json` 映射回原名；Release 发布前会据此重建两套 artifact 并再次运行同一 verifier。

Breaking changes：

- `profiles/x86` 和 workflow 输入 `x86` 已改名为 `x86-n5105-pve`，没有兼容别名。
- 生产 profile 跟随 Lean target 稳定内核；`patchsets/common/kernel/bbr3-sources.json` 只保存 provider 策略，每轮自动解析最新兼容 BBRv3 port、物化并锁定 commit/hash。
- GitHub 官方复用 Actions 直接使用 `actions/*@main`，按用户选择追踪最新默认分支；任何上游 runtime/行为不兼容会使门禁直接失败。
- `diy-part2.sh` 不再做可变 release 查询、`sed` 服务策略或 `PKG_HASH:=skip`；它只应用 source lock 中已经验证的 metadata。
- 正式 Release 必须由同一 source lock 下两台设备同时通过；单 profile 仅提供 Actions artifact。

## Credits

- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [sbwml/builder](https://github.com/sbwml/builder)
- [sbwml/r4s_build_script](https://github.com/sbwml/r4s_build_script)
- [CachyOS/kernel-patches](https://github.com/CachyOS/kernel-patches)
- [google/bbr](https://github.com/google/bbr)

## License

[MIT](LICENSE)
