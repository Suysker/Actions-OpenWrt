# Lessons

## OpenWrt 配置与构建架构

- 根因模式：feed 漂移后，虚拟 provider、内嵌翻译和历史包别名可能不再对应真实 Kconfig symbol。预防规则：所有 profile 必须经过 `make defconfig` 后的 seed drift、required 和 forbidden 三类校验；修正包契约，不放宽检查。
- 根因模式：失败后的 `!cancelled()` 发布/清理步骤会制造次生错误，甚至影响有效 Release。预防规则：构建、产物验证、发布和清理使用严格的成功依赖；只有新 Release 已创建并重新校验后才能清理旧版本。
- 架构规则：用户明确要求继续追踪 Lean `master`、保留 firewall3/iptables，并一次性交付 R4S 与 N5105 优化。后续不得在未获得新产品决策前改为官方稳定分支、firewall4/nftables 或分阶段上线。
- 可复现规则：追踪远程 master 或最新稳定 release 时，每次 workflow 启动只解析一次所有 ref/release，立即冻结完整 SHA、精确版本、不可变 URL 和 SHA256，随后双平台只消费同一 source-lock，并把解析结果随固件发布。“最新”是解析策略，不是跳过 hash 的理由。
- 优化规则：只纳入能由当前公开源码独立表达、能通过双 profile 构建和目标机验证的优化。私有 target、远程脚本、耦合内核补丁和无法量化收益的“优化”不进入生产路径。
- 设备调优规则：先审计 target/device 已有的 DTS、hotplug、UCI defaults 和驱动选择。R4S 已把两个网口 IRQ 分配给 CPU4/CPU5；通用 irqbalance 会产生第二个所有者并可能撤销设备优化，因此设备原生策略优先，重复调优必须删除。
- 配置包规则：`default-settings` 一类名称不能被视为无害基础包。选择前必须审读全部首次启动副作用；软件源、固定密码、签名、防火墙、OTA 和 steering 等跨域行为应拆成项目自己的窄 overlay，并把原整包加入 forbidden/manifest 契约。
- 上游移植规则：先比较当前基座，再判断“版本替换”是否真是升级。sbwml 的 boot chain 比当前 Lean 更旧，r8168 的小版本 bump也缺少当前问题证据；已有更新、依赖更完整的 native 实现应保留。
- Kconfig 规则：第三方 config 中看似合理的 symbol 也可能无效。当前 R4S zram 必须同时选择 `CONFIG_KERNEL_ZRAM_BACKEND_LZ4` 和 `CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4`；N5105 的 `CONFIG_VIRTIO_SUPPORT` 则是不可见的 target 内部 symbol，不能写进 seed，应该检查 x86 kernel config 中真实 built-in 的 `CONFIG_VIRTIO_NET`/`CONFIG_SCSI_VIRTIO`。所有优化 symbol 必须以当前 source-lock 执行 `make defconfig` 后证明仍然存在。
- LuCI 翻译规则：当前 LuCI 的 `luci-i18n-*-zh-cn` 是随应用生成的隐藏 package symbol，不能作为逐项 seed 输入；common 应选择公开的 `CONFIG_LUCI_LANG_zh_Hans=y`，再由 required manifest 和镜像清单验证实际翻译产物。遇到 seed drift 必须检查 symbol 的 prompt/default/dependency，不能把隐藏输出当作用户配置入口。
- 精简配置规则：forbidden 清单如果只做事后断言，Lean target 的默认包仍会先进入 `.config`。`exact:` package 必须由共享 renderer 自动生成 Kconfig 负选择，再依次通过 seed drift、forbidden config 和最终 manifest 门禁；regex 只能做集合断言，当前已知的 target 默认项还要有 exact 规则作为配置输入。不要在每个设备 seed 手抄同一批排除项。
- Kconfig 子选项规则：父 LuCI app 为 `n` 不代表其所有 `INCLUDE_*` symbol 都会自动变成 `n`；缺少父依赖的子选项仍可能通过 `select` 拉入被禁 package。诊断 forbidden 冲突时要从最终 `.config` 反查选择器，并把真正的泄漏 symbol 写入共享 seed 与静态合同，而不是放弃 package blacklist。
- CPU 规则：微架构名不等于具体 SKU 的完整 ISA 合约。N5105 可以用 `-mtune=tremont` 做调度优化，但整机 ISA 使用可验证的 `x86-64-v2`；设备启动前必须验证 `-march` 所要求的 CPU features。
- 网络队列规则：硬件/虚拟 multiqueue、RPS、手工 affinity 和 irqbalance 都会影响包落在哪个 CPU。每个平台只允许一套明确所有权：R4S 使用 native affinity + packet steering；N5105 使用 4 queues + irqbalance，并关闭 RPS。
- DNS 组合规则：安装 dnsmasq、AdGuardHome、MosDNS、SmartDNS 和 PassWall 时，运行时必须能解释唯一的 LAN `:53` 有效入口、完整转发图和各层缓存行为；不强制所有服务只监听 loopback，也不擅自把用户的多级缓存改成单一所有者，但必须证明没有端口争用、WAN 暴露和可触发的查询环路。
- DNS 诊断规则：配置文件里的 listener 不能单独证明真实流量路径。AdGuardHome 等 LuCI 集成可能通过 iptables PREROUTING redirect 保留 dnsmasq `:53`、同时把 LAN 查询送到另一端口；必须联合检查 UCI、服务 YAML、init/firewall 脚本、实际 socket 和 NAT 规则。
- 构建边界规则：固件负责包、provider、安全默认和兼容性 contract；用户常用 DNS 的端口、upstream、缓存、过滤规则、PassWall 节点/订阅及凭据属于可变运行时状态，只用于设备配置与验收，不进入跨设备镜像或仓库。
- 源码补丁准入规则：历史 `diy-part2.sh` 的 `sed`、旧注释或用户常用运行值都不能单独证明源码补丁有必要。必须先对照本次 source-lock 的上游实现和现有 UCI/规则接口；已经失效、已被上游覆盖或能由运行时配置表达的改动不进入 patchset。需要持续追新的内核能力应在仓库保存受信任 provider/ref/path 策略，每轮解析兼容 port、物化并冻结 commit/hash，再对精确 kernel clean-apply；缺少匹配适配时失败，不能套用其他内核版本、切 testing kernel 或静默回退。
- BBRv3 与运行时所有权规则：BBRv3 是修改 TCP core 的版本化内核能力，不是普通插件。common 保留 Lean 的 `kmod-tcp-bbr`、`tcp_bbr.ko` 和运行名 `bbr` 契约，以 source-lock、patch SHA256、源码 `BBR_VERSION=3`、build `modinfo` 和真机 `/sys/module/tcp_bbr/version=3` 证明代际；这样可直接复用 TurboACC 的上游依赖。一次性 UCI 脚本只在确认 version `3` 后设置 factory default 并写持久标记，sysupgrade 不覆盖用户后来选择的 CCA；后续 TCP CCA 和 software flow offload 由 TurboACC/UCI 唯一管理，并以 PassWall、firewall 和 nlbwmon 真机一致性验收。
- qdisc provider 规则：写入 `net.core.default_qdisc=fq` 不代表内核已经提供 `fq`；`fq_codel` 也不是 `fq`。必须从当前 source-lock 的 kernel package 定义确认 provider，common 显式选择它，并在构建树检查 `sch_fq.ko`、在真机检查 `/sys/module/sch_fq` 与实际 qdisc，不能只验证 sysctl 文本。
- 上游产物规则：HAProxy LTS、AdGuardHome stable、GeoIP 和 Geosite 可以自动追最新，但 resolver 必须使用发布方的 SHA256/checksum/asset digest，并把精确结果写入 source-lock；package applicator 不访问网络，不允许 `PKG_HASH:=skip` 或 `latest/download`。设备内二进制自更新不得绕开 OPKG、非特权 jail、provenance 和 Release 回滚。
- Feed provider 规则：同一 package 同时存在于默认与自定义 feed 时，不能依赖 `feeds install -a` 的偶然遍历顺序。只有真实 provider 冲突才允许在锁定 feed checkout 中删除未选 source directory，随后必须重建相关 feed index，并用共享 provider contract 同时约束 selector、artifact applicator 和最终 profile checker。
- 用户网络默认规则：用户已明确 common 地址池从 `.32` 开始且 `limit=232`，LAN DHCPv6/NDP 使用 relay；与 relay 配套的 WAN relay master、LAN `delegate=0`/`ip6assign=64` 必须作为同一契约测试，不能只改一个 UCI 字段造成半配置状态。其余 WAN 地址、桥接和端口偏好不从历史配置扩大推断。
- 构建优化规则：运行性能优化、固件体积优化和链接速度优化必须分开评价。LTO/GC sections 是实验项，Mold 主要缩短链接时间；不能为了“全开”让持续 master 的生产构建积累单包 opt-out 和隐性 fallback。
- GCC 方言规则：GCC 大版本切换会改变默认 C 方言；Lean master 的旧包即使未安装，也可能因 host/build dependency 进入编译图。先用串行日志确认具体语义冲突，再对单包固定其原始兼容方言（当前 `libsepol 3.3` 使用 GNU17），不得全局降级 GCC 或放宽错误。
- CI 缓存规则：ccache、下载缓存和 toolchain 缓存必须分层。key 至少绑定架构、编译器、profile、patch 和 source-lock；不恢复 fork 缓存，不使用无完整 identity 的第三方预编译工具链。
- Actions runtime 规则：用户明确优先直接跟踪最新版本，因此 workflow 只允许官方 `actions/*@main`，不保留静态 action lock、tag 或 SHA。resolver 可把 prepare 时观察到的 HEAD 写入 source-lock/update fingerprint，但 action 在 prepare 前已解析，观察值不能冒充不可变执行身份；任何上游 runtime 或行为漂移必须直接使门禁失败。扫描器必须同时识别 YAML 的 `uses:` 映射行与 `- uses:` 行内列表形式。
