**English** | [中文](https://p3terx.com/archives/build-openwrt-with-github-actions.html)

# Actions-OpenWrt

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/P3TERX/Actions-OpenWrt/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Forks&logo=github)

A template for building OpenWrt with GitHub Actions

## Usage

- Click the [Use this template](https://github.com/P3TERX/Actions-OpenWrt/generate) button to create a new repository.
- Edit files under `profiles/` to choose shared packages or per-device target settings.
- Push the profile changes to the GitHub repository.
- Select `OpenWrt Builder` on the Actions page.
- Click the `Run workflow` button.
- Choose `x86`, `r4s`, or `all` in the `profile` input.
- When the build is complete, click the `Artifacts` button in the upper right corner of the Actions page to download the binaries.

## Tips

- It may take a long time to expand a config and build the OpenWrt firmware. Thus, before create repository to build your own firmware, you may check out if others have already built it which meet your needs by simply [search `Actions-Openwrt` in GitHub](https://github.com/search?q=Actions-openwrt).
- Add some meta info of your built firmware (such as firmware architecture and installed packages) to your repository introduction, this will save others' time.

## Profile workflow

This fork keeps minimal profile fragments instead of maintaining a full generated `.config`.

- `master` is the only active maintenance branch. Old `X86` and `R4S` branches are kept as read-only references.
- The GitHub repository default branch should be `master`; scheduled update checks and triggered builds are expected to run from `master`.
- Edit `profiles/common/config.seed` when you want to add or remove shared LuCI apps or package options.
- Edit `profiles/x86/config.seed` or `profiles/r4s/config.seed` only for target, image size, hardware drivers, kernel settings, and device-specific tuning.
- Edit `profiles/common/profile.env` for shared build metadata such as LAN IP, bootstrap mode, feeds update mode, and the official Go feed source. Profile env files only define source repo/ref, target validation, and profile names.
- Optional profile patchsets are selected with `PROFILE_PATCHSET` in a profile env file. The build calls a generic patch hook after feeds are installed; profiles without a patchset skip this step.
- Edit `profiles/common/forbidden-packages.txt` for shared block/prune policy, and profile-specific forbidden files only for hardware differences.
- Edit `profiles/common/required-packages.txt` or `profiles/<profile>/required-packages.txt` when a package/config symbol is critical and the build must fail if Kconfig drops it.
- The build renders `profiles/common/*` plus `profiles/<profile>/*` into temporary `.config`, env, forbidden, and required package files; root-level `config.seed` and `forbidden-packages.txt` are intentionally not maintained.
- Edit `feeds.custom.conf` when you want to add, remove, or change custom feed sources. Builds read this file; scheduled update checks intentionally ignore custom feed changes.
- `prune:` rules remove known broken/unwanted package entries with a `Makefile` before OpenWrt scans package menus; `exact:` and `regex:` rules fail the final config check if those packages are selected.
- Do not add dependency libraries or kernel modules manually unless you are deliberately overriding OpenWrt defaults. `make defconfig` expands real dependencies during the GitHub Actions build.
- The build replaces only `feeds/packages/lang/golang` with OpenWrt official `openwrt/packages` `lang/golang`, then rebuilds the packages feed index so current Go-based packages can build without importing an extra third-party Go feed.
- Shared packages currently include PassWall, MosDNS, SmartDNS, AdGuardHome, ddns-go, nlbwmon, arpbind, autoreboot, ramfree, ttyd, turboacc, upnp, wol, coremark, lsof, and `openssh-sftp-server`.
- Both x86 and R4S build from `coolsnowwolf/lede master`, so shared packages resolve against the same Lean package and LuCI ecosystem.
- The x86 profile builds the PVE VM image and keeps VirtIO plus `kmod-igc`.
- The R4S profile builds `friendlyarm_nanopi-r4s` and keeps only R4S hardware support such as cpufreq, pwmfan, R8168, RTL8152, USB, MMC/SDHCI, NIC firmware, zram, and SD-image maintenance dependencies.
- Both maintained profiles intentionally use the same common main-router stack: firewall3/iptables, `dnsmasq-full`, PPPoE, IPv6, fullcone, TUN, BBR and UPnP. `firewall4`, nftables packages, nft UPnP, and natflow are blocked.
- The experimental `experiment/sbwml-public-r4s` branch lets the R4S profile opt in to `sbwml-public-mainline`. That patchset only applies restricted kernel/target patch material from sbwml sources; private `git.cooluc.com` target repositories must be mapped to explicit public replacements or the build fails before patching.
- Docker, Samba, legacy `ddns-scripts`, VLMCS, vsftpd, openlist, qbittorrent, zerotier, homeproxy, nikki, mihomo, and similar non-target packages are blocked before or after Kconfig resolution.
- `diy-part2.sh` tracks the latest HAProxy LTS release automatically. Set `HAPROXY_VERSION` in the build workflow only when you need to pin or roll back temporarily.
- The build workflow writes the expanded diff to `config.effective` in the Actions log, so you can see what the latest upstream Kconfig resolved.
- The build workflow writes the final built-in package selections to `package-list.txt`, uploads config reports, fails when any selected seed symbol is dropped or changed by `make defconfig`, fails when any forbidden package is selected, and fails when any required package/config symbol is missing.
- Releases are created, published, and pruned with GitHub CLI/API instead of third-party release actions, so failed action finalization cannot leave firmware releases as drafts and Node.js action runtime deprecations do not affect release publishing.
- The scheduled update checker runs once per profile and only tracks the upstream OpenWrt/Lean source ref. Custom feed, profile, and helper-script changes should be built with a manual `OpenWrt Builder` run.
- The root `.config` file is ignored on purpose. It is a generated local/OpenWrt build artifact, not the repository config source.

Feed lines use OpenWrt's normal format. A `;branch` suffix tracks that branch, while a URL without suffix tracks the remote default branch:

```sh
src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
src-git small https://github.com/kenzok8/small.git
```

To refresh a profile seed from a full config inside an OpenWrt source tree:

```sh
cp /path/to/full/.config .config
make defconfig
./scripts/diffconfig.sh > /path/to/Actions-OpenWrt/profiles/<profile>/config.seed
```

## Credits

- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
