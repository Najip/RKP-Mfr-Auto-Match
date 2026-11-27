#!/system/bin/sh
MODDIR="${0%/*}"
LOG="$MODDIR/last.log"
CONF="/data/adb/rkp_mfr_auto.conf"
MFR_FILE="/data/adb/rkp_mfr_auto.mfr"
REAL_MFR_FILE="/data/adb/rkp_mfr_auto.real_mfr"
EXCLUDE_FILE="/data/adb/rkp_mfr_auto.exclude"
CAM_AUTO_FILE="/data/adb/rkp_mfr_auto.cam_auto"
REBOOT_FLAG="/data/adb/rkp_mfr_auto.reboot"
DEBUG_LOG_FILE="/data/adb/rkp_mfr_auto.log"
MODPROP="$MODDIR/module.prop"

detect_zygisk_backend() {
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
      echo "$label"
      return
    fi
  done
  if command -v magisk >/dev/null 2>&1; then
    ZVAL=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk';" 2>/dev/null | sed 's/.*=//')
    if [ "$ZVAL" = "1" ]; then
      echo "Magisk Zygisk"
      return
    fi
  fi
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    # Skip Zygisk consumer modules (like HMA-OSS) that ship a zygisk/ hooks folder
    [ -d "$d/zygisk" ] && continue
    bname="${d##*/}"
    [ "$bname" = "rkp_mfr_auto" ] && continue
    mname=""
    [ -f "$d/module.prop" ] && mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
    # Structural check: real Zygisk providers ship libzygisk.so or zygiskd/zygisk binaries
    for f in "$d"/lib64/libzygisk*.so "$d"/lib/libzygisk*.so "$d"/bin/*zygisk* "$d"/zygiskd; do
      if [ -f "$f" ]; then
        echo "${mname:-$bname}"
        return
      fi
    done
    # Name fallback for future Zygisk providers (already excluded consumer modules with zygisk/)
    case "$(printf '%s %s' "$bname" "$mname" | tr 'A-Z' 'a-z')" in
      *zygisk*)
        echo "${mname:-$bname}"
        return
        ;;
    esac
  done
  # Runtime daemon fallback (if a Zygisk provider runs outside /data/adb/modules)
  if pidof zygiskd >/dev/null 2>&1 || pidof zygiskd64 >/dev/null 2>&1; then
    echo "Zygisk (active)"
    return
  fi
  echo ""
}

ZYGISK_BACKEND=$(detect_zygisk_backend)

# Default settings (vendor prop, stock global mode, and debug logging off by default)
SPOOF_VENDOR_MFR=0
STOCK_GLOBAL_MFR=0
DEBUG_LOG=0
if [ -f "$CONF" ]; then
  . "$CONF"
fi
[ "$DEBUG_LOG" = "1" ] || DEBUG_LOG=0
# Force vendor prop and stock global mode off (toggles hidden from WebUI; code kept in case needed later)
if grep -qE '^(SPOOF_VENDOR_MFR|STOCK_GLOBAL_MFR)=1' "$CONF" 2>/dev/null; then
  printf 'SPOOF_VENDOR_MFR=0\nSTOCK_GLOBAL_MFR=0\nDEBUG_LOG=%s\n' "$DEBUG_LOG" > "$CONF" 2>/dev/null
  chmod 0644 "$CONF" 2>/dev/null
fi
SPOOF_VENDOR_MFR=0
STOCK_GLOBAL_MFR=0

dlog() {
  [ "$DEBUG_LOG" = "1" ] || return 0
  if [ -f "$DEBUG_LOG_FILE" ]; then
    sz=$(wc -c < "$DEBUG_LOG_FILE" 2>/dev/null || echo 0)
    [ "${sz:-0}" -gt 262144 ] && : > "$DEBUG_LOG_FILE"
  fi
  printf '[%s] [sh] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo boot)" "$*" >> "$DEBUG_LOG_FILE" 2>/dev/null
  chmod 0644 "$DEBUG_LOG_FILE" 2>/dev/null
}

# Read-only check: other enabled modules that set the same manufacturer props.
# Prints "module|file:line|sets or mentions|text". Nothing gets changed.
CONFLICT_RE='ro\.product\.(vendor\.)?manufacturer(_for_attestation)?([^._a-zA-Z0-9]|$)'
scan_conflicts() {
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    id="${d##*/}"
    [ "$id" = "rkp_mfr_auto" ] && continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    for f in "$d"/system.prop "$d"/*.sh "$d"/common/*.sh "$d"/common/system.prop; do
      [ -f "$f" ] || continue
      grep -nE "$CONFLICT_RE" "$f" 2>/dev/null | head -n 5 | while IFS= read -r ln; do
        num="${ln%%:*}"
        txt=$(printf '%s' "${ln#*:}" | tr -d '\r' | sed 's/^[ \t]*//' | cut -c1-120 | tr '|;' '//')
        case "$txt" in
          "#"*) continue ;;
        esac
        kind="mentions"
        case "$f" in
          *system.prop) kind="sets" ;;
        esac
        case "$txt" in
          *resetprop*|*setprop*) kind="sets" ;;
          *getprop*) continue ;;
        esac
        echo "${id}|${f#$d/}:${num}|${kind}|${txt}"
      done
    done
  done
}

RP=""
for bin in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /data/adb/magisk/resetprop; do
  if [ -x "$bin" ]; then
    RP="$bin"
    break
  fi
done
[ -n "$RP" ] || RP=$(command -v resetprop 2>/dev/null)

# Collect candidate keybox paths across OMK, TEESimulator (teesim), TrickyStore / TEESimulator-RS
CANDIDATES="/data/misc/keystore/omk/keybox.xml"

if [ -f /data/adb/teesim/config.json ]; then
  TEESIM_KB=$(sed -n 's/.*"keybox"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /data/adb/teesim/config.json | head -n 1)
  if [ -n "$TEESIM_KB" ]; then
    case "$TEESIM_KB" in
      /*) CANDIDATES="$CANDIDATES $TEESIM_KB" ;;
      *)  CANDIDATES="$CANDIDATES /data/adb/teesim/$TEESIM_KB" ;;
    esac
  fi
fi

CANDIDATES="$CANDIDATES /data/adb/teesim/keybox.xml /data/adb/tricky_store/keybox.xml /data/adb/omk/keybox.xml /data/adb/TEESimulator/keybox.xml"

parse_keybox() {
  awk '
    {
      gsub(/\r/, "")
      while (length($0) > 0) {
        if (!in_cert) {
          p = index($0, "-----BEGIN CERTIFICATE-----")
          if (p == 0) break
          $0 = substr($0, p + 27)
          in_cert = 1
          buf = ""
        } else {
          p = index($0, "-----END CERTIFICATE-----")
          if (p > 0) {
            buf = buf substr($0, 1, p - 1)
            gsub(/[ \t\n]/, "", buf)
            print buf
            $0 = substr($0, p + 25)
            in_cert = 0
            buf = ""
          } else {
            buf = buf $0
            break
          }
        }
      }
    }
  ' "$1" | while IFS= read -r b64; do
    [ -z "$b64" ] && continue
    res=$(printf '%s\n' "$b64" | base64 -d 2>/dev/null | od -An -tx1 -v | awk '
      function hex2dec(h,    i, c, v) {
        v = 0
        for (i = 1; i <= length(h); i++) {
          c = substr(h, i, 1)
          v = v * 16 + index("0123456789abcdef", c) - 1
        }
        return v
      }
      function read_uint(ai,    n, val, k) {
        if (ai < 24) return ai
        if (ai == 24) n = 1
        else if (ai == 25) n = 2
        else if (ai == 26) n = 4
        else if (ai == 27) n = 8
        else return -1
        val = 0
        for (k = 0; k < n; k++) {
          if (pos > total) return -1
          val = val * 256 + b[pos++]
        }
        return val
      }
      function skip_cbor(    ib, mt, ai, len, k) {
        if (pos > total) return 0
        ib = b[pos++]
        mt = int(ib / 32)
        ai = ib % 32
        if (mt == 0 || mt == 1) return (read_uint(ai) >= 0)
        if (mt == 2 || mt == 3) {
          len = read_uint(ai)
          if (len < 0) return 0
          pos += len
          return (pos <= total + 1)
        }
        if (mt == 4) {
          len = read_uint(ai)
          if (len < 0) return 0
          for (k = 0; k < len; k++) if (!skip_cbor()) return 0
          return 1
        }
        if (mt == 5) {
          len = read_uint(ai)
          if (len < 0) return 0
          for (k = 0; k < len; k++) {
            if (!skip_cbor()) return 0
            if (!skip_cbor()) return 0
          }
          return 1
        }
        if (mt == 6) {
          if (read_uint(ai) < 0) return 0
          return skip_cbor()
        }
        if (mt == 7) {
          if (ai < 24) return 1
          if (ai == 24) pos += 1
          else if (ai == 25) pos += 2
          else if (ai == 26) pos += 4
          else if (ai == 27) pos += 8
          else return 0
          return (pos <= total + 1)
        }
        return 0
      }
      {
        for (i = 1; i <= NF; i++) b[++total] = hex2dec(tolower($i))
      }
      END {
        # OID 1.3.6.1.4.1.11129.2.1.30 (RKP Provisioning Information)
        split("6 10 43 6 1 4 1 214 121 2 1 30", oid, " ")
        found_rkp = 0
        for (i = 1; i <= total - 15; i++) {
          ok = 1
          for (j = 1; j <= 12; j++) {
            if (b[i + j - 1] != oid[j] + 0) { ok = 0; break }
          }
          if (!ok) continue
          found_rkp = 1
          pos = i + 12
          if (pos + 2 <= total && b[pos] == 1 && b[pos+1] == 1) pos += 3
          if (pos > total || b[pos] != 4) continue
          pos++
          if (pos > total) continue
          lb = b[pos++]
          if (lb >= 128) pos += (lb - 128)
          if (pos <= total && b[pos] == 4) {
            pos++
            lb = b[pos++]
            if (lb >= 128) pos += (lb - 128)
          }
          if (pos > total) continue
          ib = b[pos++]
          if (int(ib / 32) != 5) continue
          pairs = read_uint(ib % 32)
          if (pairs < 0) continue
          for (p = 0; p < pairs; p++) {
            if (pos > total) break
            kib = b[pos++]
            kmt = int(kib / 32)
            kai = kib % 32
            if (kmt == 0) {
              key = read_uint(kai)
              if (key == 3) {
                if (pos > total) break
                vib = b[pos++]
                if (int(vib / 32) == 3) {
                  vlen = read_uint(vib % 32)
                  if (vlen > 0 && pos + vlen - 1 <= total) {
                    out = ""
                    for (c = 0; c < vlen; c++) out = out sprintf("%c", b[pos + c])
                    print "RKP:" out
                    exit 0
                  }
                }
                break
              } else {
                if (!skip_cbor()) break
              }
            } else {
              pos--
              if (!skip_cbor()) break
              if (!skip_cbor()) break
            }
          }
        }
        if (found_rkp) print "RKP:"
      }
    ')
    case "$res" in
      RKP:*)
        printf '%s\n' "$res"
        break
        ;;
    esac
  done
}

KB=""
IS_RKP=0
MFR=""

for f in $CANDIDATES; do
  [ -f "$f" ] || continue
  PARSE_OUT=$(parse_keybox "$f")
  case "$PARSE_OUT" in
    RKP:*)
      KB="$f"
      IS_RKP=1
      MFR="${PARSE_OUT#RKP:}"
      [ -n "$MFR" ] && break
      ;;
    *)
      [ -z "$KB" ] && KB="$f"
      ;;
  esac
done

detect_apps() {
  PKGS=$(pm list packages 2>/dev/null | sed 's/^package://')
  [ -z "$PKGS" ] && return

  FOUND=""
  for entry in \
    "com.eltavine.duckdetector|Duck Detector" \
    "io.github.vvb2060.keyattestation|Key Attestation" \
    "icu.nullptr.nativetest|Native Detector" \
    "com.reveny.nativecheck|Native Detector (Reveny)" \
    "io.github.vvb2060.mahoshojo|Momo" \
    "com.byxiaorun.detector|Ruru" \
    "io.github.huskydg.memorydetector|Memory Detector" \
    "com.zhenxi.hunter|Hunter"
  do
    pkg="${entry%%|*}"
    label="${entry#*|}"
    if printf '%s\n' "$PKGS" | grep -qx "$pkg"; then
      if [ -n "$FOUND" ]; then
        FOUND="${FOUND};${label}|${pkg}"
      else
        FOUND="${label}|${pkg}"
      fi
    fi
  done

  echo "DETECTED_APPS=$FOUND"
  detect_pixel_camera
  if [ -s "$CAM_AUTO_FILE" ]; then
    echo "PIXEL_CAM=1"
    echo "PIXEL_CAM_REASON=$PIXEL_CAM_REASON"
  else
    echo "PIXEL_CAM=0"
  fi
}

update_module_desc() {
  [ -f "$MODPROP" ] || return
  PENDING_STR=""
  [ -f "$REBOOT_FLAG" ] && PENDING_STR=" [Reboot pending]"
  if [ -z "$ZYGISK_BACKEND" ]; then
    DESC="[Zygisk: Missing] Install ReZygisk, Zygisk Next, BreZygisk, or Magisk Zygisk${PENDING_STR}"
  elif [ -z "$KB" ]; then
    DESC="[Zygisk: ${ZYGISK_BACKEND} | No keybox] Waiting for RKP keybox.xml${PENDING_STR}"
  elif [ "$IS_RKP" -eq 0 ] || [ -z "$MFR" ]; then
    DESC="[Zygisk: ${ZYGISK_BACKEND} | Non-RKP] Module not required for current keybox${PENDING_STR}"
  else
    DESC="[Zygisk: ${ZYGISK_BACKEND} | RKP: ${MFR}] Per-app RKP manufacturer match (Pixel Camera excluded)${PENDING_STR}"
  fi
  awk -v d="$DESC" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done) print "description=" d}' "$MODPROP" > "${MODPROP}.tmp" 2>/dev/null && mv "${MODPROP}.tmp" "$MODPROP"
}

detect_pkg_tool() {
  if command -v pm >/dev/null 2>&1; then
    echo "pm"
  elif [ -x /system/bin/pm ]; then
    echo "/system/bin/pm"
  elif command -v cmd >/dev/null 2>&1; then
    echo "cmd"
  elif [ -x /system/bin/cmd ]; then
    echo "/system/bin/cmd"
  else
    echo "none"
  fi
}

list_packages_raw() {
  tool="$1"
  shift
  case "$tool" in
    pm) pm list packages "$@" 2>/dev/null ;;
    /system/bin/pm) /system/bin/pm list packages "$@" 2>/dev/null ;;
    cmd) cmd package list packages "$@" 2>/dev/null ;;
    /system/bin/cmd) /system/bin/cmd package list packages "$@" 2>/dev/null ;;
  esac
}

# Pixel Camera only. GCam ports and OEM cameras are left alone.
# Fix is applied only when the real Pixel Camera package is installed AND
# the phone is a real Google Pixel or the ROM is Pixel based.
PIXEL_CAM_PKG="com.google.android.GoogleCamera"
PIXEL_CAM_SVC="com.google.android.apps.camera.services"
PIXEL_ROM_PROPS='^\[(ro|net|org)\.(pixelos|pixelexperience|pixel|evolution|evolutionx|elixir|derp|derpfest|infinity|ppui|pixelplusui|yaap|afterlife|pixelextended|blaze|voltage|statix)[._]'
PIXEL_CAM_REASON=""

is_real_pixel() {
  for p in ro.product.system.manufacturer ro.product.odm.manufacturer ro.product.brand ro.product.system.brand; do
    v=$(getprop "$p" 2>/dev/null | tr 'A-Z' 'a-z')
    [ "$v" = "google" ] && return 0
  done
  r=$(head -n 1 "$REAL_MFR_FILE" 2>/dev/null | tr 'A-Z' 'a-z')
  [ "$r" = "google" ] && return 0
  return 1
}

is_pixel_rom() {
  feats=""
  if command -v pm >/dev/null 2>&1; then
    feats=$(pm list features 2>/dev/null)
  elif [ -x /system/bin/pm ]; then
    feats=$(/system/bin/pm list features 2>/dev/null)
  fi
  printf '%s\n' "$feats" | grep -qE 'com\.google\.android\.feature\.PIXEL(_[0-9]{4})?_EXPERIENCE' && return 0
  grep -qsE 'com\.google\.android\.feature\.PIXEL(_[0-9]{4})?_EXPERIENCE' \
    /product/etc/sysconfig/*.xml /system/etc/sysconfig/*.xml /system_ext/etc/sysconfig/*.xml 2>/dev/null && return 0
  # Known Pixel based ROMs by their own props (PixelOS, Pixel Experience,
  # Evolution X, Project Elixir, DerpFest, Infinity-X, PixelPlusUI, YAAP,
  # AfterLife, Pixel Extended, Project Blaze, Voltage, Statix ...)
  getprop 2>/dev/null | grep -qiE "$PIXEL_ROM_PROPS" && return 0
  # Pixel Camera baked into the ROM itself (not sideloaded) = Pixel based ROM
  # (-s still lists it after a Play Store update)
  pm list packages -s 2>/dev/null | grep -qx "package:$PIXEL_CAM_PKG" && return 0
  return 1
}

detect_pixel_camera() {
  PKGS_ALL=$(pm list packages 2>/dev/null | sed 's/^package://')
  # PackageManager not ready yet (early boot): keep the previous result
  [ -z "$PKGS_ALL" ] && return 0

  PIXEL_CAM_REASON=""
  OUT=""
  if printf '%s\n' "$PKGS_ALL" | grep -qx "$PIXEL_CAM_PKG"; then
    if is_real_pixel; then
      PIXEL_CAM_REASON="pixel"
    elif is_pixel_rom; then
      PIXEL_CAM_REASON="pixel_rom"
    fi
    if [ -n "$PIXEL_CAM_REASON" ]; then
      OUT="$PIXEL_CAM_PKG
"
      printf '%s\n' "$PKGS_ALL" | grep -qx "$PIXEL_CAM_SVC" && OUT="${OUT}${PIXEL_CAM_SVC}
"
      dlog "pixel-cam: detected ($PIXEL_CAM_REASON), fix applied"
    else
      dlog "pixel-cam: $PIXEL_CAM_PKG installed but not a Pixel / Pixel based ROM, skipped"
    fi
  fi

  printf '%s' "$OUT" > "${CAM_AUTO_FILE}.tmp" 2>/dev/null
  mv "${CAM_AUTO_FILE}.tmp" "$CAM_AUTO_FILE" 2>/dev/null
  chmod 0644 "$CAM_AUTO_FILE" 2>/dev/null
}

if [ "$1" = "--scan-cams" ]; then
  detect_pixel_camera
  exit 0
fi

if [ "$1" = "--export-log" ]; then
  OUT_DIR="/sdcard/Download"
  [ -d "$OUT_DIR" ] || OUT_DIR="/storage/emulated/0/Download"
  mkdir -p "$OUT_DIR" 2>/dev/null
  TS=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "latest")
  OUT_FILE="$OUT_DIR/rkp_mfr_auto_log_${TS}.txt"
  {
    echo "=== RKP Manufacturer Auto-Match Diagnostic Log ==="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
    if [ -f "$MODPROP" ]; then
      grep -E '^(id|name|version|versionCode)=' "$MODPROP" 2>/dev/null
    fi
    echo "Android: $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
    echo "Device: $(getprop ro.product.brand 2>/dev/null) / $(getprop ro.product.model 2>/dev/null) / $(getprop ro.product.device 2>/dev/null)"
    echo "ABI: $(getprop ro.product.cpu.abi 2>/dev/null)"
    echo ""
    echo "=== Status ==="
    echo "ZYGISK_BACKEND=${ZYGISK_BACKEND:-missing}"
    echo "KEYBOX_PATH=${KB:-none}"
    echo "IS_RKP=$IS_RKP"
    echo "RKP_MFR=${MFR:-none}"
    echo "REAL_MFR=$(head -n 1 "$REAL_MFR_FILE" 2>/dev/null)"
    echo "CUR_MFR=$(getprop ro.product.manufacturer 2>/dev/null)"
    echo "CUR_VENDOR_MFR=$(getprop ro.product.vendor.manufacturer 2>/dev/null)"
    echo "CUR_ATTEST_MFR=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)"
    echo "SPOOF_VENDOR_MFR=$SPOOF_VENDOR_MFR"
    echo "STOCK_GLOBAL_MFR=$STOCK_GLOBAL_MFR"
    echo "DEBUG_LOG=$DEBUG_LOG"
    echo "RESETPROP=${RP:-none}"
    echo "LAST_LOG=$(head -n 1 "$LOG" 2>/dev/null)"
    echo ""
    echo "=== Package Listing Check ==="
    PKG_TOOL=$(detect_pkg_tool)
    U_RAW=$(list_packages_raw "$PKG_TOOL" -3)
    A_RAW=$(list_packages_raw "$PKG_TOOL")
    echo "PKG_TOOL=$PKG_TOOL"
    echo "PATH=$PATH"
    echo "USER_PKG_COUNT=$(printf '%s\n' "$U_RAW" | grep -c '^package:' 2>/dev/null || echo 0)"
    echo "ALL_PKG_COUNT=$(printf '%s\n' "$A_RAW" | grep -c '^package:' 2>/dev/null || echo 0)"
    echo ""
    echo "=== Installed Modules ==="
    for d in /data/adb/modules/*; do
      [ -d "$d" ] || continue
      st="enabled"
      [ -f "$d/disable" ] && st="disabled"
      [ -f "$d/remove" ] && st="remove"
      mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
      has_z="no"
      [ -d "$d/zygisk" ] && has_z="yes"
      echo "${d##*/} | $st | zygisk_dir=$has_z | $mname"
    done
    echo ""
    echo "=== Possible Conflicts (other modules touching manufacturer props) ==="
    CF=$(scan_conflicts)
    if [ -n "$CF" ]; then printf '%s\n' "$CF"; else echo "(none found)"; fi
    if [ "$IS_RKP" = "1" ] && [ -n "$MFR" ] && [ -n "$RP" ]; then
      for cp in ro.product.manufacturer ro.product.manufacturer_for_attestation; do
        cv=$(getprop "$cp" 2>/dev/null)
        [ "$cv" != "$MFR" ] && echo "MISMATCH: $cp is '$cv' but should be '$MFR' (changed after us, or reboot pending)"
      done
    fi
    echo ""
    echo "=== Auto-Detected Cameras ($CAM_AUTO_FILE) ==="
    if [ -f "$CAM_AUTO_FILE" ]; then cat "$CAM_AUTO_FILE"; else echo "(none)"; fi
    echo ""
    echo "=== Custom Whitelist ($EXCLUDE_FILE) ==="
    if [ -f "$EXCLUDE_FILE" ]; then cat "$EXCLUDE_FILE"; else echo "(none)"; fi
    echo ""
    echo "=== Debug Log ($DEBUG_LOG_FILE) ==="
    if [ -f "$DEBUG_LOG_FILE" ]; then cat "$DEBUG_LOG_FILE"; else echo "(empty)"; fi
  } > "$OUT_FILE" 2>/dev/null
  if [ -f "$OUT_FILE" ]; then
    echo "$OUT_FILE"
    exit 0
  else
    echo "Failed to write $OUT_FILE" >&2
    exit 1
  fi
fi

if [ "$1" = "--list-apps" ]; then
  SHOW_ALL=0
  [ "$2" = "all" ] && SHOW_ALL=1
  PKG_TOOL=$(detect_pkg_tool)
  USER_RAW=$(list_packages_raw "$PKG_TOOL" -3)
  ALL_RAW=$(list_packages_raw "$PKG_TOOL")
  if [ "$DEBUG_LOG" = "1" ]; then
    u_cnt=$(printf '%s\n' "$USER_RAW" | grep -c '^package:' 2>/dev/null || echo 0)
    a_cnt=$(printf '%s\n' "$ALL_RAW" | grep -c '^package:' 2>/dev/null || echo 0)
    dlog "list-apps show_all=$SHOW_ALL tool=$PKG_TOOL user_cnt=$u_cnt all_cnt=$a_cnt path=$PATH"
  fi
  {
    printf '%s\n' "$USER_RAW" | sed -n 's/^package:/U|/p'
    printf '%s\n' "$ALL_RAW" | sed -n 's/^package:/A|/p' | sort -u
  } | awk -F'|' -v show_all="$SHOW_ALL" -v efile="$EXCLUDE_FILE" -v cfile="$CAM_AUTO_FILE" '
    BEGIN {
      if (efile != "") {
        while ((getline line < efile) > 0) {
          gsub(/\r/, "", line)
          gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line != "" && substr(line, 1, 1) != "#") is_excl[line] = 1
        }
        close(efile)
      }
      if (cfile != "") {
        while ((getline line < cfile) > 0) {
          gsub(/\r/, "", line)
          gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line != "" && substr(line, 1, 1) != "#") is_cam[line] = 1
        }
        close(cfile)
      }
    }
    $1 == "U" {
      gsub(/\r/, "", $2)
      if ($2 != "") is_user[$2] = 1
      next
    }
    $1 == "A" {
      p = $2
      gsub(/\r/, "", p)
      if (p == "") next
      if (p in is_cam) next
      u = (p in is_user) ? 1 : 0
      e = (p in is_excl) ? 1 : 0
      if (show_all || u || e) {
        printf "%s|%s|%d\n", p, (u ? "user" : "sys"), e
      }
    }
  '
  exit 0
fi

if [ "$1" = "--mark-reboot" ]; then
  touch "$REBOOT_FLAG" 2>/dev/null
  update_module_desc
  exit 0
fi

if [ "$1" = "--status" ]; then
  PENDING_REBOOT=0
  [ -f "$REBOOT_FLAG" ] && PENDING_REBOOT=1
  update_module_desc
  if [ "$DEBUG_LOG" = "1" ]; then
    MODS=""
    for d in /data/adb/modules/*; do
      [ -d "$d" ] || continue
      st="on"
      [ -f "$d/disable" ] && st="off"
      [ -f "$d/remove" ] && st="rm"
      MODS="${MODS} ${d##*/}(${st})"
    done
    dlog "status zygisk=${ZYGISK_BACKEND:-missing} kb=${KB:-none} is_rkp=$IS_RKP mfr=${MFR:-none} rp=${RP:-none} vendor=$SPOOF_VENDOR_MFR"
    dlog "modules:${MODS:- none}"
  fi
  CF=$(scan_conflicts)
  CF_ONE=$(printf '%s' "$CF" | tr '\n' ';')
  PROP_MISMATCH=""
  if [ "$IS_RKP" = "1" ] && [ -n "$MFR" ] && [ -n "$RP" ] && [ "$PENDING_REBOOT" = "0" ]; then
    for cp in ro.product.manufacturer ro.product.manufacturer_for_attestation; do
      cv=$(getprop "$cp" 2>/dev/null)
      [ "$cv" != "$MFR" ] && PROP_MISMATCH="${PROP_MISMATCH}${cp}=${cv};"
    done
  fi
  [ -n "$CF" ] && dlog "conflicts: $CF_ONE"
  [ -n "$PROP_MISMATCH" ] && dlog "prop mismatch (want $MFR): $PROP_MISMATCH"
  echo "CONFLICTS=$CF_ONE"
  echo "PROP_MISMATCH=$PROP_MISMATCH"
  echo "KEYBOX_PATH=$KB"
  echo "IS_RKP=$IS_RKP"
  echo "RKP_MFR=$MFR"
  echo "CUR_MFR=$(getprop ro.product.manufacturer 2>/dev/null)"
  echo "CUR_VENDOR_MFR=$(getprop ro.product.vendor.manufacturer 2>/dev/null)"
  echo "CUR_ATTEST_MFR=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)"
  echo "SPOOF_VENDOR_MFR=$SPOOF_VENDOR_MFR"
  echo "STOCK_GLOBAL_MFR=$STOCK_GLOBAL_MFR"
  echo "DEBUG_LOG=$DEBUG_LOG"
  echo "ZYGISK_BACKEND=$ZYGISK_BACKEND"
  echo "PENDING_REBOOT=$PENDING_REBOOT"
  detect_apps
  if [ -f "$LOG" ]; then
    echo "LAST_LOG=$(head -n 1 "$LOG")"
  else
    echo "LAST_LOG="
  fi
  exit 0
fi

if [ "$1" = "--dry-run" ]; then
  echo "Zygisk backend: ${ZYGISK_BACKEND:-missing}"
  echo "Keybox: ${KB:-none}"
  echo "RKP keybox: $IS_RKP"
  echo "Detected RKP map[3]: ${MFR:-none}"
  echo "Spoof vendor manufacturer: $SPOOF_VENDOR_MFR"
  exit 0
fi

# Clear pending-reboot flag on normal boot
if [ "$1" != "--hot-apply" ]; then
  rm -f "$REBOOT_FLAG"
fi

if [ -z "$ZYGISK_BACKEND" ]; then
  rm -f "$MFR_FILE"
  update_module_desc
  echo "Zygisk backend missing; install ReZygisk / Zygisk Next / BreZygisk / Magisk Zygisk" > "$LOG"
  [ "$1" = "--hot-apply" ] && echo "Zygisk backend missing"
  exit 0
fi

if [ -z "$KB" ]; then
  rm -f "$MFR_FILE"
  update_module_desc
  echo "No keybox.xml found (Zygisk: $ZYGISK_BACKEND)" > "$LOG"
  [ "$1" = "--hot-apply" ] && echo "No keybox.xml found"
  exit 0
fi

if [ "$IS_RKP" -eq 0 ]; then
  rm -f "$MFR_FILE"
  update_module_desc
  echo "Not an RKP keybox ($KB), module not needed (Zygisk: $ZYGISK_BACKEND)" > "$LOG"
  [ "$1" = "--hot-apply" ] && echo "Not an RKP keybox, nothing applied"
  exit 0
fi

if [ -z "$MFR" ]; then
  rm -f "$MFR_FILE"
  update_module_desc
  echo "RKP keybox found but no map[3] manufacturer in $KB (Zygisk: $ZYGISK_BACKEND)" > "$LOG"
  [ "$1" = "--hot-apply" ] && echo "No map[3] manufacturer in keybox"
  exit 0
fi

# Save real stock manufacturer before changing ro.product.manufacturer
REAL_MFR=""
CUR_M=$(getprop ro.product.manufacturer 2>/dev/null)
if [ -n "$CUR_M" ] && [ "$CUR_M" != "$MFR" ]; then
  REAL_MFR="$CUR_M"
elif [ -f "$REAL_MFR_FILE" ]; then
  REAL_MFR=$(head -n 1 "$REAL_MFR_FILE" 2>/dev/null)
fi
if [ -z "$REAL_MFR" ] || [ "$REAL_MFR" = "$MFR" ]; then
  for p in ro.product.system.manufacturer ro.product.odm.manufacturer ro.product.vendor.manufacturer ro.product.system_ext.manufacturer; do
    val=$(getprop "$p" 2>/dev/null)
    if [ -n "$val" ] && [ "$val" != "$MFR" ]; then
      REAL_MFR="$val"
      break
    fi
  done
fi
if [ -n "$REAL_MFR" ]; then
  printf '%s\n' "$REAL_MFR" > "$REAL_MFR_FILE"
  chmod 0644 "$REAL_MFR_FILE" 2>/dev/null
fi

# Save detected manufacturer for status/reference
printf '%s\n' "$MFR" > "$MFR_FILE"
chmod 0644 "$MFR_FILE" 2>/dev/null

# Apply RKP manufacturer via resetprop:
# - Default (STOCK_GLOBAL_MFR=0): set ro.product.manufacturer globally so detectors pass
#   with zero Zygisk maps; Zygisk restores real_mfr for Pixel Camera & whitelisted apps.
# - Stock global mode (STOCK_GLOBAL_MFR=1): keep ro.product.manufacturer stock so DenyList
#   banking/UPI apps stay completely untouched; only set manufacturer_for_attestation globally.
if [ -n "$RP" ]; then
  if [ "$STOCK_GLOBAL_MFR" = "0" ]; then
    [ "$CUR_M" != "$MFR" ] && "$RP" -n ro.product.manufacturer "$MFR"
  fi
  CUR_A=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)
  [ "$CUR_A" != "$MFR" ] && "$RP" -n ro.product.manufacturer_for_attestation "$MFR"
  if [ "$SPOOF_VENDOR_MFR" = "1" ]; then
    CUR_V=$(getprop ro.product.vendor.manufacturer 2>/dev/null)
    [ "$CUR_V" != "$MFR" ] && "$RP" -n ro.product.vendor.manufacturer "$MFR"
  fi
fi

update_module_desc

dlog "apply mode=${1:-boot} zygisk=${ZYGISK_BACKEND:-missing} kb=$KB mfr=$MFR real_mfr=${REAL_MFR:-none} rp=${RP:-none} vendor=$SPOOF_VENDOR_MFR stock_global=$STOCK_GLOBAL_MFR"

if [ "$1" = "--hot-apply" ]; then
  detect_pixel_camera
  echo "Zygisk ($ZYGISK_BACKEND): hot-updated mfr=$MFR from $KB (Pixel Camera excluded)" > "$LOG"
  echo "Updated RKP mfr=$MFR for $ZYGISK_BACKEND (restart target apps; reboot if first install)"
else
  echo "Zygisk ($ZYGISK_BACKEND): mfr=$MFR from $KB (per-app, Pixel Camera excluded)" > "$LOG"
fi
