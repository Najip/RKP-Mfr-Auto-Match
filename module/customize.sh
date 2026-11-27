#!/system/bin/sh

ui_print "- Installing RKP Manufacturer Auto-Match"

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755

if [ -d /data/adb/modules/rkp_nubia ] && [ ! -f /data/adb/modules/rkp_nubia/disable ]; then
  ui_print "! Old rkp_nubia module found, disable or remove it first"
fi

KB=""
for f in /data/misc/keystore/omk/keybox.xml /data/adb/tricky_store/keybox.xml; do
  if [ -f "$f" ]; then
    KB="$f"
    break
  fi
done

if [ -n "$KB" ]; then
  ui_print "- Found keybox: $KB"
  ui_print "- Running hot-install..."
  if [ -x /data/adb/ksu/bin/busybox ]; then
    HOT_OUT=$(/data/adb/ksu/bin/busybox sh "$MODPATH/post-fs-data.sh" --hot-apply 2>&1)
  else
    HOT_OUT=$(sh "$MODPATH/post-fs-data.sh" --hot-apply 2>&1)
  fi
  ui_print "- $HOT_OUT"
  ui_print "- Note: reboot once so Java Build.* fields also pick it up"
else
  ui_print "- No keybox.xml found yet, import one and reboot"
fi
