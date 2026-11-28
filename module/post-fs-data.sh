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
  # 1. Built-in NyaZygisk in SukiSU Nova (suppresses external providers in memory when enabled)
  if [ -x /data/adb/ksud ] && [ ! -f /data/adb/ksu/zygisk.json ] && [ ! -f /data/adb/ksu/bin/folkzygisk ]; then
    zs=$(/data/adb/ksud zygisk status 2>/dev/null)
    if printf '%s\n' "$zs" | grep -qiE '"(enabled|fully_active|zygote_injected)"[[:space:]]*:[[:space:]]*true|^[[:space:]]*(enabled|active)[[:space:]]*:[[:space:]]*(true|yes|on|1)\b'; then
      echo "NyaZygisk (built-in)"
      return
    fi
  fi

  # 2. Known external Zygisk provider modules (read module.prop name so forks like BreZygisk show right)
  for pair in \
    "rezygisk|ReZygisk" \
    "zygisksu|Zygisk Next" \
    "brezygisk|BreZygisk" \
    "BreZygisk|BreZygisk" \
    "neozygisk|NeoZygisk" \
    "nyazygisk|NyaZygisk" \
    "yukizygisk|YukiZygisk" \
    "nextzygisk|NextZygisk" \
    "NextZygisk|NextZygisk"
  do
    id="${pair%%|*}"
    label="${pair#*|}"
    d="/data/adb/modules/$id"
    if [ -d "$d" ] && [ ! -f "$d/disable" ] && [ ! -f "$d/remove" ]; then
      mname=""
      [ -f "$d/module.prop" ] && mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      echo "${mname:-$label}"
      return
    fi
  done

  # 3. Built-in Magisk Zygisk (Magisk and forks)
  if command -v magisk >/dev/null 2>&1; then
    ZVAL=$(magisk --sqlite "SELECT value FROM settings WHERE key='zygisk';" 2>/dev/null | sed 's/.*=//')
    if [ "$ZVAL" = "1" ]; then
      echo "Magisk Zygisk"
      return
    fi
  fi

  # 4. Built-in FolkZygisk in FinaSU (stands down automatically when an external provider is active)
  if [ -f /data/adb/ksu/zygisk.json ] && grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' /data/adb/ksu/zygisk.json 2>/dev/null; then
    echo "FolkZygisk (built-in)"
    return
  fi

  # 5. Built-in YukiZygisk in YukiSU
  if [ -x /data/adb/ksud ]; then
    yz=$(/data/adb/ksud yzctl status --json 2>/dev/null)
    if printf '%s\n' "$yz" | grep -qiE '"(enabled|feature_enabled|injected)"[[:space:]]*:[[:space:]]*true|"zygote"[[:space:]]*:[[:space:]]*"injected"'; then
      echo "YukiZygisk (built-in)"
      return
    fi
  fi
  if [ -f /data/adb/ksu/yukizygisk/yzconfig.json ] && grep -qE '"enabled"[[:space:]]*:[[:space:]]*true' /data/adb/ksu/yukizygisk/yzconfig.json 2>/dev/null; then
    echo "YukiZygisk (built-in)"
    return
  fi

  # 6. Generic external Zygisk provider scan (skipping consumer modules with zygisk/)
  for d in /data/adb/modules/*; do
    [ -d "$d" ] || continue
    [ -f "$d/disable" ] && continue
    [ -f "$d/remove" ] && continue
    # Skip Zygisk consumer modules (like HMA-OSS) that ship a zygisk/ hooks folder
    [ -d "$d/zygisk" ] && continue
    bname="${d##*/}"
    [ "$bname" = "rkp_mfr_auto" ] && continue
    mname=""
    [ -f "$d/module.prop" ] && mname=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
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

  # 7. Runtime daemon fallback (Zygisk providers running outside /data/adb/modules)
  for proc in zygiskd zygiskd64 zygiskd32 zn-daemon folkzygisk nyazygiskd yukizygiskd; do
    if pidof "$proc" >/dev/null 2>&1; then
      echo "Zygisk (active)"
      return
    fi
  done
  echo ""
}

ZYGISK_BACKEND=$(detect_zygisk_backend)

# Default settings (vendor prop, stock global mode, and debug logging off by default)
SPOOF_VENDOR_MFR=0
STOCK_GLOBAL_MFR=0
DEBUG_LOG=0
# Parse the config instead of sourcing it: only the three known 0/1 keys are
# honoured, so a tampered file cannot execute arbitrary code as root at boot.
if [ -f "$CONF" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      SPOOF_VENDOR_MFR=0|SPOOF_VENDOR_MFR=1) SPOOF_VENDOR_MFR="${line#*=}" ;;
      STOCK_GLOBAL_MFR=0|STOCK_GLOBAL_MFR=1) STOCK_GLOBAL_MFR="${line#*=}" ;;
      DEBUG_LOG=0|DEBUG_LOG=1) DEBUG_LOG="${line#*=}" ;;
    esac
  done < "$CONF"
fi
[ "$DEBUG_LOG" = "1" ] || DEBUG_LOG=0
# The vendor/stock prop toggles are hidden from the WebUI and forced off. Only
# rewrite the config during a boot/apply run: read-only modes (--keybox,
# --status, --list-apps, --export-log...) must not consume the old value before
# customize.sh has seen it.
CONF_NEEDS_RESET=0
if [ -f "$CONF" ] && grep -qE '^(SPOOF_VENDOR_MFR|STOCK_GLOBAL_MFR)=1' "$CONF" 2>/dev/null; then
  CONF_NEEDS_RESET=1
fi
case "$1" in
  ""|--hot-apply)
    if [ "$CONF_NEEDS_RESET" = "1" ]; then
      printf 'SPOOF_VENDOR_MFR=0\nSTOCK_GLOBAL_MFR=0\nDEBUG_LOG=%s\n' "$DEBUG_LOG" > "$CONF" 2>/dev/null
      chmod 0644 "$CONF" 2>/dev/null
    fi
    ;;
esac
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

# Read-only check: other enabled modules that set or mention the same props.
# Prints "module|file:line|sets|mentions|text"; nothing is changed.
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
  ' "$1" | {
    rkp_seen=0
    while IFS= read -r b64; do
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
          m="${res#RKP:}"
          if [ -n "$m" ]; then
            printf 'RKP:%s\n' "$m"
            exit 0
          fi
          rkp_seen=1
          ;;
      esac
    done
    # No certificate carried a manufacturer: report the RKP extension once.
    if [ "$rkp_seen" = "1" ]; then
      printf 'RKP:\n'
    fi
    exit 0
  }
}

# ---------------------------------------------------------------------------
# Keystore provider detection and keybox discovery
#
# Supported providers and where they keep the active keybox:
#   Oh My Keymint    id=oh_my_keymint  /data/misc/keystore/omk/keybox.xml
#   TrickyStore      id=tricky_store   /data/adb/tricky_store/keybox.xml
#   TrickyStore OSS  id=tricky_store   /data/adb/tricky_store/keybox.xml (+ [file.xml] in target.txt)
#   TEESimulator-RS  id=tricky_store   /data/adb/tricky_store/keybox.xml (+ [file.xml] in target.txt)
#   TEESimulator     id=teesim         /data/adb/teesim/<keybox from config.json profiles>
#   Unknown / legacy                   /data/adb/TEESimulator/keybox.xml, /data/adb/omk/keybox.xml
#
# A keybox that merely exists on disk must not win over the keybox of the module
# that is actually enabled: a leftover Oh My Keymint keybox on a device that now
# runs TrickyStore used to be parsed first. Enabled modules are therefore
# scanned before disabled ones, and only then legacy paths are tried.
# ---------------------------------------------------------------------------

KB=""
KB_OWNER=""
IS_RKP=0
MFR=""
CHOSEN=0
RKP_MFRS=""
WARNINGS=""
KS_ENTRIES=""
KS_MODULES=""
KS_ENABLED_COUNT=0
KS_PRIMARY=""
TEESIM_MFR_OVERRIDE=""
SEEN_FILE="/data/adb/rkp_mfr_auto.seen.$$"
: > "$SEEN_FILE" 2>/dev/null
trap 'rm -f "$SEEN_FILE" 2>/dev/null' 0

warn() {
  case ";$WARNINGS;" in
    *";$1;"*) ;;
    *) WARNINGS="${WARNINGS:+$WARNINGS;}$1" ;;
  esac
}

valid_mfr() {
  [ -n "$1" ] || return 1
  [ "${#1}" -le 48 ] || return 1
  printf '%s' "$1" | grep -q '[^A-Za-z0-9._ -]' && return 1
  return 0
}

# Variant of the shared tricky_store id (TrickyStore, OSS, TEESimulator-RS).
ks_tricky_variant() {
  d="$1"
  nm="$2"
  if [ -f "$d/libTrickyStoreOSS.so" ]; then
    echo "TrickyStoreOSS"
    return
  fi
  if [ -f "$d/libcertgen.so" ] || [ -f "$d/supervisor" ]; then
    echo "TEESimulatorRS"
    return
  fi
  case "$nm" in
    *Tricky*Store*OSS*|*TrickyStore*OSS*) echo "TrickyStoreOSS"; return ;;
    *TEESimulator*RS*|*TEESimulator-RS*) echo "TEESimulatorRS"; return ;;
    *TEESimulator*|*TEESim*) echo "TEESimulator"; return ;;
  esac
  echo "TrickyStore"
}

ks_label_from_dir() {
  d="$1"
  id="${d##*/}"
  nm=""
  [ -f "$d/module.prop" ] && nm=$(grep -iE '^name=' "$d/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
  # Known module ids are authoritative.
  case "$id" in
    oh_my_keymint) echo "OhMyKeymint"; return ;;
    teesim) echo "TEESimulator"; return ;;
    tricky_store) ks_tricky_variant "$d" "$nm"; return ;;
  esac
  # Forks with a custom id need a provider-specific file or an exact name.
  # Deliberately no bare "*OSS*" match: HMA-OSS Zygisk and other consumer
  # modules used to be mistaken for TrickyStore OSS and could win the keybox
  # selection over the keystore module that is actually installed.
  [ -f "$d/libTrickyStoreOSS.so" ] && { echo "TrickyStoreOSS"; return; }
  if [ -f "$d/libcertgen.so" ] || [ -f "$d/supervisor" ]; then
    echo "TEESimulatorRS"
    return
  fi
  [ -f "$d/libTrickyStore.so" ] && { echo "TrickyStore"; return; }
  case "$nm" in
    *Tricky*Store*OSS*|*TrickyStore*OSS*) echo "TrickyStoreOSS"; return ;;
    *TEESimulator*RS*|*TEESimulator-RS*) echo "TEESimulatorRS"; return ;;
    *TEESimulator*|*TEESim*) echo "TEESimulator"; return ;;
    *Tricky*Store*|*TrickyStore*) echo "TrickyStore"; return ;;
    *Oh*Keymint*|*OhMyKeymint*) echo "OhMyKeymint"; return ;;
  esac
  echo ""
}

ks_display_name() {
  fam="$1"
  d="$2"
  prop="$d/module.prop"
  nm=""
  au=""
  uj=""
  if [ -f "$prop" ]; then
    nm=$(grep -iE '^name=' "$prop" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r|;' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    au=$(grep -iE '^author=' "$prop" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r|;' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    uj=$(grep -iE '^updateJson=' "$prop" 2>/dev/null | head -n 1 | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  fi
  [ -n "$nm" ] || nm="$fam"

  # Extract GitHub owner from updateJson if present
  owner=""
  case "$uj" in
    *raw.githubusercontent.com/*)
      owner=$(printf '%s' "$uj" | sed -n 's|.*raw\.githubusercontent\.com/\([^/]*\)/.*|\1|p')
      ;;
    *github.com/*)
      owner=$(printf '%s' "$uj" | sed -n 's|.*github\.com/\([^/]*\)/.*|\1|p')
      ;;
  esac

  # Check if owner or trailing author differs from canonical upstream
  tag=""
  if [ -n "$owner" ]; then
    ol=$(printf '%s' "$owner" | tr 'A-Z' 'a-z')
    is_up=0
    case "$fam:$ol" in
      OhMyKeymint:qwq233|OhMyKeymint:clef-j|OhMyKeymint:jamesclef|OhMyKeymint:ohmykeymint) is_up=1 ;;
      TrickyStore:5ec1cff|TrickyStore:avmm) is_up=1 ;;
      TrickyStoreOSS:beakthoven|TrickyStoreOSS:trickystoreoss|TrickyStoreOSS:5ec1cff) is_up=1 ;;
      TEESimulator:jingmatrix) is_up=1 ;;
      TEESimulatorRS:enginex0|TEESimulatorRS:jingmatrix|TEESimulatorRS:teesimulator|TEESimulatorRS:engstk) is_up=1 ;;
    esac
    [ "$is_up" = "0" ] && tag="$owner"
  fi

  if [ -z "$tag" ] && [ -n "$au" ]; then
    # If author is comma/slash-separated (e.g. "James Clef,ITxiao6666"), check the last entry
    last_au=$(printf '%s' "$au" | awk -F'[,/&]' '{s=$NF; gsub(/^[ \t]+|[ \t]+$/, "", s); print s}')
    al=$(printf '%s' "$last_au" | tr 'A-Z' 'a-z')
    is_up=0
    case "$fam:$al" in
      OhMyKeymint:"james clef"|OhMyKeymint:jamesclef|OhMyKeymint:clef-j|OhMyKeymint:qwq233) is_up=1 ;;
      TrickyStore:5ec1cff|TrickyStore:avmm) is_up=1 ;;
      TrickyStoreOSS:beakthoven|TrickyStoreOSS:5ec1cff|TrickyStoreOSS:"beakthoven & 5ec1cff") is_up=1 ;;
      TEESimulator:jingmatrix) is_up=1 ;;
      TEESimulatorRS:enginex0|TEESimulatorRS:jingmatrix|TEESimulatorRS:engstk) is_up=1 ;;
    esac
    [ "$is_up" = "0" ] && [ -n "$last_au" ] && tag="$last_au"
  fi

  if [ -n "$tag" ]; then
    nml=$(printf '%s' "$nm" | tr 'A-Z' 'a-z')
    tgl=$(printf '%s' "$tag" | tr 'A-Z' 'a-z')
    case "$nml" in
      *"$tgl"*) echo "$nm" ;;
      *) echo "$nm ($tag)" ;;
    esac
  else
    echo "$nm"
  fi
}

scan_ks_dirs() {
  seen_ids=""
  for base in /data/adb/modules /data/adb/modules_update; do
    [ -d "$base" ] || continue
    for d in "$base"/*; do
      [ -d "$d" ] || continue
      id="${d##*/}"
      case ";$seen_ids;" in
        *";$id;"*) continue ;;
      esac
      label=$(ks_label_from_dir "$d")
      [ -n "$label" ] || continue
      seen_ids="$seen_ids;$id"
      disp=$(ks_display_name "$label" "$d")
      en=1
      if [ -f "$d/disable" ] || [ -f "$d/remove" ]; then en=0; fi
      case "$label" in
        TEESimulator|TEESimulatorRS|TrickyStore|TrickyStoreOSS) w=5 ;;
        OhMyKeymint) w=4 ;;
        *) w=3 ;;
      esac
      # entry layout: weight|family|enabled|module_dir
      KS_ENTRIES="$KS_ENTRIES ${w}|${label}|${en}|${d}"
      if [ "$en" = "1" ]; then
        KS_ENABLED_COUNT=$((KS_ENABLED_COUNT + 1))
        KS_MODULES="${KS_MODULES}${disp}|${id}|enabled;"
      else
        KS_MODULES="${KS_MODULES}${disp}|${id}|disabled;"
      fi
    done
  done
}

# Read every value of a JSON string key ("keybox", "manufacturer", ...) without jq.
teesim_json_values() {
  awk -v key="$1" '
    {
      line = $0
      pat = "\"" key "\"[ \t]*:[ \t]*\"[^\"]*\""
      while (match(line, pat) > 0) {
        s = substr(line, RSTART, RLENGTH)
        sub(/.*:[ \t]*"/, "", s)
        sub(/"$/, "", s)
        print s
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$2" 2>/dev/null
}

add_mfr_variant() {
  m="$1"
  case ";$RKP_MFRS;" in
    *";$m;"*) ;;
    *) RKP_MFRS="${RKP_MFRS:+$RKP_MFRS;}$m" ;;
  esac
  dlog "keybox: RKP map[3]=$m from $2"
}

try_keybox() {
  f="$1"
  owner="$2"
  choose="${3:-1}"
  [ -n "$f" ] || return 0
  [ -f "$f" ] || return 0
  if [ -f "$SEEN_FILE" ] && grep -Fxq "$f" "$SEEN_FILE" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$f" >> "$SEEN_FILE" 2>/dev/null
  out=$(parse_keybox "$f")
  case "$out" in
    RKP:*)
      m="${out#RKP:}"
      m=$(printf '%s' "$m" | tr -d '\r\n\t' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      if [ -n "$m" ] && ! valid_mfr "$m"; then
        warn bad_mfr
        dlog "keybox: rejected unsafe map[3] value in $f"
        m=""
      fi
      [ -n "$m" ] && add_mfr_variant "$m" "$f"
      if [ "$choose" = "1" ] && [ "$CHOSEN" = "0" ]; then
        if [ -n "$m" ]; then
          KB="$f"; KB_OWNER="$owner"; MFR="$m"; IS_RKP=1; CHOSEN=1
        elif [ -z "$KB" ]; then
          KB="$f"; KB_OWNER="$owner"; IS_RKP=1
        fi
      fi
      ;;
    *)
      if [ "$choose" = "1" ] && [ "$CHOSEN" = "0" ] && [ -z "$KB" ]; then
        KB="$f"; KB_OWNER="$owner"; IS_RKP=0
      fi
      ;;
  esac
}

discover_module_keyboxes() {
  fam="$1"
  owner_disp="$2"
  choose="${3:-1}"
  case "$fam" in
    TEESimulator)
      cfg="/data/adb/teesim/config.json"
      if [ -f "$cfg" ]; then
        while IFS= read -r alt; do
          [ -n "$alt" ] || continue
          case "$alt" in
            /*) try_keybox "$alt" "$owner_disp" "$choose" ;;
            *)  try_keybox "/data/adb/teesim/$alt" "$owner_disp" "$choose" ;;
          esac
        done <<EOF
$(teesim_json_values keybox "$cfg")
EOF
        while IFS= read -r mfr; do
          [ -n "$mfr" ] || continue
          TEESIM_MFR_OVERRIDE="${TEESIM_MFR_OVERRIDE:+$TEESIM_MFR_OVERRIDE;}$mfr"
        done <<EOF
$(teesim_json_values manufacturer "$cfg")
EOF
      fi
      try_keybox "/data/adb/teesim/keybox.xml" "$owner_disp" "$choose"
      ;;
    TrickyStore|TrickyStoreOSS|TEESimulatorRS)
      try_keybox "/data/adb/tricky_store/keybox.xml" "$owner_disp" "$choose"
      if [ -f /data/adb/tricky_store/target.txt ]; then
        while IFS= read -r alt; do
          [ -n "$alt" ] || continue
          case "$alt" in
            /*) try_keybox "$alt" "$owner_disp" "$choose" ;;
            *)  try_keybox "/data/adb/tricky_store/$alt" "$owner_disp" "$choose" ;;
          esac
        done <<EOF
$(awk -F'[][]' '/^[ \t]*\[[^]]+\.xml\][ \t]*$/ {print $2}' /data/adb/tricky_store/target.txt 2>/dev/null)
EOF
      fi
      for alt in /data/adb/tricky_store/*.xml; do
        [ -f "$alt" ] && try_keybox "$alt" "$owner_disp" "$choose"
      done
      ;;
    OhMyKeymint)
      try_keybox "/data/misc/keystore/omk/keybox.xml" "$owner_disp" "$choose"
      try_keybox "/data/adb/omk/keybox.xml" "$owner_disp" "$choose"
      ;;
  esac
}

scan_ks_dirs

# The highest-priority enabled module is authoritative: only its keyboxes may be
# applied. Keyboxes of any other enabled module are parsed for conflict reporting
# but never override the active module. Disabled modules contribute nothing.
for weight in 5 4 3; do
  for entry in $KS_ENTRIES; do
    e_w="${entry%%|*}"
    e_rest="${entry#*|}"
    [ "$e_w" = "$weight" ] || continue
    e_label="${e_rest%%|*}"
    e_rest="${e_rest#*|}"
    e_en="${e_rest%%|*}"
    e_dir="${e_rest#*|}"
    [ "$e_en" = "1" ] || continue
    e_disp=$(ks_display_name "$e_label" "$e_dir")
    if [ -z "$KS_PRIMARY" ]; then
      KS_PRIMARY="$e_disp"
      discover_module_keyboxes "$e_label" "$e_disp" 1
    else
      discover_module_keyboxes "$e_label" "$e_disp" 0
    fi
  done
done

# Nothing recognisable installed: keep supporting unknown forks by path only.
if [ -z "$KS_ENTRIES" ]; then
  warn unknown_setup
  for f in /data/adb/teesim/keybox.xml /data/adb/tricky_store/keybox.xml \
           /data/adb/TEESimulator/keybox.xml /data/adb/omk/keybox.xml \
           /data/misc/keystore/omk/keybox.xml; do
    try_keybox "$f" "Unknown"
  done
fi

[ "$KS_ENABLED_COUNT" -gt 1 ] && warn multi_module
[ -n "$KS_ENTRIES" ] && [ "$KS_ENABLED_COUNT" -eq 0 ] && warn module_disabled

case "$RKP_MFRS" in
  *";"*) warn mfr_conflict ;;
esac

if [ -n "$TEESIM_MFR_OVERRIDE" ] && [ -n "$MFR" ]; then
  case ";$TEESIM_MFR_OVERRIDE;" in
    *";$MFR;"*) ;;
    *) warn teesim_mfr_override ;;
  esac
fi

detect_apps() {
  PKGS=$(pm list packages 2>/dev/null | sed 's/^package://')
  [ -z "$PKGS" ] && return
  # Reuse the same package list in detect_pixel_camera instead of calling pm twice.
  PKGS_CACHE="$PKGS"

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
  NEED_REBOOT=0
  [ -f "$REBOOT_FLAG" ] && NEED_REBOOT=1
  if [ "$DEBUG_LOG" = "1" ] && [ -f /dev/.rkp_mfr_auto_boot_dbg ]; then
    BDBG=$(head -n 1 /dev/.rkp_mfr_auto_boot_dbg 2>/dev/null)
    [ "$BDBG" = "0" ] && NEED_REBOOT=1
  fi
  OWNER_STR=""
  if [ -n "$KB_OWNER" ]; then
    OWNER_STR=" | ${KB_OWNER}"
  elif [ -n "$KS_PRIMARY" ]; then
    OWNER_STR=" | ${KS_PRIMARY}"
  fi
  if [ -z "$ZYGISK_BACKEND" ]; then
    DESC="❌ Error: Zygisk missing — install ReZygisk, Zygisk Next, BreZygisk, or Magisk Zygisk"
  elif [ -z "$KB" ]; then
    DESC="❌ Error: No keybox found (${ZYGISK_BACKEND}${OWNER_STR}) — waiting for keybox.xml"
  elif [ "$IS_RKP" -eq 1 ] && [ -z "$MFR" ]; then
    DESC="❌ Error: RKP keybox has no valid manufacturer (${ZYGISK_BACKEND}${OWNER_STR})"
  elif [ "$IS_RKP" -eq 1 ] && [ -z "$RP" ]; then
    DESC="❌ Error: resetprop not found (${ZYGISK_BACKEND}${OWNER_STR})"
  elif [ "$NEED_REBOOT" = "1" ]; then
    if [ "$IS_RKP" -eq 0 ]; then
      DESC="🔁 Needs reboot — Standby, non-RKP keybox (${ZYGISK_BACKEND}${OWNER_STR})"
    else
      DESC="🔁 Needs reboot — ${ZYGISK_BACKEND} | RKP: ${MFR}${OWNER_STR}"
    fi
  elif [ "$IS_RKP" -eq 0 ]; then
    IDLE_IDX_FILE="/dev/.rkp_mfr_auto_idle_idx"
    if [ ! -f "$IDLE_IDX_FILE" ]; then
      SEED=$(( $(date '+%s' 2>/dev/null || echo 0) + $$ ))
      printf '%s\n' "$((SEED % 4))" > "$IDLE_IDX_FILE" 2>/dev/null
    fi
    IDLE_IDX=$(head -n 1 "$IDLE_IDX_FILE" 2>/dev/null)
    case "$IDLE_IDX" in
      1) DESC="☕ Idle — Standard keybox, taking a break (${ZYGISK_BACKEND}${OWNER_STR})" ;;
      2) DESC="🛡️ All good — Non-RKP keybox, no spoofing needed (${ZYGISK_BACKEND}${OWNER_STR})" ;;
      3) DESC="🌙 Resting — Non-RKP keybox, nothing to spoof (${ZYGISK_BACKEND}${OWNER_STR})" ;;
      *) DESC="💤 Standby — Non-RKP keybox, nothing to spoof (${ZYGISK_BACKEND}${OWNER_STR})" ;;
    esac
  else
    DESC="✅ Active — ${ZYGISK_BACKEND} | RKP: ${MFR}${OWNER_STR} (Pixel Camera excluded)"
  fi
  TMP_PROP="${MODPROP}.$$.tmp"
  if awk -v d="$DESC" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done) print "description=" d}' "$MODPROP" > "$TMP_PROP" 2>/dev/null; then
    cmp -s "$TMP_PROP" "$MODPROP" || mv "$TMP_PROP" "$MODPROP"
  fi
  rm -f "$TMP_PROP" 2>/dev/null
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
  PKGS_ALL="$PKGS_CACHE"
  if [ -z "$PKGS_ALL" ]; then
    PKGS_ALL=$(pm list packages 2>/dev/null | sed 's/^package://')
  fi
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

  printf '%s' "$OUT" > "${CAM_AUTO_FILE}.$$.tmp" 2>/dev/null
  mv "${CAM_AUTO_FILE}.$$.tmp" "$CAM_AUTO_FILE" 2>/dev/null
  chmod 0644 "$CAM_AUTO_FILE" 2>/dev/null
}

if [ "$1" = "--scan-cams" ]; then
  detect_pixel_camera
  exit 0
fi

emit_diag_log() {
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
    echo "KEYSTORE_MODULE=${KB_OWNER:-${KS_PRIMARY:-none}}"
    echo "KEYSTORE_MODULES=${KS_MODULES:-none}"
    echo "KEYBOX_PATH=${KB:-none}"
    echo "IS_RKP=$IS_RKP"
    echo "RKP_MFR=${MFR:-none}"
    echo "RKP_MFRS=${RKP_MFRS:-none}"
    echo "WARNINGS=${WARNINGS:-none}"
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
}

# --export-log        private root-only copy (0600) used by the WebUI by default
# --export-log-public explicit copy to shared storage after the user confirms
if [ "$1" = "--export-log" ] || [ "$1" = "--export-log-public" ]; then
  TS=$(date '+%Y%m%d_%H%M%S' 2>/dev/null || echo "latest")
  if [ "$1" = "--export-log" ]; then
    OUT_DIR="/data/adb/rkp_mfr_auto_export"
    mkdir -p "$OUT_DIR" 2>/dev/null
    chmod 0700 "$OUT_DIR" 2>/dev/null
  else
    OUT_DIR="/sdcard/Download"
    [ -d "$OUT_DIR" ] || OUT_DIR="/storage/emulated/0/Download"
    mkdir -p "$OUT_DIR" 2>/dev/null
  fi
  OUT_FILE="$OUT_DIR/rkp_mfr_auto_log_${TS}.txt"
  emit_diag_log > "$OUT_FILE" 2>/dev/null
  [ "$1" = "--export-log" ] && chmod 0600 "$OUT_FILE" 2>/dev/null
  if [ -f "$OUT_FILE" ]; then
    echo "$OUT_FILE"
    exit 0
  fi
  echo "Failed to write $OUT_FILE" >&2
  exit 1
fi

if [ "$1" = "--issue-info" ]; then
  MOD_VER=$(grep -E '^version=' "$MODPROP" 2>/dev/null | head -n 1 | cut -d= -f2-)
  BRAND=$(getprop ro.product.brand 2>/dev/null)
  MODEL=$(getprop ro.product.model 2>/dev/null)
  DEV=$(getprop ro.product.device 2>/dev/null)
  AREL=$(getprop ro.build.version.release 2>/dev/null)
  ASDK=$(getprop ro.build.version.sdk 2>/dev/null)
  ROM=""
  for rp in ro.miui.ui.version.name ro.pixelos.version ro.lineage.version ro.crdroid.version ro.evolution.version ro.modversion ro.build.display.id; do
    rv=$(getprop "$rp" 2>/dev/null)
    if [ -n "$rv" ]; then
      ROM="$rv"
      break
    fi
  done
  DEV_STR="$MODEL"
  case "$MODEL" in
    "$BRAND"*) ;;
    *) [ -n "$BRAND" ] && DEV_STR="$BRAND $MODEL" ;;
  esac
  [ -n "$DEV" ] && DEV_STR="$DEV_STR ($DEV)"
  [ -n "$ROM" ] && DEV_STR="$DEV_STR, $ROM"
  [ -n "$AREL" ] && DEV_STR="$DEV_STR, Android $AREL${ASDK:+ (SDK $ASDK)}"

  ROOT_STR="unknown"
  if [ -x /data/adb/ksud ]; then
    KV=$(/data/adb/ksud -V 2>/dev/null | head -n 1)
    if [ -x /data/adb/ksu/bin/folkzygisk ] || [ -f /data/adb/ksu/zygisk.json ]; then
      ROOT_STR="FinaSU${KV:+ ($KV)}"
    elif [ -d /data/adb/ksu/yukizygisk ]; then
      ROOT_STR="YukiSU${KV:+ ($KV)}"
    elif /data/adb/ksud zygisk status >/dev/null 2>&1; then
      ROOT_STR="SukiSU${KV:+ ($KV)}"
    else
      ROOT_STR="KernelSU${KV:+ ($KV)}"
    fi
  elif [ -x /data/adb/apd ]; then
    AV=$(/data/adb/apd -V 2>/dev/null | head -n 1)
    ROOT_STR="APatch${AV:+ ($AV)}"
  elif command -v magisk >/dev/null 2>&1; then
    MV=$(magisk -v 2>/dev/null | head -n 1)
    ROOT_STR="Magisk${MV:+ ($MV)}"
  fi

  TEE_STR=""
  if [ -n "$KS_MODULES" ]; then
    TEE_STR=$(printf '%s\n' "$KS_MODULES" | tr ';' '\n' | while IFS='|' read -r kl ki ks; do
      [ -n "$kl" ] || continue
      printf '%s (%s), ' "$kl" "$ks"
    done | sed 's/, $//')
  fi
  for pdir in /data/adb/modules/*; do
    [ -d "$pdir" ] || continue
    [ -f "$pdir/disable" ] && continue
    [ -f "$pdir/remove" ] && continue
    pid="${pdir##*/}"
    case "$pid" in
      *playintegrity*|*PlayIntegrity*|*pif*|*PIF*)
        pname=$(grep -iE '^name=' "$pdir/module.prop" 2>/dev/null | head -n 1 | cut -d= -f2-)
        [ -n "$pname" ] || pname="$pid"
        case ", $TEE_STR," in
          *", $pname"*) ;;
          *) TEE_STR="${TEE_STR:+$TEE_STR + }$pname" ;;
        esac
        ;;
    esac
  done
  [ -n "$TEE_STR" ] || TEE_STR="none detected"

  echo "VERSION=${MOD_VER:-unknown}"
  echo "DEVICE=$DEV_STR"
  echo "ROOT=$ROOT_STR"
  echo "ZYGISK=${ZYGISK_BACKEND:-none}"
  echo "TEE=$TEE_STR"
  echo "LOG_BEGIN"
  echo "version=${MOD_VER:-unknown}"
  echo "ZYGISK_BACKEND=${ZYGISK_BACKEND:-missing}"
  echo "KEYSTORE_MODULE=${KB_OWNER:-${KS_PRIMARY:-none}}"
  echo "KEYSTORE_MODULES=${KS_MODULES:-none}"
  echo "KEYBOX_PATH=${KB:-none}"
  echo "IS_RKP=$IS_RKP RKP_MFR=${MFR:-none} RKP_MFRS=${RKP_MFRS:-none}"
  echo "WARNINGS=${WARNINGS:-none}"
  echo "REAL_MFR=$(head -n 1 "$REAL_MFR_FILE" 2>/dev/null)"
  echo "CUR_MFR=$(getprop ro.product.manufacturer 2>/dev/null)"
  echo "CUR_VENDOR_MFR=$(getprop ro.product.vendor.manufacturer 2>/dev/null)"
  echo "CUR_ATTEST_MFR=$(getprop ro.product.manufacturer_for_attestation 2>/dev/null)"
  echo "DEBUG_LOG=$DEBUG_LOG RESETPROP=${RP:-none}"
  echo "LAST_LOG=$(head -n 1 "$LOG" 2>/dev/null)"
  CF=$(scan_conflicts)
  if [ -n "$CF" ]; then
    echo "--- Possible Conflicts ---"
    printf '%s\n' "$CF"
  fi
  if [ "$IS_RKP" = "1" ] && [ -n "$MFR" ] && [ -n "$RP" ]; then
    for cp in ro.product.manufacturer ro.product.manufacturer_for_attestation; do
      cv=$(getprop "$cp" 2>/dev/null)
      [ "$cv" != "$MFR" ] && echo "MISMATCH: $cp='$cv' expected='$MFR'"
    done
  fi
  if [ -s "$CAM_AUTO_FILE" ]; then
    echo "--- Auto Cameras ---"
    cat "$CAM_AUTO_FILE"
  fi
  if [ -s "$EXCLUDE_FILE" ]; then
    echo "--- Custom Whitelist ---"
    cat "$EXCLUDE_FILE"
  fi
  if [ -s "$DEBUG_LOG_FILE" ]; then
    echo "--- Debug Log (tail) ---"
    tail -n 35 "$DEBUG_LOG_FILE" 2>/dev/null
  fi
  exit 0
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
    stat -c 'I|%Y|%n' /data/user/0/* 2>/dev/null
    stat -c 'L|%Y|%n' /data/user/0/*/cache /data/user/0/*/code_cache /data/user/0/*/shared_prefs /data/user/0/*/databases 2>/dev/null
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
    $1 == "I" {
      ts = $2 + 0
      p = $3
      sub(/^\/data\/user\/0\//, "", p)
      if (p != "" && ts > inst_ts[p] + 0) inst_ts[p] = ts
      next
    }
    $1 == "L" {
      ts = $2 + 0
      p = $3
      sub(/^\/data\/user\/0\//, "", p)
      sub(/\/.*$/, "", p)
      if (p != "" && ts > used_ts[p] + 0) used_ts[p] = ts
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
        it = (p in inst_ts) ? inst_ts[p] : 0
        ut = (p in used_ts) ? used_ts[p] : it
        printf "%s|%s|%d|%d|%d\n", p, (u ? "user" : "sys"), e, it, ut
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

if [ "$1" = "--refresh-desc" ]; then
  update_module_desc
  exit 0
fi

if [ "$1" = "--restart-apps" ]; then
  shift
  AM_BIN=""
  if command -v am >/dev/null 2>&1; then
    AM_BIN="am"
  elif [ -x /system/bin/am ]; then
    AM_BIN="/system/bin/am"
  fi
  STOPPED=0
  AUTOSTARTED=0
  SEEN_PKGS=" "
  EXTRA_CAMS=""
  if [ -s "$CAM_AUTO_FILE" ]; then
    while IFS= read -r cp; do
      case "$cp" in
        ""|"#"*|*[!a-zA-Z0-9._-]*) continue ;;
      esac
      EXTRA_CAMS="$EXTRA_CAMS $cp"
    done < "$CAM_AUTO_FILE"
  fi
  for pkg in "$@" $EXTRA_CAMS; do
    case "$pkg" in
      ""|*[!a-zA-Z0-9._-]*) continue ;;
    esac
    case "$SEEN_PKGS" in
      *" $pkg "*) continue ;;
    esac
    SEEN_PKGS="${SEEN_PKGS}${pkg} "
    if [ -n "$AM_BIN" ]; then
      "$AM_BIN" force-stop "$pkg" >/dev/null 2>&1
    fi
    rm -rf \
      "/data/user/0/$pkg/cache/"* \
      "/data/user/0/$pkg/code_cache/"* \
      "/data/user_de/0/$pkg/cache/"* \
      "/data/user_de/0/$pkg/code_cache/"* \
      "/sdcard/Android/data/$pkg/cache/"* 2>/dev/null
    STOPPED=$((STOPPED + 1))

    # Only autostart apps that are currently whitelisted and allowed to autostart in background
    IS_WL=0
    if [ -f "$EXCLUDE_FILE" ] && grep -qxF "$pkg" "$EXCLUDE_FILE" 2>/dev/null; then
      IS_WL=1
    fi
    if [ "$IS_WL" = "1" ] && [ -n "$AM_BIN" ]; then
      CAN_AUTO=0
      MIUI_OP=$(appops get "$pkg" 10008 2>/dev/null)
      case "$MIUI_OP" in
        *allow*) CAN_AUTO=1 ;;
        *ignore*|*deny*) CAN_AUTO=0 ;;
        *)
          if dumpsys package "$pkg" 2>/dev/null | grep -q 'android.permission.RECEIVE_BOOT_COMPLETED: granted=true'; then
            BG_OP=$(appops get "$pkg" RUN_IN_BACKGROUND 2>/dev/null)
            case "$BG_OP" in
              *ignore*|*deny*) CAN_AUTO=0 ;;
              *) CAN_AUTO=1 ;;
            esac
          fi
          ;;
      esac
      if [ "$CAN_AUTO" = "1" ]; then
        "$AM_BIN" broadcast -a android.intent.action.BOOT_COMPLETED -p "$pkg" >/dev/null 2>&1 && AUTOSTARTED=$((AUTOSTARTED + 1))
      fi
    fi
    dlog "restart-apps pkg=$pkg wl=$IS_WL autostart=${CAN_AUTO:-0}"
  done
  echo "STOPPED=$STOPPED AUTOSTARTED=$AUTOSTARTED"
  exit 0
fi

if [ "$1" = "--keybox" ]; then
  echo "ZYGISK_BACKEND=$ZYGISK_BACKEND"
  echo "KEYSTORE_MODULE=${KB_OWNER:-${KS_PRIMARY:-}}"
  echo "KEYSTORE_MODULES=$KS_MODULES"
  echo "KEYBOX_PATH=$KB"
  echo "KEYBOX_OWNER=$KB_OWNER"
  echo "IS_RKP=$IS_RKP"
  echo "RKP_MFR=$MFR"
  echo "RKP_MFRS=$RKP_MFRS"
  echo "WARNINGS=$WARNINGS"
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
  BOOT_DBG_FILE="/dev/.rkp_mfr_auto_boot_dbg"
  if [ ! -f "$BOOT_DBG_FILE" ]; then
    printf '%s\n' "$DEBUG_LOG" > "$BOOT_DBG_FILE" 2>/dev/null
  fi
  BOOT_DEBUG_LOG=$(head -n 1 "$BOOT_DBG_FILE" 2>/dev/null)
  [ "$BOOT_DEBUG_LOG" = "1" ] || BOOT_DEBUG_LOG=0
  echo "BOOT_DEBUG_LOG=$BOOT_DEBUG_LOG"
  echo "ZYGISK_BACKEND=$ZYGISK_BACKEND"
  echo "PENDING_REBOOT=$PENDING_REBOOT"
  echo "KEYSTORE_MODULE=${KB_OWNER:-${KS_PRIMARY:-}}"
  echo "KEYSTORE_MODULES=$KS_MODULES"
  echo "RKP_MFRS=$RKP_MFRS"
  echo "WARNINGS=$WARNINGS"
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
  echo "Keystore module: ${KB_OWNER:-${KS_PRIMARY:-none}}"
  echo "Keystore modules: ${KS_MODULES:-none}"
  echo "Keybox: ${KB:-none}"
  echo "RKP keybox: $IS_RKP"
  echo "Detected RKP map[3]: ${MFR:-none}"
  echo "Other RKP manufacturers: ${RKP_MFRS:-none}"
  echo "Warnings: ${WARNINGS:-none}"
  echo "Spoof vendor manufacturer: $SPOOF_VENDOR_MFR"
  exit 0
fi

# Clear pending-reboot flag and record boot-time debug log state on normal boot
if [ "$1" != "--hot-apply" ]; then
  rm -f "$REBOOT_FLAG"
  printf '%s\n' "$DEBUG_LOG" > /dev/.rkp_mfr_auto_boot_dbg 2>/dev/null
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
  IS_FIRST=0
  [ "$2" = "--first-install" ] && IS_FIRST=1
  HAS_WL=0
  if [ -f "$EXCLUDE_FILE" ] && grep -qE '^[a-zA-Z0-9._-]+$' "$EXCLUDE_FILE" 2>/dev/null; then
    HAS_WL=1
  fi
  CAM_CLEARED=0
  if [ "$IS_FIRST" = "0" ] && [ -s "$CAM_AUTO_FILE" ]; then
    AM_BIN=""
    if command -v am >/dev/null 2>&1; then
      AM_BIN="am"
    elif [ -x /system/bin/am ]; then
      AM_BIN="/system/bin/am"
    fi
    while IFS= read -r cp; do
      case "$cp" in
        ""|"#"*|*[!a-zA-Z0-9._-]*) continue ;;
      esac
      [ -n "$AM_BIN" ] && "$AM_BIN" force-stop "$cp" >/dev/null 2>&1
      rm -rf \
        "/data/user/0/$cp/cache/"* \
        "/data/user/0/$cp/code_cache/"* \
        "/data/user_de/0/$cp/cache/"* \
        "/data/user_de/0/$cp/code_cache/"* \
        "/sdcard/Android/data/$cp/cache/"* 2>/dev/null
      CAM_CLEARED=1
      dlog "hot-apply cleared Pixel Camera cache: $cp"
    done < "$CAM_AUTO_FILE"
  fi
  echo "Zygisk ($ZYGISK_BACKEND): hot-updated mfr=$MFR from $KB" > "$LOG"
  MSG="Updated RKP mfr=$MFR for $ZYGISK_BACKEND"
  EXTRA=""
  if [ "$IS_FIRST" = "0" ]; then
    [ "$CAM_CLEARED" = "1" ] && EXTRA="Pixel Camera restarted & cache cleared"
    if [ "$HAS_WL" = "1" ]; then
      EXTRA="${EXTRA:+$EXTRA; }restart whitelisted apps if needed"
    fi
  fi
  if [ -n "$EXTRA" ]; then
    echo "$MSG ($EXTRA)"
  else
    echo "$MSG"
  fi
else
  echo "Zygisk ($ZYGISK_BACKEND): mfr=$MFR from $KB (per-app, Pixel Camera excluded)" > "$LOG"
fi
