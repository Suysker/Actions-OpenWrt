**English** | [中文](https://p3terx.com/archives/build-openwrt-with-github-actions.html)

# Actions-OpenWrt

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/P3TERX/Actions-OpenWrt/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Forks&logo=github)

A template for building OpenWrt with GitHub Actions

## Usage

- Click the [Use this template](https://github.com/P3TERX/Actions-OpenWrt/generate) button to create a new repository.
- Edit `config.seed` to choose the target and packages. ( You can change the source repository through environment variables in the workflow file. )
- Push `config.seed` to the GitHub repository.
- Select `Build OpenWrt` on the Actions page.
- Click the `Run workflow` button.
- When the build is complete, click the `Artifacts` button in the upper right corner of the Actions page to download the binaries.

## Tips

- It may take a long time to expand a config and build the OpenWrt firmware. Thus, before create repository to build your own firmware, you may check out if others have already built it which meet your needs by simply [search `Actions-Openwrt` in GitHub](https://github.com/search?q=Actions-openwrt).
- Add some meta info of your built firmware (such as firmware architecture and installed packages) to your repository introduction, this will save others' time.

## Config workflow

This fork keeps a minimal `config.seed` instead of maintaining a full generated `.config`.

- Edit `config.seed` when you want to add or remove LuCI apps or package options.
- Edit `feeds.custom.conf` when you want to add, remove, or change custom feed sources. Build and update-checker both read this file.
- `forbidden-packages.txt` is the block policy. `prune:` rules remove known broken/unwanted package entries with a `Makefile` before OpenWrt scans package menus; `exact:` and `regex:` rules only fail the final config check if those packages are selected.
- Do not add dependency libraries or kernel modules manually unless you are deliberately overriding OpenWrt defaults. `make defconfig` expands real dependencies during the GitHub Actions build.
- The build replaces only `feeds/packages/lang/golang` with OpenWrt official `openwrt/packages` `lang/golang`, then rebuilds the packages feed index so current Go-based packages can build without importing an extra third-party Go feed.
- This profile enables OpenWrt's testing kernel option, so it follows the target's `KERNEL_TESTING_PATCHVER`.
- This PVE VM profile keeps SeaBIOS and EFI images, VirtIO disk/net support through `CONFIG_VIRTIO_SUPPORT`, and Intel i225 passthrough through `kmod-igc`.
- `diy-part2.sh` tracks the latest HAProxy LTS release automatically. Set `HAPROXY_VERSION` in the build workflow only when you need to pin or roll back temporarily.
- Edit `forbidden-packages.txt` when an upstream or Lean default package must be blocked from the image.
- The build workflow writes the expanded diff to `config.effective` in the Actions log, so you can see what the latest upstream Kconfig resolved.
- The build workflow writes the final built-in package selections to `package-list.txt`, uploads config reports, and fails when any forbidden package is selected.
- The update checker tracks Lean's source plus the external feeds in `feeds.custom.conf`; source or plugin feed updates trigger a rebuild automatically.
- The root `.config` file is ignored on purpose. It is a generated local/OpenWrt build artifact, not the repository config source.

Feed lines use OpenWrt's normal format. A `;branch` suffix tracks that branch, while a URL without suffix tracks the remote default branch:

```sh
src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git;main
src-git small https://github.com/kenzok8/small.git
```

To refresh the seed from a full config inside an OpenWrt source tree:

```sh
cp /path/to/full/.config .config
make defconfig
./scripts/diffconfig.sh > /path/to/Actions-OpenWrt/config.seed
```

## Credits

- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
