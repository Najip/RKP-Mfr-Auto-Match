# RKP Manufacturer Auto-Match

Simple KSU / APatch / Magisk module to auto-match manufacturer props with your active RKP keybox.

The original idea and the first RKP fix script come from [dlagia](https://github.com/dlagia). His untouched script is archived in [`archive/fix-rkp.sh`](archive/fix-rkp.sh). Big thanks to him.

Instead of hardcoding `nubia` (or whatever OEM the public RKP kb is from), this reads `map[3]` straight from your `keybox.xml` at boot and applies it via `resetprop`, with Zygisk handling camera / whitelisted app restore. Should stay working even if you switch to a different public RKP kb later.

Only tested with [ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint) (both its TEE engine for keybox and its PIF engine).

## What it does

On boot (`post-fs-data`), it checks:
- `/data/misc/keystore/omk/keybox.xml` (OhMyKeymint)
- `/data/adb/teesim/keybox.xml` and custom keybox path in `/data/adb/teesim/config.json` (JingMatrix TEESimulator)
- `/data/adb/tricky_store/keybox.xml` (TrickyStore / TEESimulator-RS / older TEESimulator)
- `/data/adb/omk/keybox.xml` and `/data/adb/TEESimulator/keybox.xml` (fallback)

It grabs the RKP manufacturer from the cert extension (`1.3.6.1.4.1.11129.2.1.30`, `map[3]`) using BusyBox `awk`/`base64`/`od`, then works together with **Zygisk** (required: ReZygisk, Zygisk Next, BreZygisk, NeoZygisk, Magisk Zygisk, or any compatible Zygisk provider):
- **Default mode**: sets `ro.product.manufacturer` and `ro.product.manufacturer_for_attestation` to the RKP manufacturer via `resetprop -n` so detectors pass natively while our Zygisk `.so` immediately calls `DLCLOSE_MODULE_LIBRARY` (leaving zero Zygisk maps in normal apps / detectors).
- **Camera apps**: automatically detects Pixel Camera, GCam mods (even cloned package names like `com.samsung.android.scan3d` or `com.agc.*`, detected via camera activity class names and `libgcastartup.so`/`libgcam*.so`), and OEM cameras, restoring your real stock manufacturer (`Build.MANUFACTURER` + native props) so cameras don't crash.
- **User-whitelisted apps**: any app you toggle on in the WebUI **Apps** tab (saved in `/data/adb/rkp_mfr_auto.exclude`) gets a stealth Java `Build.MANUFACTURER` restore and immediately calls `DLCLOSE_MODULE_LIBRARY` so no resident PLT hook or `.so` map is left in `/proc/self/maps`.
- **Stock global mode (for DenyList / banking / UPI apps)**: optional toggle in WebUI **Settings** (**Keep global `ro.product.manufacturer` stock**, off by default, requires reboot). Turn this on if a banking/UPI app on KSU Unmount / DenyList (where Zygisk never injects) breaks whenever global `ro.product.manufacturer` is changed.
- Updates the module description on the KSU / APatch / Magisk module page with the detected Zygisk backend and RKP status.

If your keybox is not RKP (no `map[3]`) or your phone already matches, it won't touch anything.

## Install & hot-install

Flash the zip from Releases in KSU / APatch / Magisk. Remove or disable any old hardcoded module like `rkp_nubia` first.

- If you are updating from a previous version and the Zygisk native libraries did not change (WebUI / script-only updates), `customize.sh` hot-installs directly into `/data/adb/modules/rkp_mfr_auto` and clears KernelSU's pending `update` marker so the WebUI stays accessible right away without a reboot.
- On a first install or whenever the Zygisk `.so` changes, a reboot is required to load the new native library.
- You can also tap **Hot Apply** in the WebUI after swapping keyboxes.

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
- **Home**: shows Zygisk backend status, keybox type (tells you if it's not an RKP keybox so the module isn't needed), detected `map[3]` manufacturer, installed detector / Pixel Camera apps, current props, boot log, and a **Hot Apply** button.
- **Apps**: editable whitelist of installed apps excluded from spoofing (with search and a system-apps toggle; Pixel Camera, auto-detected GCam mods, and OEM cameras are marked `Fixed` so they never crash; no reboot required).
- **Settings**:
  - **Spoof `ro.product.vendor.manufacturer`** (off by default; requires reboot).
  - **Keep global `ro.product.manufacturer` stock** (off by default; requires reboot) — use this if a DenyList/Unmount banking or UPI app breaks with global manufacturer spoofing.
  - **Debug logging** (off by default; no reboot required) with **Capture Snapshot**, **Export to Download** (`/sdcard/Download/rkp_mfr_auto_log_<timestamp>.txt`), **Refresh**, **Copy**, and **Clear**.
  - **Color Theme** (`System`, `Light`, `Dark`, `AMOLED` — no reboot required) and GitHub links.

## Notes on camera apps & strict banking / UPI apps

- **Camera apps**: Pixel Camera, GCam mods (including cloned package names), and common OEM cameras are automatically detected and marked `Fixed` in the **Apps** tab so they receive your real stock manufacturer. Keep `ro.product.vendor.manufacturer` turned off in Settings unless a detector specifically flags it.
- **Strict banking / UPI apps**:
  1. First, try toggling the app on in the **Apps** whitelist and force-stopping/reopening it. User-whitelisted apps use stealth Java restore + immediate `dlclose` so no Zygisk `.so` stays mapped in memory.
  2. If the app still fails (usually because it is in KSU Unmount / Zygisk DenyList, which blocks Zygisk from injecting at all), turn on **Keep global `ro.product.manufacturer` stock** in WebUI **Settings** and reboot. That leaves `ro.product.manufacturer` untouched globally so DenyList apps see stock props with zero Zygisk maps, while non-whitelisted apps get stealth Java `Build.MANUFACTURER` spoofing.
  3. If you still hit issues, turn on **Enable debug log** in Settings, reproduce the issue once, tap **Export to Download**, and share the `.txt` file from `/sdcard/Download/`.

## Credits

- [dlagia](https://github.com/dlagia): original idea and RKP manufacturer fix script ([`archive/fix-rkp.sh`](archive/fix-rkp.sh)). This module grew from it.
- [ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint): the setup this was tested against.
