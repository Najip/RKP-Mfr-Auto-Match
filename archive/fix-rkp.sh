#!/system/bin/sh
# ==============================================================================
# Universal Cross-Device RKP Manufacturer & Brand Fix (v2.2)
# Kompatibel: Magisk / KernelSU / KSU-Next / SukiSU / APatch (Android 10 - 16)
#
# Fitur:
#   - Mode default SAFE (attestation-only): hanya override *_for_attestation
#     sehingga Pixel Camera (Pixel 8 Pro QPR3+), MIUI Camera, Samsung Camera,
#     dan cameraserver TIDAK crash.
#   - Pilihan mode: safe (default) | vendor | full (untuk HAL legacy)
#   - Guard otomatis perangkat Google Pixel agar mode full tidak membuat Camera crash
#   - Auto-deteksi root manager aktif, OEM multi-kata, keluarga sub-brand
#   - Dual-stage: post-fs-data (sebelum Zygote/KeyMint/rkpd) + service (pasca-boot)
#   - Opsional sinkron otomatis dengan PlayIntegrityFix / Fork (pif.json / pif.prop)
#   - Built-in installer modul (--install) + tombol Action + audit diagnostik
#
# Pemakaian cepat (via root):
#   su -c "sh /storage/emulated/0/Download/fix-rkp.sh --install"
#   su -c "sh /storage/emulated/0/Download/fix-rkp.sh --status"
#   su -c "sh /storage/emulated/0/Download/fix-rkp.sh --mode safe"
#   su -c "sh /storage/emulated/0/Download/fix-rkp.sh --mode full"
#   su -c "sh /storage/emulated/0/Download/fix-rkp.sh --set nubia nubia"
# ==============================================================================

PATH="$PATH:/system/bin:/vendor/bin:/product/bin:/system_ext/bin:/data/data/com.termux/files/usr/bin"

VERSION="2.2"
MOD_ID="rkp_universal_fix"
MOD_DIR="/data/adb/modules/$MOD_ID"
CONF_FILE="${RKP_CONF_FILE:-/data/adb/rkp-fix.conf}"
LOG_FILE="/data/adb/rkp-fix.log"
OEM_CACHE="/dev/.rkp_universal_orig_oem"

# Default konfigurasi (dapat diubah di /data/adb/rkp-fix.conf)
# SPOOF_MODE:
#   safe   = HANYA properti *_for_attestation (REKOMENDASI: anti-crash Camera di Pixel/Stock ROM)
#   vendor = safe + partisi vendor/odm/*_dlkm (tanpa ubah Build.MANUFACTURER sistem)
#   full   = Override global semua partisi + sapu dinamis (berisiko crash Camera di Pixel/Stock)
SPOOF_MODE="safe"
ALLOW_PIXEL_FULL=0
TARGET_MANUFACTURER="nubia"
TARGET_BRAND="nubia"
AUTO_SYNC_PIF=0
SPOOF_ATTESTATION_PROPS=1
EXTRA_SOURCE_PATTERNS=""
LATE_REAPPLY_DELAY=3
ENABLE_LOG=1

# State internal
RESETPROP_BIN=""
RESETPROP_MODE=""
ROOT_MGR="unknown"
DRY_RUN=0
STAGE="manual"
CHANGED_COUNT=0
SKIPPED_HW_COUNT=0
LEAK_COUNT=0
SEEN_PROPS="|"
TMP_PROPS=""
PREV_TARGET_TOKENS=""
EFF_MODE="safe"

# ------------------------------------------------------------------------------
# Utilitas dasar (POSIX sh / Android mksh safe)
# ------------------------------------------------------------------------------
to_lower() {
  printf '%s' "$1" | tr 'A-Z' 'a-z'
}

strip_cr() {
  printf '%s' "$1" | tr -d '\r'
}

trim_ws() {
  _s="$1"
  _s="${_s#"${_s%%[![:space:]]*}"}"
  _s="${_s%"${_s##*[![:space:]]}"}"
  printf '%s' "$_s"
}

log_msg() {
  _msg="$1"
  _log_dir="${LOG_FILE%/*}"
  if [ "$ENABLE_LOG" = "1" ] && [ "$DRY_RUN" = "0" ] && [ -w "$_log_dir" ] 2>/dev/null; then
    _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'boot')"
    printf '[%s] [%s] %s\n' "$_ts" "$STAGE" "$_msg" >> "$LOG_FILE" 2>/dev/null
  fi
}

say() {
  printf '%s\n' "$1"
}

cleanup_tmp() {
  [ -n "$TMP_PROPS" ] && [ -f "$TMP_PROPS" ] && rm -f "$TMP_PROPS"
}
trap cleanup_tmp EXIT INT TERM

init_tmp() {
  if [ -w /dev ]; then
    TMP_PROPS="/dev/.rkp_props.$$"
  elif [ -n "${TMPDIR:-}" ] && [ -w "$TMPDIR" ]; then
    TMP_PROPS="$TMPDIR/.rkp_props.$$"
  else
    TMP_PROPS="/data/local/tmp/.rkp_props.$$"
  fi
}

# ------------------------------------------------------------------------------
# Deteksi Root Manager Aktif & resetprop
# ------------------------------------------------------------------------------
detect_resetprop() {
  if [ -n "${RKP_MOCK_RESETPROP:-}" ] && [ -x "$RKP_MOCK_RESETPROP" ]; then
    RESETPROP_BIN="$RKP_MOCK_RESETPROP"
    RESETPROP_MODE="direct"
    ROOT_MGR="mock"
    return 0
  fi

  if command -v resetprop >/dev/null 2>&1; then
    RESETPROP_BIN="$(command -v resetprop)"
    RESETPROP_MODE="direct"
    case "$RESETPROP_BIN" in
      *ksu*)    ROOT_MGR="KernelSU" ;;
      *ap*)     ROOT_MGR="APatch" ;;
      *magisk*) ROOT_MGR="Magisk" ;;
      *)
        if [ -n "${KSU:-}" ] || [ -x /data/adb/ksud ]; then
          ROOT_MGR="KernelSU"
        elif [ -n "${APATCH:-}" ] || [ -x /data/adb/apd ]; then
          ROOT_MGR="APatch"
        elif command -v magisk >/dev/null 2>&1; then
          ROOT_MGR="Magisk"
        else
          ROOT_MGR="generic"
        fi
        ;;
    esac
    return 0
  fi

  if [ -x /data/adb/ksu/bin/resetprop ] && [ -x /data/adb/ksud ]; then
    RESETPROP_BIN="/data/adb/ksu/bin/resetprop"
    RESETPROP_MODE="direct"
    ROOT_MGR="KernelSU"
  elif [ -x /data/adb/ap/bin/resetprop ] && [ -x /data/adb/apd ]; then
    RESETPROP_BIN="/data/adb/ap/bin/resetprop"
    RESETPROP_MODE="direct"
    ROOT_MGR="APatch"
  elif [ -x /data/adb/magisk/resetprop ]; then
    RESETPROP_BIN="/data/adb/magisk/resetprop"
    RESETPROP_MODE="direct"
    ROOT_MGR="Magisk"
  elif command -v magisk >/dev/null 2>&1; then
    RESETPROP_BIN="$(command -v magisk)"
    RESETPROP_MODE="magisk_sub"
    ROOT_MGR="Magisk"
  elif [ -x /data/adb/ksu/bin/resetprop ]; then
    RESETPROP_BIN="/data/adb/ksu/bin/resetprop"
    RESETPROP_MODE="direct"
    ROOT_MGR="KernelSU"
  elif [ -x /data/adb/ap/bin/resetprop ]; then
    RESETPROP_BIN="/data/adb/ap/bin/resetprop"
    RESETPROP_MODE="direct"
    ROOT_MGR="APatch"
  else
    return 1
  fi
  return 0
}

dump_props() {
  if [ "$RESETPROP_MODE" = "magisk_sub" ]; then
    "$RESETPROP_BIN" resetprop 2>/dev/null
  else
    "$RESETPROP_BIN" 2>/dev/null
  fi
}

get_prop() {
  if [ "$RESETPROP_MODE" = "magisk_sub" ]; then
    "$RESETPROP_BIN" resetprop "$1" 2>/dev/null
  elif [ -n "$RESETPROP_BIN" ]; then
    "$RESETPROP_BIN" "$1" 2>/dev/null
  else
    getprop "$1" 2>/dev/null
  fi
}

set_prop() {
  _k="$1"
  _v="$2"
  case "$SEEN_PROPS" in
    *"|$_k|"*) return 0 ;;
  esac
  SEEN_PROPS="${SEEN_PROPS}${_k}|"

  _cur="$(get_prop "$_k")"
  [ "$_cur" = "$_v" ] && return 0

  if [ "$DRY_RUN" = "1" ]; then
    say "  [DRY-RUN] $_k: '${_cur:-<unset>}' -> '$_v'"
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    return 0
  fi

  if [ "$RESETPROP_MODE" = "magisk_sub" ]; then
    "$RESETPROP_BIN" resetprop -n "$_k" "$_v" 2>/dev/null
  else
    "$RESETPROP_BIN" -n "$_k" "$_v" 2>/dev/null
  fi
  if [ $? -eq 0 ]; then
    CHANGED_COUNT=$((CHANGED_COUNT + 1))
    log_msg "SET $_k: '${_cur:-<unset>}' -> '$_v'"
  else
    log_msg "FAIL $_k -> '$_v'"
  fi
}

# ------------------------------------------------------------------------------
# Deteksi Perangkat Google Pixel (Proteksi Anti-Crash Pixel Camera / libgcam)
# ------------------------------------------------------------------------------
is_pixel_device() {
  _fp="$(to_lower "$(get_prop ro.build.fingerprint) $(get_prop ro.vendor.build.fingerprint)")"
  case "$_fp" in
    *google/*) return 0 ;;
  esac

  _hw="$(to_lower "$(get_prop ro.hardware) $(get_prop ro.boot.hardware) $(get_prop ro.product.board)")"
  case " $_hw " in
    *" husky "*|*" shiba "*|*" akita "*|*" cheetah "*|*" panther "*|*" oriole "*|*" raven "*|*" bluejay "*|*" lynx "*|*" felix "*|*" tangorpro "*|*" tokay "*|*" caiman "*|*" komodo "*|*" comet "*|*" mustang "*|*" frankel "*|*" blazer "*|*" tegu "*|*" slider "*|*" gs101 "*|*" gs201 "*|*" zuma "*|*" zumapro "*)
      return 0
      ;;
  esac

  _mfg="$(to_lower "$(get_prop ro.product.manufacturer)")"
  [ "$_mfg" = "google" ] && return 0

  if [ -z "${RKP_MOCK_RESETPROP:-}" ]; then
    [ -d /product/priv-app/GoogleCamera ] || [ -d /product/priv-app/PixelCamera ] && return 0
  fi

  return 1
}

# ------------------------------------------------------------------------------
# Konfigurasi & Auto-Sync PIF (PlayIntegrityFix / PlayIntegrityFork)
# ------------------------------------------------------------------------------
write_default_conf() {
  _dest="${1:-$CONF_FILE}"
  _dir="${_dest%/*}"
  [ "$_dir" != "$_dest" ] && mkdir -p "$_dir" 2>/dev/null
  cat <<EOF > "$_dest" 2>/dev/null || return 1
# Konfigurasi Universal RKP Manufacturer & Brand Fix v$VERSION
# Edit nilai di bawah lalu reboot (atau jalankan Action di Magisk/KSU/APatch).

# Mode override:
#   safe   = HANYA properti *_for_attestation (REKOMENDASI: aman untuk Pixel Camera & Stock ROM)
#   vendor = safe + properti vendor/odm/*_dlkm (tidak menyentuh Build.MANUFACTURER app)
#   full   = Override global semua partisi + sapu dinamis (JANGAN pakai di Pixel Stock!)
SPOOF_MODE="$SPOOF_MODE"

# Set 1 hanya jika benar-benar ingin memaksa mode vendor/full di perangkat Google Pixel
# (PERINGATAN: berisiko tinggi membuat Google/Pixel Camera crash!)
ALLOW_PIXEL_FULL=$ALLOW_PIXEL_FULL

# Target manufacturer & brand (contoh: nubia / Google / samsung / OnePlus)
TARGET_MANUFACTURER="$TARGET_MANUFACTURER"
TARGET_BRAND="$TARGET_BRAND"

# 1 = Sinkron otomatis MANUFACTURER & BRAND dari pif.json / pif.prop jika terpasang
# 0 = Gunakan nilai manual TARGET_MANUFACTURER & TARGET_BRAND di atas
AUTO_SYNC_PIF=$AUTO_SYNC_PIF

# 1 = Override properti *_for_attestation (prioritas utama KeyMint / RKP)
SPOOF_ATTESTATION_PROPS=$SPOOF_ATTESTATION_PROPS

# Pola OEM tambahan untuk disapu pada mode full (pisahkan dengan |, huruf kecil, opsional)
# Contoh: EXTRA_SOURCE_PATTERNS="miui|hyperos"
EXTRA_SOURCE_PATTERNS="$EXTRA_SOURCE_PATTERNS"

# Jeda (detik) setelah boot_completed sebelum tahap 2 memeriksa ulang override vendor
LATE_REAPPLY_DELAY=$LATE_REAPPLY_DELAY

# 1 = Catat log ke $LOG_FILE
ENABLE_LOG=$ENABLE_LOG
EOF
  return 0
}

load_conf() {
  if [ -r "$CONF_FILE" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      _line="$(trim_ws "$(strip_cr "$_line")")"
      case "$_line" in
        ""|\#*) continue ;;
        SPOOF_MODE=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in safe|vendor|full) SPOOF_MODE="$_val" ;; esac
          ;;
        ALLOW_PIXEL_FULL=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in 0|1) ALLOW_PIXEL_FULL="$_val" ;; esac
          ;;
        TARGET_MANUFACTURER=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          [ -n "$_val" ] && TARGET_MANUFACTURER="$_val"
          ;;
        TARGET_BRAND=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          [ -n "$_val" ] && TARGET_BRAND="$_val"
          ;;
        AUTO_SYNC_PIF=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in 0|1) AUTO_SYNC_PIF="$_val" ;; esac
          ;;
        SPOOF_ATTESTATION_PROPS=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in 0|1) SPOOF_ATTESTATION_PROPS="$_val" ;; esac
          ;;
        EXTRA_SOURCE_PATTERNS=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          EXTRA_SOURCE_PATTERNS="$_val"
          ;;
        LATE_REAPPLY_DELAY=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in *[!0-9]*|"") ;; *) LATE_REAPPLY_DELAY="$_val" ;; esac
          ;;
        ENABLE_LOG=*)
          _val="${_line#*=}"; _val="${_val#\"}"; _val="${_val%\"}"
          case "$_val" in 0|1) ENABLE_LOG="$_val" ;; esac
          ;;
      esac
    done < "$CONF_FILE"
  fi
}

read_pif_field() {
  _file="$1"
  _key="$2"
  [ -r "$_file" ] || return 1
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="$(trim_ws "$(strip_cr "$_line")")"
    case "$_line" in
      ""|\#*|//*|/\**) continue ;;
    esac
    case "$_line" in
      *"\"$_key\""*:*)
        _v="${_line#*\"$_key\"}"
        _v="${_v#*:}"
        _v="$(trim_ws "$_v")"
        case "$_v" in
          \"*)
            _v="${_v#\"}"
            _v="${_v%%\"*}"
            if [ -n "$_v" ]; then
              printf '%s' "$_v"
              return 0
            fi
            ;;
        esac
        ;;
      "$_key"=*)
        _v="${_line#*=}"
        _v="${_v#\"}"
        _v="${_v%\"}"
        if [ -n "$_v" ]; then
          printf '%s' "$_v"
          return 0
        fi
        ;;
    esac
  done < "$_file"
  return 1
}

sync_from_pif() {
  [ "$AUTO_SYNC_PIF" = "1" ] || return 0
  for _pf in \
    "${RKP_PIF_FILE:-}" \
    /data/adb/modules/playintegrityfix/custom.pif.json \
    /data/adb/modules/playintegrityfix/custom.pif.prop \
    /data/adb/modules/playintegrityfix/pif.json \
    /data/adb/modules/playintegrityfix/pif.prop \
    /data/adb/modules/PlayIntegrityFork/custom.pif.json \
    /data/adb/modules/PlayIntegrityFork/custom.pif.prop \
    /data/adb/pif.json \
    /data/adb/pif.prop
  do
    [ -n "$_pf" ] && [ -r "$_pf" ] || continue
    _pm="$(read_pif_field "$_pf" "MANUFACTURER")"
    _pb="$(read_pif_field "$_pf" "BRAND")"
    if [ -n "$_pm" ] || [ -n "$_pb" ]; then
      [ -n "$_pm" ] && TARGET_MANUFACTURER="$_pm"
      [ -n "$_pb" ] && TARGET_BRAND="$_pb"
      log_msg "PIF sync ($_pf): MANUFACTURER=$TARGET_MANUFACTURER BRAND=$TARGET_BRAND"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------------------------
# Auto-Deteksi OEM Asli + Ekspansi Keluarga Sub-Brand (Lintas Perangkat)
# ------------------------------------------------------------------------------
append_unique_token() {
  _list="$1"
  _tok="$(trim_ws "$(to_lower "$2")")"
  _tgt_m="$(to_lower "$TARGET_MANUFACTURER")"
  _tgt_b="$(to_lower "$TARGET_BRAND")"

  case "$_tok" in ""|?|unknown|android|generic|aosp|none|null) printf '%s' "$_list"; return ;; esac
  [ "$_tok" = "$_tgt_m" ] && { printf '%s' "$_list"; return; }
  [ "$_tok" = "$_tgt_b" ] && { printf '%s' "$_list"; return; }

  case "|$_list|" in
    *"|$_tok|"*) printf '%s' "$_list" ;;
    *)
      if [ -z "$_list" ]; then
        printf '%s' "$_tok"
      else
        printf '%s|%s' "$_list" "$_tok"
      fi
      ;;
  esac
}

expand_oem_family() {
  _raw="$1"
  _norm=" $(printf '%s' "$_raw" | tr '_./,-' '     ') "
  _out="$_raw"

  case "$_raw" in
    *xiaomi*|*redmi*|*poco*|*blackshark*) _out="${_out}|xiaomi|redmi|poco|blackshark" ;;
  esac
  case "$_raw" in
    *oppo*|*oneplus*|*realme*|*oplus*)    _out="${_out}|oppo|oneplus|realme|oplus" ;;
  esac
  case "$_raw" in
    *vivo*|*iqoo*)                        _out="${_out}|vivo|iqoo" ;;
  esac
  case "$_raw" in
    *huawei*|*honor*)                     _out="${_out}|huawei|honor" ;;
  esac
  case "$_raw" in
    *nubia*|*redmagic*)                   _out="${_out}|zte|nubia|redmagic" ;;
  esac
  case "$_norm" in
    *" zte "*)                            _out="${_out}|zte|nubia|redmagic" ;;
  esac
  case "$_raw" in
    *infinix*|*tecno*|*transsion*)        _out="${_out}|infinix|tecno|itel|transsion" ;;
  esac
  case "$_norm" in
    *" itel "*)                           _out="${_out}|infinix|tecno|itel|transsion" ;;
  esac
  case "$_raw" in
    *motorola*|*lenovo*)                  _out="${_out}|motorola|moto|lenovo|zuk" ;;
  esac
  case "$_norm" in
    *" moto "*|*" zuk "*)                 _out="${_out}|motorola|moto|lenovo|zuk" ;;
  esac
  case "$_raw" in
    *samsung*)                            _out="${_out}|samsung" ;;
  esac
  case "$_raw" in
    *asus*)                               _out="${_out}|asus|rog" ;;
  esac
  case "$_norm" in
    *" rog "*)                            _out="${_out}|asus|rog" ;;
  esac
  case "$_raw" in
    *nothing*)                            _out="${_out}|nothing|cmf" ;;
  esac
  case "$_norm" in
    *" cmf "*)                            _out="${_out}|nothing|cmf" ;;
  esac
  case "$_raw" in
    *nokia*)                              _out="${_out}|nokia|hmd" ;;
  esac
  case "$_norm" in
    *" hmd "*)                            _out="${_out}|nokia|hmd" ;;
  esac
  case "$_raw" in
    *sony*)                               _out="${_out}|sony" ;;
  esac
  case "$_raw" in
    *google*)                             _out="${_out}|google" ;;
  esac
  case "$_raw" in
    *meizu*)                              _out="${_out}|meizu" ;;
  esac
  case "$_raw" in
    *sharp*)                              _out="${_out}|sharp" ;;
  esac
  case "$_norm" in
    *" lg "*|*" lge "*)                   _out="${_out}|lge|lg electronics" ;;
  esac

  printf '%s' "$_out"
}

detect_source_oem_tokens() {
  _tokens=""

  if [ -r "$OEM_CACHE" ]; then
    _cached="$(cat "$OEM_CACHE" 2>/dev/null)"
    _old_ifs="$IFS"
    IFS='|'
    set -f
    for _t in $_cached; do
      _tokens="$(append_unique_token "$_tokens" "$_t")"
    done
    set +f
    IFS="$_old_ifs"
  fi

  for _p in \
    ro.product.manufacturer \
    ro.product.vendor.manufacturer \
    ro.product.odm.manufacturer \
    ro.product.system.manufacturer \
    ro.product.product.manufacturer \
    ro.product.bootimage.manufacturer \
    ro.product.vendor_dlkm.manufacturer \
    ro.product.odm_dlkm.manufacturer \
    ro.product.system_dlkm.manufacturer \
    ro.product.my_product.manufacturer \
    ro.product.brand \
    ro.product.vendor.brand \
    ro.product.odm.brand \
    ro.product.system.brand \
    ro.product.manufacturer_for_attestation \
    ro.product.vendor.manufacturer_for_attestation \
    ro.product.odm.manufacturer_for_attestation
  do
    _v="$(get_prop "$_p")"
    [ -n "$_v" ] || continue
    _vlc="$(to_lower "$_v")"
    _fam="$(expand_oem_family "$_vlc")"
    _old_ifs="$IFS"
    IFS='|'
    set -f
    for _ft in $_fam; do
      _tokens="$(append_unique_token "$_tokens" "$_ft")"
    done
    set +f
    IFS="$_old_ifs"
  done

  if [ -n "$PREV_TARGET_TOKENS" ]; then
    _old_ifs="$IFS"
    IFS='|'
    set -f
    for _pt in $PREV_TARGET_TOKENS; do
      _tokens="$(append_unique_token "$_tokens" "$_pt")"
    done
    set +f
    IFS="$_old_ifs"
  fi

  if [ -n "$EXTRA_SOURCE_PATTERNS" ]; then
    _old_ifs="$IFS"
    IFS='|'
    set -f
    for _et in $EXTRA_SOURCE_PATTERNS; do
      _tokens="$(append_unique_token "$_tokens" "$_et")"
    done
    set +f
    IFS="$_old_ifs"
  fi

  _cache_dir="${OEM_CACHE%/*}"
  if [ "$DRY_RUN" = "0" ] && [ -n "$_tokens" ] && [ -w "$_cache_dir" ] 2>/dev/null; then
    printf '%s' "$_tokens" > "$OEM_CACHE" 2>/dev/null
  fi

  printf '%s' "$_tokens"
}

is_hardware_prop() {
  _plc="$(to_lower "$1")"
  case "$_plc" in
    ro.soc.*|*.soc.*|*qti*|*qualcomm*|*mediatek*|*mtk*|*exynos*|*unisoc*|*kirin*) return 0 ;;
    *bluetooth*|*.bt.*|*usb*|*camera*|*.cam.*|*nfc*|*audio*|*sound*|*speaker*)    return 0 ;;
    *display*|*panel*|*lcm*|*drm*|*ril*|*radio*|*gsm*|*telephony*|*modem*|*ims*)  return 0 ;;
    *wifi*|*wlan*|*sensor*|*vibrator*|*haptic*|*battery*|*charger*|*power*)       return 0 ;;
    *fingerprint*|*biometric*|*thermal*|*gpu*|*vulkan*|*opengl*|*boot.hardware*)  return 0 ;;
    *keymaster*|*keymint*|*gatekeeper*|*widevine*|*crypto*)                       return 0 ;;
  esac
  return 1
}

matches_any_token() {
  _haystack="$(to_lower "$1")"
  _toks="$2"
  [ -n "$_toks" ] || return 1
  _norm=" $(printf '%s' "$_haystack" | tr '_./,-' '     ') "

  _old_ifs="$IFS"
  IFS='|'
  set -f
  for _t in $_toks; do
    case "$_t" in
      ?|??|???|????)
        case "$_norm" in
          *" $_t "*)
            set +f
            IFS="$_old_ifs"
            return 0
            ;;
        esac
        ;;
      *)
        case "$_haystack" in
          *"$_t"*)
            set +f
            IFS="$_old_ifs"
            return 0
            ;;
        esac
        ;;
    esac
  done
  set +f
  IFS="$_old_ifs"
  return 1
}

partition_exists() {
  _pt="$1"
  [ -n "$(get_prop "ro.product.${_pt}.manufacturer")" ] && return 0
  [ -n "$(get_prop "ro.product.${_pt}.brand")" ] && return 0
  [ -n "$(get_prop "ro.product.${_pt}.model")" ] && return 0
  [ -n "$(get_prop "ro.product.${_pt}.device")" ] && return 0
  return 1
}

resolve_effective_mode() {
  EFF_MODE="$SPOOF_MODE"
  if [ "$EFF_MODE" != "safe" ] && [ "$ALLOW_PIXEL_FULL" != "1" ] && is_pixel_device; then
    EFF_MODE="safe"
    log_msg "PIXEL GUARD: Menurunkan mode '$SPOOF_MODE' -> 'safe' (anti-crash Pixel Camera). Set ALLOW_PIXEL_FULL=1 untuk memaksa."
    if [ "$STAGE" = "manual" ] || [ "$STAGE" = "dry-run" ] || [ "$STAGE" = "set" ]; then
      say "INFO [Pixel Guard]: Google Pixel terdeteksi -> mode diturunkan ke 'safe' (attestation-only) agar Pixel Camera tidak crash."
    fi
  fi
}

# ------------------------------------------------------------------------------
# Mesin Override Universal (safe / vendor / full)
# ------------------------------------------------------------------------------
apply_fix() {
  CHANGED_COUNT=0
  SKIPPED_HW_COUNT=0
  SEEN_PROPS="|"

  resolve_effective_mode
  _eff_mode="$EFF_MODE"
  _src_tokens="$(detect_source_oem_tokens)"
  log_msg "Start apply (root=$ROOT_MGR, mode=$_eff_mode, target=${TARGET_MANUFACTURER}/${TARGET_BRAND}, src_tokens=${_src_tokens:-<none>})"

  # Tahap A: Properti Attestation (aman 100% untuk semua kamera/HAL, prioritas utama KeyMint/RKP)
  if [ "$SPOOF_ATTESTATION_PROPS" = "1" ] || [ "$_eff_mode" = "safe" ]; then
    for _p in \
      ro.product.manufacturer_for_attestation \
      ro.product.vendor.manufacturer_for_attestation \
      ro.product.odm.manufacturer_for_attestation
    do
      set_prop "$_p" "$TARGET_MANUFACTURER"
    done

    for _p in \
      ro.product.brand_for_attestation \
      ro.product.vendor.brand_for_attestation \
      ro.product.odm.brand_for_attestation
    do
      set_prop "$_p" "$TARGET_BRAND"
    done

    for _part in system product system_ext bootimage; do
      for _kind in manufacturer brand; do
        _p="ro.product.${_part}.${_kind}_for_attestation"
        if [ -n "$(get_prop "$_p")" ]; then
          if [ "$_kind" = "brand" ]; then
            set_prop "$_p" "$TARGET_BRAND"
          else
            set_prop "$_p" "$TARGET_MANUFACTURER"
          fi
        fi
      done
    done
  fi

  # Mode SAFE berhenti di sini agar Build.MANUFACTURER / Build.BRAND / Camera HAL tetap asli
  if [ "$_eff_mode" = "safe" ]; then
    log_msg "Done apply (safe): changed=$CHANGED_COUNT"
    return 0
  fi

  # Tahap B: Mode VENDOR (override partisi vendor/odm/*_dlkm tanpa mengubah Build sistem)
  for _part in vendor odm; do
    set_prop "ro.product.${_part}.manufacturer" "$TARGET_MANUFACTURER"
    set_prop "ro.product.${_part}.brand" "$TARGET_BRAND"
  done
  for _part in vendor_dlkm odm_dlkm; do
    [ -n "$(get_prop "ro.product.${_part}.manufacturer")" ] && \
      set_prop "ro.product.${_part}.manufacturer" "$TARGET_MANUFACTURER"
    [ -n "$(get_prop "ro.product.${_part}.brand")" ] && \
      set_prop "ro.product.${_part}.brand" "$TARGET_BRAND"
  done

  if [ "$_eff_mode" = "vendor" ]; then
    log_msg "Done apply (vendor): changed=$CHANGED_COUNT"
    return 0
  fi

  # Tahap C: Mode FULL (override global semua partisi + sapu dinamis)
  set_prop ro.product.manufacturer "$TARGET_MANUFACTURER"
  set_prop ro.product.brand "$TARGET_BRAND"

  for _part in system product; do
    set_prop "ro.product.${_part}.manufacturer" "$TARGET_MANUFACTURER"
    set_prop "ro.product.${_part}.brand" "$TARGET_BRAND"
  done

  if partition_exists "system_ext"; then
    set_prop ro.product.system_ext.manufacturer "$TARGET_MANUFACTURER"
    set_prop ro.product.system_ext.brand "$TARGET_BRAND"
  fi

  for _part in \
    bootimage system_dlkm \
    my_product my_manifest my_stock my_region my_heytap my_bigball \
    my_carrier my_company my_engineering my_preload
  do
    [ -n "$(get_prop "ro.product.${_part}.manufacturer")" ] && \
      set_prop "ro.product.${_part}.manufacturer" "$TARGET_MANUFACTURER"
    [ -n "$(get_prop "ro.product.${_part}.brand")" ] && \
      set_prop "ro.product.${_part}.brand" "$TARGET_BRAND"
  done

  init_tmp
  dump_props > "$TMP_PROPS"
  if [ -r "$TMP_PROPS" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
      _line="$(strip_cr "$_line")"
      case "$_line" in
        \[*\]:\ \[*\])
          _prop="${_line#\[}"
          _prop="${_prop%%\]:*}"
          _prop_lc="$(to_lower "$_prop")"
          case "$_prop_lc" in
            *manufacturer*|*brand*)
              if is_hardware_prop "$_prop"; then
                SKIPPED_HW_COUNT=$((SKIPPED_HW_COUNT + 1))
                continue
              fi

              _val="${_line#*:\ \[}"
              _val="${_val%\]}"
              [ -n "$_val" ] || continue

              if matches_any_token "$_val" "$_src_tokens"; then
                case "$_prop_lc" in
                  *brand*) set_prop "$_prop" "$TARGET_BRAND" ;;
                  *)       set_prop "$_prop" "$TARGET_MANUFACTURER" ;;
                esac
              fi
              ;;
          esac
          ;;
      esac
    done < "$TMP_PROPS"
  fi
  cleanup_tmp

  log_msg "Done apply (full): changed=$CHANGED_COUNT skipped_hw=$SKIPPED_HW_COUNT"
}

# ------------------------------------------------------------------------------
# Diagnostik / Audit Status
# ------------------------------------------------------------------------------
show_status() {
  resolve_effective_mode
  _eff_mode="$EFF_MODE"
  _src_tokens="$(detect_source_oem_tokens)"
  _is_px="TIDAK"
  is_pixel_device && _is_px="YA (Pixel Camera Guard aktif)"
  LEAK_COUNT=0
  _ok_count=0

  say "=============================================="
  say " Universal RKP Fix v$VERSION - Status & Audit"
  say "=============================================="
  say "Root Manager   : $ROOT_MGR ($RESETPROP_BIN)"
  say "Android / SDK  : $(get_prop ro.build.version.release) (SDK $(get_prop ro.build.version.sdk))"
  say "Google Pixel   : $_is_px"
  say "Konfigurasi    : $CONF_FILE $([ -r "$CONF_FILE" ] && echo '[aktif]' || echo '[default]')"
  say "Mode           : $_eff_mode (config=$SPOOF_MODE)"
  say "Target         : MANUFACTURER='$TARGET_MANUFACTURER' | BRAND='$TARGET_BRAND'"
  say "Auto-Sync PIF  : $AUTO_SYNC_PIF | Attestation Props: $SPOOF_ATTESTATION_PROPS"
  say "Source OEM     : ${_src_tokens:-<tidak terdeteksi / sudah bersih>}"
  say "----------------------------------------------"

  if [ "$_eff_mode" = "safe" ]; then
    say "Audit Properti Attestation (Mode SAFE - Camera terlindungi):"
    for _p in \
      ro.product.manufacturer_for_attestation \
      ro.product.vendor.manufacturer_for_attestation \
      ro.product.odm.manufacturer_for_attestation \
      ro.product.brand_for_attestation \
      ro.product.vendor.brand_for_attestation \
      ro.product.odm.brand_for_attestation
    do
      _val="$(get_prop "$_p")"
      case "$_p" in
        *brand*) _exp="$TARGET_BRAND" ;;
        *)       _exp="$TARGET_MANUFACTURER" ;;
      esac
      if [ "$_val" = "$_exp" ]; then
        _ok_count=$((_ok_count + 1))
      else
        say "  [LEAK]     $_p = ${_val:-<unset>} (seharusnya $_exp)"
        LEAK_COUNT=$((LEAK_COUNT + 1))
      fi
    done
    say "  [SAFE]     ro.product.manufacturer = $(get_prop ro.product.manufacturer) (dijaga asli untuk Camera/HAL)"
    say "  [SAFE]     ro.product.brand = $(get_prop ro.product.brand) (dijaga asli untuk Camera/HAL)"
  else
    say "Audit Properti (Mode $_eff_mode):"
    init_tmp
    dump_props > "$TMP_PROPS"
    if [ -r "$TMP_PROPS" ]; then
      while IFS= read -r _line || [ -n "$_line" ]; do
        _line="$(strip_cr "$_line")"
        case "$_line" in
          \[*\]:\ \[*\])
            _prop="${_line#\[}"
            _prop="${_prop%%\]:*}"
            _prop_lc="$(to_lower "$_prop")"
            case "$_prop_lc" in
              *manufacturer*|*brand*)
                _val="${_line#*:\ \[}"
                _val="${_val%\]}"
                if is_hardware_prop "$_prop"; then
                  continue
                fi
                case "$_prop_lc" in
                  *brand*) _exp="$TARGET_BRAND" ;;
                  *)       _exp="$TARGET_MANUFACTURER" ;;
                esac
                if [ "$_val" = "$_exp" ]; then
                  _ok_count=$((_ok_count + 1))
                elif matches_any_token "$_val" "$_src_tokens"; then
                  say "  [LEAK]     $_prop = $_val (seharusnya $_exp)"
                  LEAK_COUNT=$((LEAK_COUNT + 1))
                else
                  say "  [DIFF]     $_prop = $_val"
                fi
                ;;
            esac
            ;;
        esac
      done < "$TMP_PROPS"
    fi
    cleanup_tmp
  fi

  say "Ringkasan      : $_ok_count cocok | $LEAK_COUNT leak terdeteksi"
  say "----------------------------------------------"
  say "Ekosistem Attestation:"
  say "  Modul terpasang : $([ -d "$MOD_DIR" ] && echo "YA ($MOD_DIR)" || echo 'TIDAK')"
  if [ -d /data/adb/modules/playintegrityfix ] || [ -d /data/adb/modules/PlayIntegrityFork ]; then
    say "  PIF terdeteksi  : YA"
  else
    say "  PIF terdeteksi  : TIDAK"
  fi
  if [ -d /data/adb/modules/tricky_store ] || [ -d /data/adb/modules/trickystore ] || [ -d /data/adb/tricky_store ]; then
    say "  TrickyStore     : YA"
  else
    say "  TrickyStore     : TIDAK"
  fi
  if [ "$LEAK_COUNT" -eq 0 ]; then
    if [ "$_eff_mode" = "safe" ]; then
      say "Catatan        : Properti attestation bersih & Camera aman. Jika perangkat non-Pixel"
      say "                 masih fallback ke OEM lama, coba '--mode full' atau gunakan TrickyStore."
    else
      say "Catatan        : Semua properti bersih. Jika RKP masih mendeteksi OEM lama,"
      say "                 sumbernya berasal dari hardware TEE/KeyMint TA (perlu TrickyStore)."
    fi
  fi
}

# ------------------------------------------------------------------------------
# Installer / Uninstaller Modul Otomatis (Magisk / KernelSU / APatch)
# ------------------------------------------------------------------------------
install_module() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    say "ERROR: Jalankan --install sebagai root (su -c ...)."
    exit 1
  fi

  _self="$0"
  case "$_self" in
    /*) ;;
    *) _self="$(pwd)/$_self" ;;
  esac
  if command -v realpath >/dev/null 2>&1; then
    _self_real="$(realpath "$_self" 2>/dev/null || echo "$_self")"
  else
    _self_real="$_self"
  fi

  mkdir -p "$MOD_DIR" || { say "ERROR: Gagal membuat $MOD_DIR"; exit 1; }

  _dst="$MOD_DIR/fix-rkp.sh"
  if command -v realpath >/dev/null 2>&1 && [ -e "$_dst" ]; then
    _dst_real="$(realpath "$_dst" 2>/dev/null || echo "$_dst")"
  else
    _dst_real="$_dst"
  fi

  if [ "$_self_real" != "$_dst_real" ]; then
    cp "$_self" "$_dst" || { say "ERROR: Gagal menyalin script ke $_dst"; exit 1; }
  fi
  chmod 755 "$_dst"

  cat <<EOF > "$MOD_DIR/module.prop"
id=$MOD_ID
name=Universal RKP Manufacturer Fix
version=v$VERSION
versionCode=220
author=Universal Cross-Device Script
description=Camera-safe dual-stage (post-fs-data + late service) cross-device RKP manufacturer & brand fixer for Magisk, KernelSU, and APatch.
EOF

  cat <<'EOF' > "$MOD_DIR/post-fs-data.sh"
#!/system/bin/sh
MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."
[ -f /data/adb/rkp-fix.log ] && : > /data/adb/rkp-fix.log
exec /system/bin/sh "$MODDIR/fix-rkp.sh" --post-fs-data
EOF

  cat <<'EOF' > "$MOD_DIR/service.sh"
#!/system/bin/sh
MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."
exec /system/bin/sh "$MODDIR/fix-rkp.sh" --service
EOF

  cat <<'EOF' > "$MOD_DIR/action.sh"
#!/system/bin/sh
MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="."
/system/bin/sh "$MODDIR/fix-rkp.sh" --apply
/system/bin/sh "$MODDIR/fix-rkp.sh" --status
EOF

  cat <<EOF > "$MOD_DIR/uninstall.sh"
#!/system/bin/sh
rm -f "$LOG_FILE" "$OEM_CACHE"
EOF

  chmod 755 "$MOD_DIR/post-fs-data.sh" "$MOD_DIR/service.sh" "$MOD_DIR/action.sh" "$MOD_DIR/uninstall.sh"
  chmod 644 "$MOD_DIR/module.prop"

  if [ ! -f "$CONF_FILE" ]; then
    write_default_conf "$CONF_FILE" || { say "ERROR: Gagal menulis $CONF_FILE"; exit 1; }
    say "Konfigurasi dibuat: $CONF_FILE (mode default: $SPOOF_MODE)"
  else
    say "Konfigurasi lama dipertahankan: $CONF_FILE (mode: $SPOOF_MODE)"
  fi

  for _old in /data/adb/post-fs-data.d/fix-rkp.sh /data/adb/service.d/fix-rkp.sh; do
    if [ -f "$_old" ]; then
      say "INFO: Script lama ditemukan di $_old (disarankan dihapus agar tidak dobel)."
    fi
  done

  say "Modul terpasang di: $MOD_DIR"
  say "Reboot perangkat agar tahap post-fs-data aktif sebelum Zygote/KeyMint/rkpd."
}

uninstall_module() {
  if [ "$(id -u 2>/dev/null || echo 1)" != "0" ]; then
    say "ERROR: Jalankan --uninstall sebagai root."
    exit 1
  fi
  rm -rf "$MOD_DIR" "$LOG_FILE" "$OEM_CACHE"
  say "Modul $MOD_ID dihapus. (Config $CONF_FILE tetap disimpan; hapus manual jika tidak perlu.)"
}

run_service_stage() {
  STAGE="service"
  _wait=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$_wait" -lt 120 ]; do
    sleep 1
    _wait=$((_wait + 1))
  done
  [ "$LATE_REAPPLY_DELAY" -gt 0 ] 2>/dev/null && sleep "$LATE_REAPPLY_DELAY"
  apply_fix
}

show_help() {
  cat <<EOF
Universal Cross-Device RKP Manufacturer & Brand Fix v$VERSION

Pemakaian:
  sh fix-rkp.sh --install                   Pasang sebagai modul Magisk/KSU/APatch (dual-stage)
  sh fix-rkp.sh --uninstall                 Hapus modul terpasang
  sh fix-rkp.sh --mode <safe|vendor|full>   Pilih mode (safe = anti-crash Camera di Pixel/Stock)
  sh fix-rkp.sh --set <mfg> [brand]         Ubah target di $CONF_FILE (matikan auto-PIF) & terapkan
  sh fix-rkp.sh --auto-pif <0|1>            Aktifkan/matikan auto-sync dari PlayIntegrityFix
  sh fix-rkp.sh --apply                     Terapkan override sekarang
  sh fix-rkp.sh --dry-run                   Simulasi tanpa mengubah properti apapun
  sh fix-rkp.sh --status                    Audit properti, leak, dan status ekosistem RKP
  sh fix-rkp.sh --post-fs-data              Jalankan tahap 1 (dipanggil otomatis oleh modul)
  sh fix-rkp.sh --service                   Jalankan tahap 2 pasca-boot (dipanggil otomatis)
EOF
}

# ------------------------------------------------------------------------------
# Entry Point
# ------------------------------------------------------------------------------
load_conf

CMD="${1:-}"

if [ -z "$CMD" ]; then
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
    CMD="--apply"
  else
    CMD="--post-fs-data"
  fi
fi

case "$CMD" in
  -h|--help)
    show_help
    exit 0
    ;;
  --install)
    install_module
    exit 0
    ;;
  --uninstall)
    uninstall_module
    exit 0
    ;;
  --mode)
    case "${2:-}" in
      safe|vendor|full)
        _req_mode="$2"
        if [ "$_req_mode" != "safe" ] && detect_resetprop && is_pixel_device; then
          if [ "${3:-}" != "--force" ]; then
            say "PERINGATAN: Perangkat Google Pixel terdeteksi!"
            say "Mode '$_req_mode' mengubah properti sistem/vendor dan menyebabkan Pixel Camera CRASH."
            say "Tetap gunakan '--mode safe' (attestation-only) atau gunakan TrickyStore."
            say "Jika tetap ingin memaksa: sh fix-rkp.sh --mode $_req_mode --force"
            exit 1
          fi
          ALLOW_PIXEL_FULL=1
        elif [ "$_req_mode" = "safe" ]; then
          ALLOW_PIXEL_FULL=0
        fi
        SPOOF_MODE="$_req_mode"
        write_default_conf "$CONF_FILE" || { say "ERROR: Gagal menulis $CONF_FILE (butuh root)."; exit 1; }
        say "SPOOF_MODE='$SPOOF_MODE' disimpan di $CONF_FILE. Reboot agar perubahan penuh aktif."
        ;;
      *)
        say "ERROR: Gunakan --mode safe | vendor | full"
        exit 1
        ;;
    esac
    exit 0
    ;;
  --set)
    [ -n "${2:-}" ] || { say "ERROR: Gunakan --set <manufacturer> [brand]"; exit 1; }
    PREV_TARGET_TOKENS="${TARGET_MANUFACTURER}|${TARGET_BRAND}"
    TARGET_MANUFACTURER="$2"
    TARGET_BRAND="${3:-$2}"
    if [ "$AUTO_SYNC_PIF" = "1" ]; then
      AUTO_SYNC_PIF=0
      say "INFO: AUTO_SYNC_PIF dimatikan agar target manual tidak ditimpa PIF saat reboot."
    fi
    write_default_conf "$CONF_FILE" || { say "ERROR: Gagal menulis $CONF_FILE (butuh root)."; exit 1; }
    say "Target diperbarui: MANUFACTURER='$TARGET_MANUFACTURER' BRAND='$TARGET_BRAND' ($CONF_FILE)"
    if detect_resetprop; then
      STAGE="set"
      apply_fix
      say "Diterapkan ($CHANGED_COUNT properti diubah). Reboot disarankan untuk RKP/KeyMint."
    fi
    exit 0
    ;;
  --auto-pif)
    case "${2:-}" in
      0|1)
        AUTO_SYNC_PIF="$2"
        write_default_conf "$CONF_FILE" || { say "ERROR: Gagal menulis $CONF_FILE (butuh root)."; exit 1; }
        say "AUTO_SYNC_PIF=$AUTO_SYNC_PIF disimpan di $CONF_FILE"
        ;;
      *)
        say "ERROR: Gunakan --auto-pif 1 atau --auto-pif 0"
        exit 1
        ;;
    esac
    exit 0
    ;;
esac

if ! detect_resetprop; then
  say "ERROR: Binary resetprop tidak ditemukan (butuh root Magisk/KernelSU/APatch)."
  exit 1
fi

sync_from_pif

case "$CMD" in
  --post-fs-data)
    STAGE="post-fs-data"
    apply_fix
    ;;
  --service)
    run_service_stage
    ;;
  --apply)
    STAGE="manual"
    apply_fix
    say "Selesai: $CHANGED_COUNT properti diperbarui (hardware dilewati: $SKIPPED_HW_COUNT)."
    ;;
  --dry-run)
    STAGE="dry-run"
    DRY_RUN=1
    say "Mode simulasi (config: $SPOOF_MODE | target: $TARGET_MANUFACTURER / $TARGET_BRAND):"
    apply_fix
    say "Total properti yang akan diubah: $CHANGED_COUNT (mode aktif: $EFF_MODE | hardware dilewati: $SKIPPED_HW_COUNT)."
    ;;
  --status)
    STAGE="status"
    show_status
    ;;
  *)
    say "Argumen tidak dikenal: $CMD"
    show_help
    exit 1
    ;;
esac
