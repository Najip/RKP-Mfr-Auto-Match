#!/system/bin/sh
MODDIR="${0%/*}"

# Wait for PackageManagerService after boot, then check for Pixel Camera (real Pixel / Pixel based ROM only)
# regardless of cloned package names.
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 60 ]; do
  sleep 2
  i=$((i + 1))
done
sleep 3

if [ -x /data/adb/ksu/bin/busybox ]; then
  /data/adb/ksu/bin/busybox sh "$MODDIR/post-fs-data.sh" --scan-cams >/dev/null 2>&1
else
  sh "$MODDIR/post-fs-data.sh" --scan-cams >/dev/null 2>&1
fi
