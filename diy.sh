#!/usr/bin/env bash
set -euo pipefail

device_dts="target/linux/ramips/dts/mt7621_jdcloud_re-cp-02.dts"
device_makefile="target/linux/ramips/image/mt7621.mk"
nikki_dir="package/nikki"

test -f "$device_dts"
grep -q "define Device/jdcloud_re-cp-02" "$device_makefile"
grep -q 'reg = <0x90000 0xf70000>;' "$device_dts"
grep -q '&sdhci' "$device_dts"

test -f "$nikki_dir/nikki/Makefile"
test -f "$nikki_dir/mihomo-meta/Makefile"
test -f "$nikki_dir/luci-app-nikki/Makefile"

echo "Using upstream jdcloud_re-cp-02 support and the pinned Nikki submodule."
