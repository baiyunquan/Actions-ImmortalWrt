#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "usage: $0 IMMORTALWRT_DIR EXTROOT_STAGE METADATA_DIR" >&2
	exit 2
fi

source_dir="$(realpath "$1")"
stage_dir="$(realpath -m "$2")"
metadata_dir="$(realpath -m "$3")"

rich_packages=(
	fdisk
	luci-app-firewall
	luci-i18n-firewall-zh-cn
	filebrowser
	luci-app-filebrowser
	luci-i18n-filebrowser-zh-cn
	luci-app-argon-config
	luci-i18n-argon-config-zh-cn
	luci-app-package-manager
	luci-i18n-package-manager-zh-cn
	luci-app-ttyd
	luci-i18n-ttyd-zh-cn
	luci-app-homeproxy
	luci-i18n-homeproxy-zh-cn
	luci-proto-wireguard
	luci-app-tailscale-community
	luci-i18n-tailscale-community-zh-cn
	luci-app-vlmcsd
	luci-i18n-vlmcsd-zh-cn
	luci-app-samba4
	qbittorrent
	luci-app-qbittorrent
	luci-i18n-qbittorrent-zh-cn
	mihomo-meta
	nikki
	luci-app-nikki
	luci-i18n-nikki-zh-cn
)

mkdir -p "$metadata_dir"
rm -rf "$stage_dir"
mkdir -p "$stage_dir/upper" "$stage_dir/work"

cd "$source_dir"
for package_name in "${rich_packages[@]}"; do
	config_key="CONFIG_PACKAGE_${package_name}"
	if grep -Fqx "${config_key}=y" .config; then
		continue
	elif grep -Fqx "${config_key}=m" .config; then
		sed -i "s/^${config_key}=m$/${config_key}=y/" .config
	elif grep -Fqx "# ${config_key} is not set" .config; then
		sed -i "s/^# ${config_key} is not set$/${config_key}=y/" .config
	else
		printf '%s=y\n' "$config_key" >> .config
	fi
done
make defconfig

for package_name in "${rich_packages[@]}"; do
	grep -Fqx "CONFIG_PACKAGE_${package_name}=y" .config || {
		echo "rich rootfs package was not selected: $package_name" >&2
		exit 1
	}
done

# Module builds do not emit the pkginfo/*.install files consumed by
# package/install. Re-run the official package compile target after promoting
# the rich package set to built-in; existing build products are reused while
# the built-in installation metadata is regenerated.
make package/compile -j"$(nproc)" || make package/compile -j1 V=s
make package/install

target_dir="$(make -s --no-print-directory val.TARGET_DIR)"
test -d "$target_dir"
test -x staging_dir/host/bin/apk

apk_args=(
	--root "$target_dir"
	--keys-dir "$source_dir"
	--no-logfile
	--preserve-env
)

for package_name in "${rich_packages[@]}"; do
	IPKG_INSTROOT="$target_dir" staging_dir/host/bin/apk \
		"${apk_args[@]}" info --installed "$package_name" >/dev/null
done

IPKG_INSTROOT="$target_dir" staging_dir/host/bin/apk \
	"${apk_args[@]}" list --quiet --manifest --no-network \
	--repositories-file /dev/null |
	sort > "$metadata_dir/EXTROOT_MANIFEST"

cp .config "$metadata_dir/config.extroot"
cp -a "$target_dir/." "$stage_dir/upper/"
mkdir -p "$stage_dir/upper/etc/luban"
touch "$stage_dir/upper/etc/luban/extroot-image-ready"

test -x "$stage_dir/upper/usr/bin/filebrowser"
test -x "$stage_dir/upper/usr/bin/qbittorrent-nox"
test -e "$stage_dir/upper/etc/init.d/nikki"
test -e "$stage_dir/upper/usr/share/luci/menu.d/luci-app-samba4.json"
