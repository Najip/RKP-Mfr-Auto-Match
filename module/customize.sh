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
else
  ui_print "- No keybox.xml found yet, import one and reboot"
fi
