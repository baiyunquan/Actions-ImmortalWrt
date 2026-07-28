#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
	echo "usage: $0 IMMORTALWRT_DIR EXTROOT_STAGE METADATA_DIR OUTPUT_DIR" >&2
	exit 2
fi

source_dir="$(realpath "$1")"
extroot_stage="$(realpath "$2")"
metadata_dir="$(realpath "$3")"
output_dir="$(realpath -m "$4")"
target_dir="$source_dir/bin/targets/ramips/mt7621"
partition_size=$((0xf70000))
fwtool="$source_dir/staging_dir/host/bin/fwtool"
sysupgrade_metadata="$(mktemp)"
trap 'rm -f "$sysupgrade_metadata"' EXIT

sysupgrade_bin="$(find "$target_dir" -maxdepth 1 -type f \
	-name '*jdcloud_re-cp-02-squashfs-sysupgrade.bin' -print -quit)"
nor_manifest="$(find "$target_dir" -maxdepth 1 -type f \
	-name '*jdcloud_re-cp-02*.manifest' -print -quit)"

test -n "$sysupgrade_bin"
test -n "$nor_manifest"
test -x "$fwtool"

sysupgrade_size="$(stat -c %s "$sysupgrade_bin")"
if ((sysupgrade_size > partition_size)); then
	echo "NOR image is larger than the 0xf70000 firmware partition" >&2
	exit 1
fi

for forbidden_package in \
	filebrowser qbittorrent samba4-server sing-box tailscale mihomo-meta nikki; do
	if grep -Eq "^${forbidden_package}([[:space:]-]|$)" "$nor_manifest"; then
		echo "large package leaked into the NOR image: $forbidden_package" >&2
		exit 1
	fi
done

"$fwtool" -i "$sysupgrade_metadata" "$sysupgrade_bin"
grep -q 'jdcloud,re-cp-02' "$sysupgrade_metadata"

rm -rf "$output_dir"
mkdir -p "$output_dir"

cp "$sysupgrade_bin" "$output_dir/JDCOS.bin"
cp "$sysupgrade_metadata" "$output_dir/SYSUPGRADE_METADATA.json"
cp "$nor_manifest" "$output_dir/NOR_MANIFEST"
cp "$metadata_dir/config.nor" "$output_dir/config.nor"
cp "$metadata_dir/config.extroot" "$output_dir/config.extroot"
cp "$metadata_dir/EXTROOT_MANIFEST" "$output_dir/EXTROOT_MANIFEST"
cp "$metadata_dir/IMMORTALWRT_COMMIT" "$output_dir/IMMORTALWRT_COMMIT"
cp "$metadata_dir/FEED_COMMITS" "$output_dir/FEED_COMMITS"
cp "$metadata_dir/NIKKI_COMMIT" "$output_dir/NIKKI_COMMIT"

"$(dirname "$0")/build-sd-image.sh" \
	"$output_dir/JDCOS.bin" \
	"$extroot_stage" \
	"$output_dir/luban-sd-extroot.img"

(
	checksum_file="$(mktemp)"
	trap 'rm -f "$checksum_file"' EXIT
	cd "$output_dir"
	find . -type f -print0 |
		sort -z |
		xargs -0 sha256sum > "$checksum_file"
	mv "$checksum_file" SHA256SUMS
)
