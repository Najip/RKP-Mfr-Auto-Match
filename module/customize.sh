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
    HOT_OUT=$(/data/adb/ksu/bin/busybox sh "$MODPATH/post-fs-data.sh" --hot-apply 2>&1)
  else
    HOT_OUT=$(sh "$MODPATH/post-fs-data.sh" --hot-apply 2>&1)
  fi
  ui_print "- $HOT_OUT"
  ui_print "- Reboot to load the Zygisk module"
else
  ui_print "- No keybox.xml found yet, import one and reboot"
fi
