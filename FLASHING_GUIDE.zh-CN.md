# 京东云鲁班 RE-CP-02 本地构建与烧录指南

本指南适用于本仓库生成的双镜像：

- `JDCOS.bin`：写入 16 MiB SPI NOR 中的 `firmware` 分区。
- `luban-sd-extroot.img.gz`：在另一台计算机上整盘写入 SD/TF 卡。

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
git clone --depth 1 --branch openwrt-25.12 \
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
4. 在 U-Boot 提示符执行：

```text
setenv bootcount 6
saveenv
reset
```

重启后，原厂恢复逻辑会从 `192.168.68.10` 请求严格区分大小写的
`JDCOS.bin`，写入 `firmware` 分区，并在完成后自动重启。期间：

- 不要断电、拔网线、关闭 TFTP 服务或操作复位键。
- 不要执行整片 NOR 的 `erase`、`cp.b` 或其他手工写入命令。
- 不要写入或擦除 U-Boot、Config、Factory。

若 TFTP 没有请求，依次检查服务器地址是否确为 `192.168.68.10/24`、文件名、
文件权限、网线是否接 LAN 口、防火墙和 `journalctl -fu tftpd-hpa` 日志。不要在
原因未明时反复擦写 NOR。

## 7. 首次启动与确认

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

## 8. 停止本地 TFTP 服务

烧录完成后不再需要 TFTP：

```sh
sudo systemctl disable --now tftpd-hpa
sudo ip address del 192.168.68.10/24 dev "$LUBAN_TFTP_IF"
```

保留 `/srv/tftp/JDCOS.bin` 不影响路由器；如不再需要，可在确认备份后手工移除。
