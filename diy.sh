#!/usr/bin/env bash
set -euo pipefail

device_dts="target/linux/ramips/dts/mt7621_jdcloud_re-cp-02.dts"
device_makefile="target/linux/ramips/image/mt7621.mk"
passwall2_dir="package/passwall2"

test -f "$device_dts"
grep -q "define Device/jdcloud_re-cp-02" "$device_makefile"
grep -q 'reg = <0x90000 0xf70000>;' "$device_dts"
grep -q '&sdhci' "$device_dts"

# Nikki is retained in the repository, but its build checks are disabled.
# test -f "package/nikki/nikki/Makefile"
# test -f "package/nikki/mihomo-meta/Makefile"
# test -f "package/nikki/luci-app-nikki/Makefile"
test -f "$passwall2_dir/luci-app-passwall2/Makefile"

# mirror.iscas.ac.cn accepts connections but can stop transferring indefinitely.
# Drop it before `make download`, and make curl abandon any other zero-speed
# mirror so the downloader can continue with its next configured source.
sed -i '\#https://mirror\.iscas\.ac\.cn/kernel\.org#d' scripts/projectsmirrors.json
sed -i \
  's/curl -f --connect-timeout 5 --retry 3 --location/curl -f --connect-timeout 5 --speed-limit 1024 --speed-time 30 --retry 3 --location/' \
  scripts/download.pl
grep -q -- '--speed-limit 1024 --speed-time 30' scripts/download.pl

echo "Using upstream jdcloud_re-cp-02 support and the pinned PassWall2 submodule."
