# rkp-mfr-auto

Simple KSU / APatch / Magisk module to auto-match manufacturer props with your active RKP keybox.

Instead of hardcoding `nubia` (or whatever OEM the public RKP kb is from), this reads `map[3]` straight from your `keybox.xml` at boot and applies it via `resetprop`. Should stay working even if you switch to a different public RKP kb later.

## What it does

On boot (`post-fs-data`), it checks:
- `/data/misc/keystore/omk/keybox.xml` (OhMyKeymint)
- `/data/adb/tricky_store/keybox.xml` (fallback)

It grabs the RKP manufacturer from the cert extension (`1.3.6.1.4.1.11129.2.1.30`, `map[3]`) using BusyBox `awk`/`base64`/`od`, then sets:
- `ro.product.manufacturer`
- `ro.product.vendor.manufacturer`
- `ro.product.manufacturer_for_attestation`

If your keybox is not RKP (no `map[3]`) or your phone already matches, it won't touch anything.

## Install & check

Flash the zip from Releases in KSU / APatch / Magisk and reboot. Remove or disable any old hardcoded module like `rkp_nubia` first.

Check what got detected after reboot:
```sh
su -c cat /data/adb/modules/rkp_mfr_auto/last.log
```

Test detection without changing props:
```sh
su -c "/data/adb/ksu/bin/busybox sh /data/adb/modules/rkp_mfr_auto/post-fs-data.sh --dry-run"
```

## Note on Pixel Camera / camera crashes

Since `resetprop` changes `ro.product.manufacturer` globally, some camera apps (like Pixel Camera / `com.google.android.GoogleCamera` or OEM cameras that check `Build.MANUFACTURER`) might crash on launch.

If that happens on your device:
- Try a per-app Zygisk spoofer instead of global `resetprop`, like [COPG-VD](https://github.com/VD171/COPG-VD) (whitelist mode, or blacklist `com.google.android.GoogleCamera` and `com.google.android.apps.camera.services`) or [EasySpoof](https://github.com/TOMMASO26175/easySpoof).
- Or if you use LSPosed, keep this module and spoof the real manufacturer back just for the camera app with [CamSpoof](https://github.com/indramccaslin/CamSpoof) or [SpoofMyDevice](https://github.com/Xposed-Modules-Repo/com.spoofmydevice).
- You can also try removing `ro.product.vendor.manufacturer` from `post-fs-data.sh` and rebooting to see if that stops the crash.
