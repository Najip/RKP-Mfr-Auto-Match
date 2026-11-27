#!/system/bin/sh
MODDIR="${0%/*}"
LOG="$MODDIR/last.log"
CONF="/data/adb/rkp_mfr_auto.conf"
MFR_FILE="/data/adb/rkp_mfr_auto.mfr"
REBOOT_FLAG="/data/adb/rkp_mfr_auto.reboot"
MODPROP="$MODDIR/module.prop"

detect_zygisk_backend() {
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    bname="${d##*/}"
    case "$bname" in
      rkp_mfr_auto) continue ;;
      rezygisk) echo "ReZygisk"; return ;;
      zygisksu) echo "Zygisk Next"; return ;;
      brezygisk|BreZygisk) echo "BreZygisk"; return ;;
      neozygisk) echo "NeoZygisk"; return ;;
    esac
    if [ -f "$d/module.prop" ]; then
      mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
      case "$(printf '%s %s' "$bname" "$mname" | tr 'A-Z' 'a-z')" in
        *zygisk*)
          echo "${mname:-$bname}"
          return
          ;;
      esac
    fi
  done
  if command -v magisk >/dev/null 2>&1; then
    ZVAL=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk';" 2>/dev/null | sed 's/.*=//')
    if [ "$ZVAL" = "1" ]; then
      echo "Magisk Zygisk"
      return
    fi
  fi
  echo ""
}

ZYGISK_BACKEND=$(detect_zygisk_backend)

# Default settings (vendor prop off by default)
SPOOF_VENDOR_MFR=0
if [ -f "$CONF" ]; then
  . "$CONF"
fi
[ "$SPOOF_VENDOR_MFR" = "1" ] || SPOOF_VENDOR_MFR=0

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

  CAM=""
  for entry in \
    "com.google.android.GoogleCamera|Pixel Camera" \
    "com.google.android.apps.camera.services|Pixel Camera Services"
  do
    pkg="${entry%%|*}"
    label="${entry#*|}"
    if printf '%s\n' "$PKGS" | grep -qx "$pkg"; then
      if [ -n "$CAM" ]; then
        CAM="${CAM};${label}|${pkg}"
      else
        CAM="${label}|${pkg}"
      fi
    fi
  done

  echo "DETECTED_APPS=$FOUND"
  echo "CAMERA_APPS=$CAM"
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
    DESC="[Zygisk: ${ZYGISK_BACKEND} | RKP: ${MFR}] Per-app RKP manufacturer match (camera apps excluded)${PENDING_STR}"
  fi
  awk -v d="$DESC" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done) print "description=" d}' "$MODPROP" > "${MODPROP}.tmp" 2>/dev/null && mv "${MODPROP}.tmp" "$MODPROP"
}

if [ "$1" = "--mark-reboot" ]; then
  touch "$REBOOT_FLAG" 2>/dev/null
  update_module_desc
  exit 0
fi

if [ "$1" = "--status" ]; then
  PENDING_REBOOT=0
  [ -f "$REBOOT_FLAG" ] && PENDING_REBOOT=1
  update_module_desc
  echo "KEYBOX_PATH=$KB"
  echo "IS_RKP=$IS_RKP"
  echo "RKP_MFR=$MFR"
  echo "CUR_MFR=$(getprop ro.product.manufacturer 2>/dev/null)"
  echo "CUR_VENDOR_MFR=$(getprop ro.product.vendor.manufacturer 2>/dev/null)"
  echo "CUR_ATTEST_MFR=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)"
  echo "SPOOF_VENDOR_MFR=$SPOOF_VENDOR_MFR"
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

# Save detected manufacturer for Zygisk companion
printf '%s\n' "$MFR" > "$MFR_FILE"
chmod 0644 "$MFR_FILE" 2>/dev/null

# Keep global ro.product.manufacturer stock so camera apps don't crash.
# Only set manufacturer_for_attestation globally if resetprop is available.
if [ -n "$RP" ]; then
  CUR_A=$(getprop ro.product.manufacturer_for_attestation)
  [ "$CUR_A" != "$MFR" ] && "$RP" -n ro.product.manufacturer_for_attestation "$MFR"
fi

update_module_desc

if [ "$1" = "--hot-apply" ]; then
  echo "Zygisk ($ZYGISK_BACKEND): hot-updated mfr=$MFR from $KB (camera apps excluded)" > "$LOG"
  echo "Updated RKP mfr=$MFR for $ZYGISK_BACKEND (restart target apps; reboot if first install)"
else
  echo "Zygisk ($ZYGISK_BACKEND): mfr=$MFR from $KB (per-app, camera apps excluded)" > "$LOG"
fi
