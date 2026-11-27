# rkp-mfr-auto

Simple KSU / APatch / Magisk module to auto-match manufacturer props with your active RKP keybox.

Instead of hardcoding `nubia` (or whatever OEM the public RKP kb is from), this reads `map[3]` straight from your `keybox.xml` at boot and applies it via `resetprop`. Should stay working even if you switch to a different public RKP kb later.

Only tested with [ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint) (both its TEE engine for keybox and its PIF engine).

## What it does

On boot (`post-fs-data`), it checks:
- `/data/misc/keystore/omk/keybox.xml` (OhMyKeymint)
- `/data/adb/teesim/keybox.xml` and custom keybox path in `/data/adb/teesim/config.json` (JingMatrix TEESimulator)
- `/data/adb/tricky_store/keybox.xml` (TrickyStore / TEESimulator-RS / older TEESimulator)
- `/data/adb/omk/keybox.xml` and `/data/adb/TEESimulator/keybox.xml` (fallback)

It grabs the RKP manufacturer from the cert extension (`1.3.6.1.4.1.11129.2.1.30`, `map[3]`) using BusyBox `awk`/`base64`/`od`, then sets:
- `ro.product.manufacturer`
- `ro.product.manufacturer_for_attestation`
- `ro.product.vendor.manufacturer` (off by default, can be toggled on in WebUI Settings)

If your keybox is not RKP (no `map[3]`) or your phone already matches, it won't touch anything.

## Install & hot-install

Flash the zip from Releases in KSU / APatch / Magisk. Remove or disable any old hardcoded module like `rkp_nubia` first.

During install, `customize.sh` runs a hot-apply so native `getprop` values update right away (you can also tap **Hot Apply** in the WebUI after swapping keyboxes). Note that Android caches Java `Build.*` fields in Zygote at boot, so a reboot is still needed for apps reading `Build.MANUFACTURER` / `Build.MANUFACTURER_FOR_ATTESTATION` to pick up the change.

Check what got detected:
```sh
su -c cat /data/adb/modules/rkp_mfr_auto/last.log
```

Test detection without changing props:
```sh
su -c "/data/adb/ksu/bin/busybox sh /data/adb/modules/rkp_mfr_auto/post-fs-data.sh --dry-run"
```

## WebUI

Open the module WebUI from KSU / APatch Manager:
- **Home**: shows keybox type (tells you if it's not an RKP keybox so the module isn't needed), detected `map[3]` manufacturer, installed detector / Pixel Camera apps (suggests turning on `ro.product.vendor.manufacturer` if needed), current props, boot log, and a **Hot Apply** button.
- **Settings**: toggle `ro.product.vendor.manufacturer` (off by default; shows a reboot toast when changed) and pick the color theme (`System`, `Light`, `Dark`, `AMOLED` — no reboot required).

## Note on Pixel Camera / camera crashes

Since `resetprop` changes `ro.product.manufacturer` globally, some camera apps (like Pixel Camera / `com.google.android.GoogleCamera` or OEM cameras that check `Build.MANUFACTURER`) might crash on launch.

If that happens on your device:
- Keep `ro.product.vendor.manufacturer` turned off in WebUI Settings (default).
- Or try a per-app Zygisk spoofer instead of global `resetprop`, like [COPG-VD](https://github.com/VD171/COPG-VD) (whitelist mode, or blacklist `com.google.android.GoogleCamera` and `com.google.android.apps.camera.services`) or [EasySpoof](https://github.com/TOMMASO26175/easySpoof).
- Or if you use LSPosed, keep this module and spoof the real manufacturer back just for the camera app with [CamSpoof](https://github.com/indramccaslin/CamSpoof) or [SpoofMyDevice](https://github.com/Xposed-Modules-Repo/com.spoofmydevice).
