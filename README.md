# 京东云鲁班 RE-CP-02 ImmortalWrt 双镜像

本仓库通过 GitHub Actions 为京东云鲁班 AX1800（JDCloud RE-CP-02）
构建 ImmortalWrt 25.12。设备支持直接使用 ImmortalWrt 上游设备树，不应用旧版
第三方 `jdcloud_luban` 补丁。

构建将 16 MiB SPI NOR 作为精简、可独立启动的主系统，把完整应用环境预展开到
SD/TF 卡上的 extroot。Nikki 以 git submodule 固定源码版本，并在同一构建树中现场
编译。

完整的本地交叉编译、SD 写卡、Ubuntu/Debian TFTP Server 配置、串口接线和
U-Boot 烧录步骤见 [本地构建与烧录指南](FLASHING_GUIDE.zh-CN.md)。

## 构建产物

在 GitHub 仓库的 Actions 页面手动运行 **Build JDCloud Luban ImmortalWrt**。
下载的 artifact 包含两个可刷写镜像：

- `JDCOS.bin`：官方 squashfs sysupgrade 镜像的 U-Boot 恢复命名，用于 SPI NOR。
- `luban-sd-extroot.img.gz`：由计算机整盘写入 SD/TF 卡的 GPT 镜像。

同时附带：

- `SHA256SUMS`
- `NOR_MANIFEST` 与 `EXTROOT_MANIFEST`
- `SYSUPGRADE_METADATA.json`
- `config.nor` 与 `config.extroot`
- ImmortalWrt、feeds 和 Nikki 的实际构建提交号

`JDCOS.bin` 只覆盖官方设备树定义的 firmware 分区，不包含 U-Boot、Config 或每台
设备唯一的 Factory/Wi-Fi 标定数据。

## 软件布局

NOR 中只保留启动、网络、LuCI、中文基础界面、SD/MMC、ext4 和 extroot 所需组件。

SD extroot 中预装：

- 防火墙、Argon 配置、软件包管理器、ttyd 及中文翻译
- HomeProxy、WireGuard、Tailscale Community、VLMCSd 及中文翻译
- FileBrowser daemon、`luci-app-filebrowser` 及中文翻译
- Samba 4
- qBittorrent、LuCI 配置页及中文翻译
- Nikki、LuCI、中文翻译、Mihomo 及完整依赖

没有安装 `luci-app-filebrowser-go`。它和 `luci-app-filebrowser` 会提供同名 ACL
文件，本构建按约定保留后者；FileBrowser daemon 仍然存在，并可使用自身 WebUI。

## SD 镜像布局

镜像使用 GPT：

1. 100 MiB FAT32，卷标 `LUBANBOOT`，包含 `JDCOS.bin`、说明和校验值。
2. 固定 2 GiB ext4，卷标 `luban-extroot`，UUID
   `7fdb0d8a-01b5-4ab3-a5ac-431000000002`，保存预展开的 overlay。

写入更大的卡后，剩余容量保持未分配。此 2 GiB 分区用于系统和应用，不适合作为
qBittorrent 大容量下载目录；下载和 Samba 数据应使用另外挂载的存储。

## 刷写前备份

刷机前至少保存以下内容并核对校验值：

- 完整 16 MiB NOR
- `mtd0` U-Boot
- `mtd1` Config
- `mtd2` Factory
- 当前原厂 firmware
- 原 SD/eMMC 分区表和需要保留的数据

其中 Factory 包含本机 MAC 地址和 Wi-Fi 标定，不能由其他设备的备份替代。

## 写入 SD/TF 卡

先核对下载文件：

```sh
sha256sum -c SHA256SUMS
```

Linux 写卡示例：

```sh
gzip -dc luban-sd-extroot.img.gz |
  sudo dd of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress
```

`/dev/sdX` 必须替换为整张 SD 卡，而不是某个分区。此操作会覆盖目标卡现有分区表
和数据。Windows 可使用能够写入压缩 raw image 的镜像工具。

## 通过原厂 U-Boot 写入 NOR

在地址 `192.168.68.10` 的计算机上启动 TFTP 服务，并把 `JDCOS.bin` 放到 TFTP
根目录。使用 3.3 V、115200 波特率串口中断 U-Boot，按原厂恢复逻辑执行：

```text
setenv ipaddr 192.168.68.1
setenv serverip 192.168.68.10
setenv netmask 255.255.255.0
run altbootcmd
```

这些 `setenv` 只修改本次 U-Boot 会话，不要执行 `saveenv`。设备会立即请求
`JDCOS.bin` 并写入 firmware 分区。不要使用整片 NOR 写入命令，也不要擦除
U-Boot、Config 或 Factory。

如果曾按旧流程保存过 `bootlimit=5` 和超限的 `bootcount`，设备会在每次启动时
自动进入刷机模式。中断 U-Boot 后恢复本机原始环境值：

```text
printenv bootcmd bootcount bootlimit
setenv bootcmd jdboot
setenv bootlimit 99999
setenv bootcount 0
saveenv
reset
```

## 首次启动

建议先写好 SD 卡并插入路由器，再刷写 `JDCOS.bin`。

第一次启动时，NOR 系统会：

1. 查找卷标和 UUID 都匹配的 extroot。
2. 验证镜像准备标记。
3. 将 NOR 当前 overlay 合并到 SD 的预展开 `upper/`。
4. 在 SD 和 NOR 中写入 extroot 配置。
5. 同步文件系统并自动重启。

第二次启动后，完整应用环境直接来自 SD。流程可重复执行；如果准备阶段断电，在
NOR 尚未启用切换时会自动重试。

默认管理地址和首次登录策略保持 ImmortalWrt 默认值，未预置密码、代理订阅、
Tailscale 凭据或 qBittorrent 下载目录。

## 回滚

先通过 U-Boot/TFTP 将已验证的原厂 firmware 作为 `JDCOS.bin` 恢复到 firmware
分区。如需完全恢复原机状态，再用备份镜像恢复原 SD/eMMC 分区布局。正常回滚不应
写入其他设备的 Factory 分区。
