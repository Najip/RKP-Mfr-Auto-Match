#!/system/bin/sh
MODDIR="${0%/*}"
LOG="$MODDIR/last.log"
CONF="/data/adb/rkp_mfr_auto.conf"

# Default settings
SPOOF_VENDOR_MFR=1
if [ -f "$CONF" ]; then
  . "$CONF"
fi
[ "$SPOOF_VENDOR_MFR" = "0" ] || SPOOF_VENDOR_MFR=1

RP=""
for bin in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /data/adb/magisk/resetprop; do
  if [ -x "$bin" ]; then
    RP="$bin"
    break
  fi
done
[ -n "$RP" ] || RP=$(command -v resetprop 2>/dev/null)

KB=""
for f in /data/misc/keystore/omk/keybox.xml /data/adb/tricky_store/keybox.xml; do
  if [ -f "$f" ]; then
    KB="$f"
    break
  fi
done

IS_RKP=0
MFR=""

if [ -n "$KB" ]; then
  PARSE_OUT=$(awk '
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
  ' "$KB" | while IFS= read -r b64; do
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
  done)

  case "$PARSE_OUT" in
    RKP:*)
      IS_RKP=1
      MFR="${PARSE_OUT#RKP:}"
      ;;
  esac
fi

if [ "$1" = "--status" ]; then
  echo "KEYBOX_PATH=$KB"
  echo "IS_RKP=$IS_RKP"
  echo "RKP_MFR=$MFR"
  echo "CUR_MFR=$(getprop ro.product.manufacturer 2>/dev/null)"
  echo "CUR_VENDOR_MFR=$(getprop ro.product.vendor.manufacturer 2>/dev/null)"
  echo "CUR_ATTEST_MFR=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)"
  echo "SPOOF_VENDOR_MFR=$SPOOF_VENDOR_MFR"
  if [ -f "$LOG" ]; then
    echo "LAST_LOG=$(head -n 1 "$LOG")"
  else
    echo "LAST_LOG="
  fi
  exit 0
fi

if [ "$1" = "--dry-run" ]; then
  echo "Keybox: ${KB:-none}"
  echo "RKP keybox: $IS_RKP"
  echo "Detected RKP map[3]: ${MFR:-none}"
  echo "Spoof vendor manufacturer: $SPOOF_VENDOR_MFR"
  exit 0
fi

if [ -z "$KB" ]; then
  echo "No keybox.xml found" > "$LOG"
  exit 0
fi

if [ "$IS_RKP" -eq 0 ]; then
  echo "Not an RKP keybox ($KB), module not needed" > "$LOG"
  exit 0
fi

if [ -z "$MFR" ]; then
  echo "RKP keybox found but no map[3] manufacturer in $KB" > "$LOG"
  exit 0
fi

if [ -z "$RP" ]; then
  echo "resetprop not found (detected $MFR from $KB)" > "$LOG"
  exit 1
fi

CUR=$(getprop ro.product.manufacturer)
if [ "$CUR" = "$MFR" ]; then
  echo "Already matches ($MFR) from $KB" > "$LOG"
  exit 0
fi

if [ "$SPOOF_VENDOR_MFR" = "1" ]; then
  PROPS="ro.product.manufacturer ro.product.vendor.manufacturer ro.product.manufacturer_for_attestation"
else
  PROPS="ro.product.manufacturer ro.product.manufacturer_for_attestation"
fi

for p in $PROPS; do
  "$RP" -n "$p" "$MFR"
done
echo "Applied RKP manufacturer=$MFR from $KB (was $CUR, vendor_prop=$SPOOF_VENDOR_MFR)" > "$LOG"
