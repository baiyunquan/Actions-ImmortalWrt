# 京东云鲁班 RE-CP-02 本地构建与烧录指南

本指南适用于本仓库生成的双镜像：

- `JDCOS.bin`：写入 16 MiB SPI NOR 中的 `firmware` 分区。
- `luban-sd-extroot.img.gz`：在另一台计算机上整盘写入 SD/TF 卡。

当前构建固定使用稳定版 ImmortalWrt `v25.12.1`，以及该版本官方
`feeds.conf.default` 中记录的 feeds 提交，不使用滚动的 Snapshot 分支。

`JDCOS.bin` 的最大允许尺寸是 `0xf70000`（16,187,392 字节，即 15,808 KiB）。它不包含
U-Boot、Config 或 Factory。Factory 保存本机 MAC 地址和 Wi-Fi 标定数据，绝不能
用其他机器的备份替换。

## 1. 当前本地构建成果

本机已经完成一次交叉编译和双镜像组装，成果位于：

```text
/home/liaic/backup_luban/.local-build/output/
```

其中可直接部署的文件是：

```text
/home/liaic/backup_luban/.local-build/output/JDCOS.bin
/home/liaic/backup_luban/.local-build/output/luban-sd-extroot.img.gz
```

同一目录还保存 `SHA256SUMS`、NOR/extroot 软件清单、最终配置和各源码提交号。
烧录前必须验证：

```sh
cd /home/liaic/backup_luban/.local-build/output
sha256sum -c SHA256SUMS
stat -c '%n %s bytes' JDCOS.bin
```

当前已验证的两个部署镜像为：

```text
ced1f7f47f400afebad251a6911fca27b44570e5b16c0ac16388071a55b77d04  JDCOS.bin
58ecfddc0b7c4aca5e55765d13a97a62da8f0762ad9cfcece48856fca1c51926  luban-sd-extroot.img.gz
```

重新构建后校验值会改变，应始终以新输出目录内的 `SHA256SUMS` 为准。

## 2. 在 Ubuntu 24.04 本地重新构建

建议至少准备 4 核 CPU、16 GiB 内存和 60 GiB 可用磁盘空间。构建目录不能位于
Windows/NTFS 挂载盘；WSL 用户还应避免让 MSYS2/Windows Qt、编译器目录出现在
`PATH` 中，否则主机 Qt 的头文件可能污染 MIPS 交叉编译。

安装依赖：

```sh
sudo apt update
sudo apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses-dev libssl-dev python3 python3-pyelftools \
  python3-setuptools rsync swig unzip zlib1g-dev file wget curl \
  libelf-dev device-tree-compiler qemu-utils dosfstools e2fsprogs \
  fdisk mtools pigz zstd fakeroot
```

从仓库根目录执行以下命令。Nikki 必须递归初始化，不能只取得主仓库：

```sh
cd /home/liaic/backup_luban/Actions-ImmortalWrt
git submodule update --init --recursive

export LUBAN_REPO_DIR="$PWD"
export LUBAN_BUILD_DIR="/home/liaic/backup_luban/.local-build"
export LUBAN_SOURCE_DIR="$LUBAN_BUILD_DIR/ImmortalWrt"
export LUBAN_METADATA_DIR="$LUBAN_BUILD_DIR/metadata"
export LUBAN_EXTROOT_DIR="$LUBAN_BUILD_DIR/extroot-stage"
export LUBAN_OUTPUT_DIR="$LUBAN_BUILD_DIR/output"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p "$LUBAN_BUILD_DIR"
git clone --depth 1 --branch v25.12.1 \
  https://github.com/immortalwrt/immortalwrt.git "$LUBAN_SOURCE_DIR"

cp "$LUBAN_REPO_DIR/feeds.conf.default" "$LUBAN_SOURCE_DIR/feeds.conf.default"
rm -rf "$LUBAN_SOURCE_DIR/package/nikki" "$LUBAN_SOURCE_DIR/files"
mkdir -p "$LUBAN_SOURCE_DIR/package/nikki"
rsync -a --exclude=.git \
  "$LUBAN_REPO_DIR/package/nikki/" "$LUBAN_SOURCE_DIR/package/nikki/"
cp -a "$LUBAN_REPO_DIR/files" "$LUBAN_SOURCE_DIR/files"
cp "$LUBAN_REPO_DIR/diy.sh" "$LUBAN_SOURCE_DIR/diy.sh"

cd "$LUBAN_SOURCE_DIR"
chmod +x diy.sh
./diy.sh
./scripts/feeds update -a
./scripts/feeds install -a
cp "$LUBAN_REPO_DIR/.config" .config
make defconfig

if ! timeout --foreground 45m make download -j8; then
  find dl -type f -size -1024c -print -delete
  timeout --foreground 45m make download -j4
fi
find dl -type f -size -1024c -print -delete

make -j"$(nproc)" || make -j1 V=s

mkdir -p "$LUBAN_METADATA_DIR"
cp .config "$LUBAN_METADATA_DIR/config.nor"
git rev-parse HEAD > "$LUBAN_METADATA_DIR/IMMORTALWRT_COMMIT"
git -C "$LUBAN_REPO_DIR/package/nikki" rev-parse HEAD \
  > "$LUBAN_METADATA_DIR/NIKKI_COMMIT"
: > "$LUBAN_METADATA_DIR/FEED_COMMITS"
for LUBAN_FEED_DIR in feeds/*; do
  test -d "$LUBAN_FEED_DIR" || continue
  printf '%s %s\n' \
    "$(basename "$LUBAN_FEED_DIR")" \
    "$(git -C "$LUBAN_FEED_DIR" rev-parse HEAD)" \
    >> "$LUBAN_METADATA_DIR/FEED_COMMITS"
done

"$LUBAN_REPO_DIR/scripts/build-rich-rootfs.sh" \
  "$LUBAN_SOURCE_DIR" "$LUBAN_EXTROOT_DIR" "$LUBAN_METADATA_DIR"
"$LUBAN_REPO_DIR/scripts/collect-artifacts.sh" \
  "$LUBAN_SOURCE_DIR" "$LUBAN_EXTROOT_DIR" \
  "$LUBAN_METADATA_DIR" "$LUBAN_OUTPUT_DIR"

cd "$LUBAN_OUTPUT_DIR"
sha256sum -c SHA256SUMS
```

若源码目录已经存在，不要再次 `git clone`。确认其中没有需要保留的修改后再决定
更新或重建；不要直接删除不明来源的构建目录。

## 3. 烧录前准备与备份

至少保留并校验以下本机备份：

- 完整 16 MiB NOR。
- `mtd0` Bootloader。
- `mtd1` Config。
- `mtd2` Factory。
- `mtd3` 原厂 firmware。
- 原 SD/eMMC 分区表和重要数据。

准备一只 3.3 V USB-TTL 串口模块，串口参数为 115200、8N1、无流控。主板 J4
针脚已有 `V/R/T/G` 标识：

- USB-TTL GND 接路由器 `G`。
- USB-TTL TX 接路由器 `R`。
- USB-TTL RX 接路由器 `T`。
- 不连接 `V`，路由器使用自己的 12 V 电源供电。

## 4. 将 extroot 镜像写入 SD/TF 卡

先用 `lsblk` 确认卡的整盘设备名。下例中的 `/dev/sdX` 必须替换为 SD 卡整盘，
不能写成 `/dev/sdX1`；命令会覆盖该卡的分区表和全部已有数据。

```sh
lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS
sudo umount /dev/sdX?* 2>/dev/null || true
gzip -dc \
  /home/liaic/backup_luban/.local-build/output/luban-sd-extroot.img.gz |
  sudo dd of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress
sync
sudo fdisk -l /dev/sdX
```

写入后应看到一个约 100 MiB 的 FAT32 `LUBANBOOT` 分区和一个固定 2 GiB 的 ext4
`luban-extroot` 分区。更大卡上的剩余空间故意保持未分配。

先完成写卡并把 SD 卡插入断电的路由器，再开始 NOR 烧录。

## 5. 在本地计算机建立 TFTP Server

以下示例使用 Ubuntu/Debian 的 `tftpd-hpa`。计算机通过网线直连路由器 LAN 口，
最好使用一块专用有线网卡，关闭这条连接上的 DHCP，并给它设置
`192.168.68.10/24`。不需要设置网关或 DNS。

安装服务并准备 TFTP 根目录：

```sh
sudo apt update
sudo apt install -y tftpd-hpa tftp-hpa
sudo install -d -o tftp -g tftp -m 0755 /srv/tftp
sudo install -o tftp -g tftp -m 0644 \
  /home/liaic/backup_luban/.local-build/output/JDCOS.bin \
  /srv/tftp/JDCOS.bin
```

编辑 `/etc/default/tftpd-hpa`，内容设为：

```text
TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/srv/tftp"
TFTP_ADDRESS="0.0.0.0:69"
TFTP_OPTIONS="--secure --verbose"
```

重启并确认 UDP 69 端口正在监听：

```sh
sudo systemctl restart tftpd-hpa
sudo systemctl enable tftpd-hpa
sudo systemctl --no-pager --full status tftpd-hpa
sudo ss -lunp | grep ':69 '
```

查看有线接口名，并临时添加服务器地址。将 `enp3s0` 换成实际的专用有线接口：

```sh
ip -br link
export LUBAN_TFTP_IF="enp3s0"
sudo ip link set "$LUBAN_TFTP_IF" up
sudo ip address add 192.168.68.10/24 dev "$LUBAN_TFTP_IF"
ip -4 address show dev "$LUBAN_TFTP_IF"
```

如果系统提示地址已经存在，可以忽略该提示并用最后一条命令核对。若启用了主机
防火墙，需要允许这块直连网卡上的 TFTP/UDP 流量；不要把 TFTP 服务暴露到公网。

先在服务器本机测试下载并比较内容：

```sh
rm -f /tmp/JDCOS.tftp-test.bin
tftp 127.0.0.1 <<'EOF'
binary
get JDCOS.bin /tmp/JDCOS.tftp-test.bin
quit
EOF
cmp /srv/tftp/JDCOS.bin /tmp/JDCOS.tftp-test.bin
sha256sum /srv/tftp/JDCOS.bin /tmp/JDCOS.tftp-test.bin
```

`cmp` 无输出且返回成功，才表示本地 TFTP 服务可用。烧录时可以另开终端查看请求：

```sh
sudo journalctl -fu tftpd-hpa
```

## 6. 通过原厂 U-Boot/TFTP 写入 SPI NOR

1. 保持 SD 卡已插入，网线连接计算机与路由器 LAN 口。
2. 打开 3.3 V 串口终端，参数设为 115200、8N1、无流控。
3. 给路由器上电，在串口出现启动信息时按任意键中断自动启动。
4. 在 U-Boot 提示符核对恢复命令和网络环境：

```text
printenv altbootcmd ipaddr serverip netmask
```

`altbootcmd` 应包含获取 `JDCOS.bin`、擦除并写入 `firmware` 分区的原厂恢复命令。
执行以下命令设置本次会话使用的网络地址并直接运行它：

```text
setenv ipaddr 192.168.68.1
setenv serverip 192.168.68.10
setenv netmask 255.255.255.0
run altbootcmd
```

不要在这一步执行 `saveenv`。三个网络变量只影响当前 U-Boot 会话，不会改变后续
正常启动条件。原厂恢复逻辑会立即从 `192.168.68.10` 请求严格区分大小写的
`JDCOS.bin`，写入 `firmware` 分区，并在完成后自动重启。期间：

- 不要断电、拔网线、关闭 TFTP 服务或操作复位键。
- 不要执行整片 NOR 的 `erase`、`cp.b` 或其他手工写入命令。
- 不要写入或擦除 U-Boot、Config、Factory。

正确进入恢复分支时，串口应出现类似以下关键字：

```text
TFTP from server 192.168.68.10
Filename 'JDCOS.bin'
Recovering
```

若 TFTP 没有请求，依次检查服务器地址是否确为 `192.168.68.10/24`、文件名、
文件权限、网线是否接 LAN 口、防火墙和 `journalctl -fu tftpd-hpa` 日志。不要在
原因未明时反复擦写 NOR。

## 7. 恢复 U-Boot 正常启动

旧版步骤曾通过保存 `bootlimit=5` 和 `bootcount=6` 触发恢复。刷写成功不会自动
撤销这两个环境变量，因此设备可能在每次启动时继续执行 `altbootcmd` 并重复刷写。

出现这种情况时，在串口上持续按键并重新上电，中断 U-Boot 自动启动，然后执行：

```text
printenv bootcmd bootcount bootlimit upgradeFlag
setenv bootcmd jdboot
setenv bootlimit 99999
setenv bootcount 0
saveenv
printenv bootcmd bootcount bootlimit upgradeFlag
reset
```

第二次 `printenv` 应显示：

```text
bootcmd=jdboot
bootcount=0
bootlimit=99999
upgradeFlag=2
```

这里只恢复本机备份中已经确认的正常启动变量。不要删除 `altbootcmd`，不要修改
`upgradeFlag`，也不要执行 `env default -a`；后两类操作可能破坏原厂恢复能力或
设备特有环境数据。`saveenv` 只更新 64 KiB 的 Config/U-Boot 环境分区，不会重写
U-Boot、Factory 或刚刷入的 firmware。

恢复后，正常启动应直接出现 `upgradeFlag=2`，随后从 NOR `0x90000` 读取并启动
ImmortalWrt，不再出现 `Using altbootcmd`、`Filename 'JDCOS.bin'` 或
`Recovering`。

## 8. 首次启动与确认

首次启动时，NOR 上的初始化服务会验证 SD 镜像，将 NOR 当前 overlay 合并到
SD 的 `upper/`，写入 extroot 配置并自动重启一次。第二次启动才进入完整的软件
环境。

等待自动重启完成后，检查：

```sh
mount | grep ' /overlay '
df -h /overlay
logread | grep -i luban
```

`/overlay` 应来自 SD 卡的 ext4 文件系统。确认 LuCI、网络和 extroot 正常后再配置
Nikki、Tailscale、qBittorrent 与共享目录。构建没有预置密码、订阅、凭据或下载
目录。

如果 `lsblk` 已显示 `/dev/mmcblk0p2` 挂在 `/mnt/mmcblk0p2`，但 `/overlay`
仍来自 `/dev/mtdblock6`，说明 SD 和 ext4 均正常，只是 extroot 初始化服务尚未
运行。执行：

```sh
/etc/init.d/luban-extroot enable
/etc/init.d/luban-extroot start
```

服务会验证 SD 镜像、写入 fstab 并自动重启。重启后再次检查 `/overlay`。本仓库
同时在固件中提供 `/etc/rc.d/S96luban-extroot`，后续构建会默认运行该服务。

精简 NOR 固件没有内置 `fdisk`；它是独立的 util-linux 软件包，不影响内核识别
GPT 或 extroot。查看现有分区可使用：

```sh
lsblk
block info
cat /proc/partitions
```

确实需要修改分区表时，等 extroot 和网络正常后再执行 `apk update && apk add fdisk`。

## 9. 后续升级

### 9.1 升级原则

每次 GitHub Actions 构建都会同时生成一组相互匹配的 `JDCOS.bin` 和
`luban-sd-extroot.img.gz`。NOR 提供内核和基础系统，SD extroot 提供完整用户空间；
升级时必须使用同一次 Actions 运行中的两个镜像。不要将新 NOR 与旧 SD，或旧 NOR
与新 SD 长期混用，否则内核模块、共享库和应用版本可能不兼容。

不建议对本设备执行无差别的 `apk upgrade`。安装或更新单个普通应用可以使用
`apk add <package>`，但内核、基础库或大批软件升级应通过新的成对镜像完成。

### 9.2 升级前备份

先确认当前系统确实从 SD 使用 extroot：

```sh
mount | grep ' /overlay '
df -h /overlay
```

在路由器上创建配置备份，并记录已安装软件：

```sh
sysupgrade -k -b /tmp/luban-upgrade-backup.tar.gz
apk list --installed > /tmp/luban-installed-packages.txt
```

然后在计算机上取回文件：

```sh
scp root@192.168.1.1:/tmp/luban-upgrade-backup.tar.gz .
scp root@192.168.1.1:/tmp/luban-installed-packages.txt .
```

备份包含系统配置，但不应被视为下载数据、共享目录或其他用户文件的副本。升级前
仍需单独备份这些数据。不要把旧的完整 SD `upper/` 目录直接覆盖到新镜像；这样会
把旧版程序和共享库一起带回。

### 9.3 推荐的完整升级

1. 从同一次 GitHub Actions 运行下载完整产物，执行 `sha256sum -c SHA256SUMS`。
2. 按第 4 节将新的 `luban-sd-extroot.img.gz` 写入备用 SD 卡。使用备用卡可以保留
   旧系统作为回退；若重写原卡，其全部分区和数据都会被覆盖。
3. 将同一产物中的新 `JDCOS.bin` 放入 TFTP 目录，并按第 5 节验证文件。
4. 关闭路由器电源，插入写好的新 SD 卡，通过串口进入 U-Boot。
5. 按第 6 节设置临时网络变量并执行 `run altbootcmd`。不要执行 `saveenv`，不要
   擦写 U-Boot、Config 或 Factory。
6. 写入完成后让设备正常启动。首次启动可能因准备 extroot 自动重启一次，等待第二次
   启动完成后再登录。
7. 按第 8 节确认 `/overlay` 来自 `/dev/mmcblk0p2`，并核对 LuCI 和网络。

新系统确认正常后，将备份传回路由器并恢复：

```sh
scp luban-upgrade-backup.tar.gz \
  root@192.168.1.1:/tmp/luban-upgrade-backup.tar.gz
ssh root@192.168.1.1 \
  'sysupgrade -r /tmp/luban-upgrade-backup.tar.gz && reboot'
```

恢复后检查网络、挂载和所需服务。若旧备份中的某项配置与新版软件不兼容，只恢复
对应的 UCI 配置，不要把旧版可执行文件或库复制回系统。至少保留旧 SD 卡和上一版
完整 Actions 产物，直到新版稳定运行。

### 9.4 只更新 NOR 或只重写 SD

`JDCOS.bin` 本质上是带设备元数据的 sysupgrade 镜像，可以先执行
`sysupgrade -T /tmp/JDCOS.bin` 检查，再通过 LuCI 或 `sysupgrade` 写入。但是在
extroot 正在使用时单独升级 NOR，重启后仍会加载旧 SD 用户空间，因此不适合作为
本设备的常规升级方式。

确实只需修复 NOR 时，应先关机并取出 SD 卡，从独立的精简 NOR 系统启动，再执行：

```sh
scp JDCOS.bin root@192.168.1.1:/tmp/JDCOS.bin
ssh root@192.168.1.1 'sysupgrade -T /tmp/JDCOS.bin'
ssh root@192.168.1.1 'sysupgrade -n /tmp/JDCOS.bin'
```

升级期间 SSH 会断开，等待设备自行重启，不能断电。NOR-only 启动只提供精简系统；
重新插入 SD 前，应确保该卡来自同一次构建。

只重写 SD 仅适用于修复同一版本的 extroot，或者随后立即把 NOR 升级为同一次构建
的 `JDCOS.bin`。不要让不同构建批次的 NOR 和 SD 继续运行。

### 9.5 升级后核对

```sh
mount | grep ' /overlay '
df -h /overlay
cat /etc/openwrt_release
logread | grep -i -E 'luban|extroot'
```

还应确认 `/overlay` 来自 `/dev/mmcblk0p2`、LuCI 可以登录、LAN/WAN 和无线正常，
再启用 Nikki、Tailscale、Samba、qBittorrent 等可选服务。

## 10. 停止本地 TFTP 服务

烧录完成后不再需要 TFTP：

```sh
sudo systemctl disable --now tftpd-hpa
sudo ip address del 192.168.68.10/24 dev "$LUBAN_TFTP_IF"
```

保留 `/srv/tftp/JDCOS.bin` 不影响路由器；如不再需要，可在确认备份后手工移除。
