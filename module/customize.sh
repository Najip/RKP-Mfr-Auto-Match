#!/system/bin/sh

ui_print "- Installing RKP Manufacturer Auto-Match (Zygisk)"

set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# Run a module script with the KernelSU BusyBox when it is available, so
# install-time and boot-time behaviour match across root managers.
call_script() {
  if [ -x /data/adb/ksu/bin/busybox ]; then
    /data/adb/ksu/bin/busybox sh "$1" "$2"
  else
    sh "$1" "$2"
  fi
}

LIVE_DIR="/data/adb/modules/rkp_mfr_auto"
REBOOT_FLAG="/data/adb/rkp_mfr_auto.reboot"

# Zygisk backend detection and keybox discovery live in post-fs-data.sh. Running
# it in the read-only --keybox mode keeps install-time and boot-time results in
# sync instead of maintaining a second copy of the detection logic here.
if [ ! -f "$MODPATH/post-fs-data.sh" ]; then
  abort "! post-fs-data.sh missing from the package"
fi
KB_INFO=$(call_script "$MODPATH/post-fs-data.sh" --keybox 2>/dev/null)
ZYGISK_BACKEND=$(printf '%s\n' "$KB_INFO" | sed -n 's/^ZYGISK_BACKEND=//p' | head -n 1)

if [ -z "$ZYGISK_BACKEND" ]; then
  ui_print "! No Zygisk backend detected."
  ui_print "! Install ReZygisk, Zygisk Next, BreZygisk, NeoZygisk, or enable Magisk Zygisk first."
  abort "! Zygisk is required for this module."
fi

ui_print "- Zygisk backend detected: $ZYGISK_BACKEND"

# Old hardcoded RKP modules set the same props; disable them non-destructively
# so both modules do not fight over ro.product.manufacturer.
if [ -d /data/adb/modules/rkp_nubia ] && [ ! -f /data/adb/modules/rkp_nubia/disable ]; then
  touch /data/adb/modules/rkp_nubia/disable 2>/dev/null
  ui_print "! Disabled conflicting module rkp_nubia (re-enable it in your manager if needed)"
fi

# Old builds listed GCam ports / OEM cameras here. Start clean, the next
# boot (or opening the WebUI) re-checks for Pixel Camera only.
: > /data/adb/rkp_mfr_auto.cam_auto 2>/dev/null

# The two prop toggles are gone from the WebUI. Reset them right at install so
# an old "on" value cannot stick around; the debug log choice is kept. Props
# changed by an old toggle only go back on reboot, so ask for one.
OLD_CONF="/data/adb/rkp_mfr_auto.conf"
NEED_REBOOT=0
[ -f "$REBOOT_FLAG" ] && NEED_REBOOT=1
if [ -f "$OLD_CONF" ]; then
  OLD_DBG=0
  grep -q '^DEBUG_LOG=1' "$OLD_CONF" 2>/dev/null && OLD_DBG=1
  if grep -qE '^(SPOOF_VENDOR_MFR|STOCK_GLOBAL_MFR)=1' "$OLD_CONF" 2>/dev/null; then
    ui_print "- Old prop toggle was on, turned it off"
    NEED_REBOOT=1
  fi
  printf 'SPOOF_VENDOR_MFR=0\nSTOCK_GLOBAL_MFR=0\nDEBUG_LOG=%s\n' "$OLD_DBG" > "$OLD_CONF"
  chmod 0644 "$OLD_CONF" 2>/dev/null
fi
# Show the pending reboot on the module card even before hot-apply runs.
[ "$NEED_REBOOT" = "1" ] && touch "$REBOOT_FLAG" 2>/dev/null

# Check if this is an update where native Zygisk .so libraries did NOT change.
# If unchanged, hot-install scripts + webroot directly into LIVE_DIR and clear
# KernelSU's pending update marker so the WebUI stays accessible without a reboot.
IS_FIRST_INSTALL=0
if [ ! -d "$LIVE_DIR" ] || [ "$MODPATH" = "$LIVE_DIR" ]; then
  IS_FIRST_INSTALL=1
fi

CAN_HOT_INSTALL=0
if [ "$IS_FIRST_INSTALL" = "0" ]; then
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

# A Zygisk setting was force-reset (or a reboot was already pending): install
# the normal way so the module card asks for a reboot.
ZYGISK_LIB_SAME="$CAN_HOT_INSTALL"
[ "$NEED_REBOOT" = "1" ] && CAN_HOT_INSTALL=0

if [ "$CAN_HOT_INSTALL" = "1" ]; then
  ui_print "- Zygisk libraries unchanged; hot-installing WebUI & scripts..."
  cp -f "$MODPATH/post-fs-data.sh" "$LIVE_DIR/post-fs-data.sh"
  cp -f "$MODPATH/service.sh" "$LIVE_DIR/service.sh"
  [ -f "$MODPATH/uninstall.sh" ] && cp -f "$MODPATH/uninstall.sh" "$LIVE_DIR/uninstall.sh"
  [ -f "$MODPATH/zygisk/src.sha256" ] && cp -f "$MODPATH/zygisk/src.sha256" "$LIVE_DIR/zygisk/src.sha256"
  chmod 0755 "$LIVE_DIR/post-fs-data.sh" "$LIVE_DIR/service.sh"

  # Swap the WebUI through a staging directory. If staging or the final rename
  # fails, the previous WebUI stays in place instead of being deleted first.
  WEB_NEW="$LIVE_DIR/webroot.new.$$"
  WEB_OLD="$LIVE_DIR/webroot.old.$$"
  rm -rf "$WEB_NEW" "$WEB_OLD"
  if cp -af "$MODPATH/webroot" "$WEB_NEW" 2>/dev/null && [ -f "$WEB_NEW/index.html" ]; then
    [ -d "$LIVE_DIR/webroot" ] && mv "$LIVE_DIR/webroot" "$WEB_OLD" 2>/dev/null
    if mv "$WEB_NEW" "$LIVE_DIR/webroot" 2>/dev/null; then
      rm -rf "$WEB_OLD"
    else
      [ -d "$WEB_OLD" ] && mv "$WEB_OLD" "$LIVE_DIR/webroot" 2>/dev/null
      rm -rf "$WEB_NEW" "$WEB_OLD"
      ui_print "! WebUI swap failed, keeping the previous WebUI"
    fi
  else
    rm -rf "$WEB_NEW"
    ui_print "! Could not stage the new WebUI, keeping the previous WebUI"
  fi

  # module.prop last: the version shown in the manager flips only after the
  # scripts and WebUI have landed.
  cp -f "$MODPATH/module.prop" "$LIVE_DIR/module.prop"
  TARGET_SCRIPT="$LIVE_DIR/post-fs-data.sh"
else
  TARGET_SCRIPT="$MODPATH/post-fs-data.sh"
fi

# KB_INFO was filled by the read-only --keybox run above; reuse it so the
# install-time and boot-time detection results cannot diverge.
KB=$(printf '%s\n' "$KB_INFO" | sed -n 's/^KEYBOX_PATH=//p' | head -n 1)
KS_MODULES=$(printf '%s\n' "$KB_INFO" | sed -n 's/^KEYSTORE_MODULES=//p' | head -n 1)
KS_WARNINGS=$(printf '%s\n' "$KB_INFO" | sed -n 's/^WARNINGS=//p' | head -n 1)

if [ -n "$KS_MODULES" ]; then
  printf '%s\n' "$KS_MODULES" | tr ';' '\n' | while IFS='|' read -r ks_label ks_id ks_state; do
    [ -n "$ks_label" ] || continue
    ui_print "- Keystore module: $ks_label ($ks_state, id=$ks_id)"
  done
fi

case "$KS_WARNINGS" in
  *multi_module*)
    ui_print "! More than one keystore module is enabled, they may conflict"
    ;;
esac

if [ -n "$KB" ]; then
  ui_print "- Found keybox: $KB"
  ui_print "- Preparing RKP manufacturer data..."
  HOT_OUT=$(call_script "$TARGET_SCRIPT" --hot-apply 2>&1)
  ui_print "- $HOT_OUT"
else
  ui_print "- No keybox.xml found yet, import one and reboot"
fi

if [ "$CAN_HOT_INSTALL" = "1" ]; then
  rm -f "$REBOOT_FLAG"
  # Drop the stale "[Reboot pending]" suffix now that no reboot is needed.
  call_script "$TARGET_SCRIPT" --refresh-desc >/dev/null 2>&1
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
  # --mark-reboot touches the flag and refreshes the module description.
  call_script "$TARGET_SCRIPT" --mark-reboot >/dev/null 2>&1 || touch "$REBOOT_FLAG" 2>/dev/null
  if [ "$IS_FIRST_INSTALL" = "1" ]; then
    ui_print "- Reboot required to activate module (first install)"
  elif [ "$NEED_REBOOT" = "1" ] && [ "$ZYGISK_LIB_SAME" = "1" ]; then
    ui_print "- Reboot required, a Zygisk setting was changed"
  else
    ui_print "- Reboot required to load updated Zygisk library"
  fi
fi
