#!/system/bin/sh

ui_print "- Installing RKP Manufacturer Auto-Match (Zygisk)"

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# Detect Zygisk backend (required)
ZYGISK_BACKEND=""
for pair in \
  "rezygisk|ReZygisk" \
  "zygisksu|Zygisk Next" \
  "brezygisk|BreZygisk" \
  "BreZygisk|BreZygisk" \
  "neozygisk|NeoZygisk"
do
  id="${pair%%|*}"
  label="${pair#*|}"
  d="/data/adb/modules/$id"
  if [ -d "$d" ] && [ ! -f "$d/disable" ] && [ ! -f "$d/remove" ]; then
    ZYGISK_BACKEND="$label"
    break
  fi
done

if [ -z "$ZYGISK_BACKEND" ] && command -v magisk >/dev/null 2>&1; then
  ZVAL=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk';" 2>/dev/null | sed 's/.*=//')
  [ "$ZVAL" = "1" ] && ZYGISK_BACKEND="Magisk Zygisk"
fi

if [ -z "$ZYGISK_BACKEND" ]; then
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    [ -d "$d/zygisk" ] && continue
    bname="${d##*/}"
    [ "$bname" = "rkp_mfr_auto" ] && continue
    if [ -f "$d/module.prop" ]; then
      mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
      case "$(printf '%s %s' "$bname" "$mname" | tr 'A-Z' 'a-z')" in
        *rezygisk*|*zygisksu*|*zygisk*next*|*brezygisk*|*neozygisk*)
          ZYGISK_BACKEND="${mname:-$bname}"
          break
          ;;
      esac
    fi
  done
fi

if [ -z "$ZYGISK_BACKEND" ]; then
  ui_print "! No Zygisk backend detected."
  ui_print "! Install ReZygisk, Zygisk Next, BreZygisk, NeoZygisk, or enable Magisk Zygisk first."
  abort "! Zygisk is required for this module."
fi

ui_print "- Zygisk backend detected: $ZYGISK_BACKEND"

if [ -d /data/adb/modules/rkp_nubia ] && [ ! -f /data/adb/modules/rkp_nubia/disable ]; then
  ui_print "! Old rkp_nubia module found, disable or remove it first"
fi

LIVE_DIR="/data/adb/modules/rkp_mfr_auto"
REBOOT_FLAG="/data/adb/rkp_mfr_auto.reboot"

# Check if this is an update where native Zygisk .so libraries did NOT change.
# If unchanged, hot-install scripts + webroot directly into LIVE_DIR and clear
# KernelSU's pending update marker so the WebUI stays accessible without a reboot.
CAN_HOT_INSTALL=0
if [ -d "$LIVE_DIR" ] && [ "$MODPATH" != "$LIVE_DIR" ]; then
  if [ -f "$LIVE_DIR/zygisk/src.sha256" ] && [ -f "$MODPATH/zygisk/src.sha256" ]; then
    cmp -s "$MODPATH/zygisk/src.sha256" "$LIVE_DIR/zygisk/src.sha256" && CAN_HOT_INSTALL=1
  elif [ -f "$LIVE_DIR/zygisk/arm64-v8a.so" ] && [ -f "$MODPATH/zygisk/arm64-v8a.so" ] && \
       [ -f "$LIVE_DIR/zygisk/armeabi-v7a.so" ] && [ -f "$MODPATH/zygisk/armeabi-v7a.so" ]; then
    if cmp -s "$MODPATH/zygisk/arm64-v8a.so" "$LIVE_DIR/zygisk/arm64-v8a.so" && \
       cmp -s "$MODPATH/zygisk/armeabi-v7a.so" "$LIVE_DIR/zygisk/armeabi-v7a.so"; then
      CAN_HOT_INSTALL=1
    fi
  fi
fi

if [ "$CAN_HOT_INSTALL" = "1" ]; then
  ui_print "- Zygisk libraries unchanged; hot-installing WebUI & scripts..."
  cp -f "$MODPATH/module.prop" "$LIVE_DIR/module.prop"
  cp -f "$MODPATH/post-fs-data.sh" "$LIVE_DIR/post-fs-data.sh"
  cp -f "$MODPATH/service.sh" "$LIVE_DIR/service.sh"
  [ -f "$MODPATH/zygisk/src.sha256" ] && cp -f "$MODPATH/zygisk/src.sha256" "$LIVE_DIR/zygisk/src.sha256"
  chmod 0755 "$LIVE_DIR/post-fs-data.sh" "$LIVE_DIR/service.sh"
  rm -rf "$LIVE_DIR/webroot"
  cp -af "$MODPATH/webroot" "$LIVE_DIR/webroot"
  TARGET_SCRIPT="$LIVE_DIR/post-fs-data.sh"
else
  TARGET_SCRIPT="$MODPATH/post-fs-data.sh"
fi

KB=""
for f in /data/misc/keystore/omk/keybox.xml /data/adb/teesim/keybox.xml /data/adb/tricky_store/keybox.xml /data/adb/omk/keybox.xml /data/adb/TEESimulator/keybox.xml; do
  if [ -f "$f" ]; then
    KB="$f"
    break
  fi
done

if [ -n "$KB" ]; then
  ui_print "- Found keybox: $KB"
  ui_print "- Preparing RKP manufacturer data..."
  if [ -x /data/adb/ksu/bin/busybox ]; then
    HOT_OUT=$(/data/adb/ksu/bin/busybox sh "$TARGET_SCRIPT" --hot-apply 2>&1)
  else
    HOT_OUT=$(sh "$TARGET_SCRIPT" --hot-apply 2>&1)
  fi
  ui_print "- $HOT_OUT"
else
  ui_print "- No keybox.xml found yet, import one and reboot"
fi

if [ "$CAN_HOT_INSTALL" = "1" ]; then
  rm -f "$REBOOT_FLAG"
  # Clear KernelSU's pending update marker right after ksud finishes installing
  (
    sleep 1
    rm -f "$LIVE_DIR/update"
    rm -rf "$MODPATH"
    sleep 1
    rm -f "$LIVE_DIR/update"
  ) >/dev/null 2>&1 &
  ui_print "- Hot-install complete (WebUI ready immediately, no reboot required)"
else
  touch "$REBOOT_FLAG" 2>/dev/null
  ui_print "- Reboot required to load updated Zygisk library"
fi
