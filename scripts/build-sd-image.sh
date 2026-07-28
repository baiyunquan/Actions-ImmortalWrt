#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "usage: $0 JDCOS_BIN EXTROOT_STAGE OUTPUT_IMAGE" >&2
	exit 2
fi

jdcos_bin="$(realpath "$1")"
extroot_stage="$(realpath "$2")"
output_image="$(realpath -m "$3")"

extroot_uuid="7fdb0d8a-01b5-4ab3-a5ac-431000000002"
p1_start=2048
p1_sectors=204800
p2_start=$((p1_start + p1_sectors))
p2_sectors=$((2 * 1024 * 1024 * 1024 / 512))
disk_sectors=$((p2_start + p2_sectors + 2048))

test -d "$extroot_stage/upper"
test -d "$extroot_stage/work"
test -e "$extroot_stage/upper/etc/luban/extroot-image-ready"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

boot_image="$work_dir/luban-boot.fat"
extroot_image="$work_dir/luban-extroot.ext4"
boot_readme="$work_dir/README.txt"
boot_checksums="$work_dir/SHA256SUMS"

truncate -s $((p1_sectors * 512)) "$boot_image"
mkfs.vfat -F 32 -n LUBANBOOT "$boot_image"

printf '%s\n' \
	"JDCloud RE-CP-02 ImmortalWrt 25.12.1" \
	"" \
	"JDCOS.bin is the SPI-NOR sysupgrade image for the stock U-Boot" \
	"TFTP recovery flow. This card contains a pre-expanded extroot." \
	"Do not write JDCOS.bin over U-Boot, Config, or Factory." > "$boot_readme"

(
	cd "$(dirname "$jdcos_bin")"
	sha256sum "$(basename "$jdcos_bin")"
) > "$boot_checksums"

mcopy -i "$boot_image" "$jdcos_bin" ::/JDCOS.bin
mcopy -i "$boot_image" "$boot_readme" ::/README.txt
mcopy -i "$boot_image" "$boot_checksums" ::/SHA256SUMS
fsck.vfat -vn "$boot_image"

truncate -s $((p2_sectors * 512)) "$extroot_image"
# Positional parameters are intentionally expanded by the inner shell.
# shellcheck disable=SC2016
fakeroot -- sh -c '
	set -e
	chown -R 0:0 "$1"
	mkfs.ext4 -q -F -L luban-extroot -U "$2" -d "$1" "$3"
' sh "$extroot_stage" "$extroot_uuid" "$extroot_image"
e2fsck -fn "$extroot_image"

mkdir -p "$(dirname "$output_image")"
truncate -s $((disk_sectors * 512)) "$output_image"
sfdisk "$output_image" <<EOF
label: gpt
unit: sectors

start=$p1_start, size=$p1_sectors, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="LUBANBOOT"
start=$p2_start, size=$p2_sectors, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="EXTROOT"
EOF

dd if="$boot_image" of="$output_image" bs=512 seek="$p1_start" \
	conv=notrunc,sparse status=none
dd if="$extroot_image" of="$output_image" bs=512 seek="$p2_start" \
	conv=notrunc,sparse status=none

sfdisk --verify "$output_image"
pigz -9 -f "$output_image"
