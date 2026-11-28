# RKP Manufacturer Auto-Match

[English](README.md) | [简体中文](README.zh-CN.md)

Simple KSU / APatch / Magisk module to auto-match manufacturer props with your active RKP keybox.

The original idea and the first RKP fix script come from [dlagia](https://github.com/dlagia). His untouched script is archived in [`archive/fix-rkp.sh`](archive/fix-rkp.sh). Big thanks to him.

Instead of hardcoding `nubia` (or whatever OEM the public RKP kb is from), this reads `map[3]` straight from the keybox that your keystore module actually uses at boot, and applies it via `resetprop`, with Zygisk handling Pixel Camera / whitelisted app restore. It keeps working when you switch to a different public RKP keybox later.

## Supported keystore modules

The module detects which keystore / attestation provider is installed and reads the keybox that provider uses:

| Keystore module | Module ID | Keybox location |
| --- | --- | --- |
| [Oh My Keymint](https://github.com/ITxiao6666/OhMyKeymint) | `oh_my_keymint` | `/data/misc/keystore/omk/keybox.xml` |
| [TrickyStore](https://github.com/5ec1cff/TrickyStore) | `tricky_store` | `/data/adb/tricky_store/keybox.xml` |
| [TrickyStore OSS](https://github.com/beakthoven/TrickyStoreOSS) | `tricky_store` | `/data/adb/tricky_store/keybox.xml` (+ `[file.xml]` headers in `target.txt`) |
| [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) | `tricky_store` | `/data/adb/tricky_store/keybox.xml` (+ `[file.xml]` headers in `target.txt`) |
| [TEESimulator](https://github.com/JingMatrix/TEESimulator) | `teesim` | keybox referenced by every profile in `/data/adb/teesim/config.json` |
| Unknown / legacy setup | - | `/data/adb/TEESimulator/keybox.xml`, `/data/adb/omk/keybox.xml` |

How the active keybox is chosen:

- **Enabled modules win over paths that only exist.** A leftover Oh My Keymint keybox no longer overrides an enabled TrickyStore / TEESimulator install, which used to apply the wrong manufacturer.
- **The highest-priority enabled module is authoritative** (TEESimulator, then the TrickyStore family, then Oh My Keymint). Its keyboxes are checked in order and the first RKP keybox with `map[3]` is applied.
- **Multi-keybox setups are understood.** TEESimulator profiles and TrickyStore / TEESimulator-RS `[file.xml]` headers are all parsed, so an alternate keybox is still found.
- **Conflicts are reported.** If more than one keystore module is enabled, or the keyboxes in use declare different manufacturers, the WebUI shows a compatibility warning instead of silently picking one.
- **Disabled modules are not used.** If the only keystore module is disabled, the module waits instead of spoofing from stale data.

Only one keystore module should stay active: they hook the same keystore path, and installing a second one usually disables or breaks the first.

## What it does

On boot (`post-fs-data`), it discovers the active keystore module and its keybox (see the table above), grabs the RKP manufacturer from the cert extension (`1.3.6.1.4.1.11129.2.1.30`, `map[3]`) using BusyBox `awk`/`base64`/`od`, and works together with **Zygisk** (required: ReZygisk, Zygisk Next, BreZygisk, NeoZygisk, Magisk Zygisk, or any compatible Zygisk provider):
- **Default mode**: sets `ro.product.manufacturer` and `ro.product.manufacturer_for_attestation` to the RKP manufacturer via `resetprop -n` so detectors pass natively while our Zygisk `.so` immediately calls `DLCLOSE_MODULE_LIBRARY` (leaving zero Zygisk maps in normal apps / detectors).
- **Pixel Camera**: only the real Pixel Camera (`com.google.android.GoogleCamera`) on a real Google Pixel or a Pixel based ROM gets your stock manufacturer back (`Build.MANUFACTURER` + native props) so it doesn't crash. GCam ports and OEM cameras are left alone, they don't need it.
- **User-whitelisted apps**: any app you toggle on in the WebUI **Apps** tab (saved in `/data/adb/rkp_mfr_auto.exclude`) gets a stealth Java `Build.MANUFACTURER` restore and immediately calls `DLCLOSE_MODULE_LIBRARY` so no resident PLT hook or `.so` map is left in `/proc/self/maps`.
- Updates the module description on the KSU / APatch / Magisk module page with the detected keystore module, Zygisk backend and RKP status.

If your keybox is not RKP (no `map[3]`) or your phone already matches, it won't touch anything.

## Install & hot-install

Flash the zip from Releases in KSU / APatch / Magisk. If an old hardcoded module like `rkp_nubia` is still present, `customize.sh` disables it non-destructively (it can be re-enabled from the manager) so both modules do not fight over `ro.product.manufacturer`.

- If you are updating from a previous version and the Zygisk native libraries did not change (WebUI / script-only updates), `customize.sh` hot-installs directly into `/data/adb/modules/rkp_mfr_auto` and clears KernelSU's pending `update` marker so the WebUI stays accessible right away without a reboot.
- On a first install, whenever the Zygisk `.so` changes, or when an update has to reset an old Zygisk setting, it installs the normal way and the module card asks for a reboot.
- You can also tap **Hot Apply** in the WebUI after swapping keyboxes or switching keystore modules.
- Removing the module runs `uninstall.sh`, which deletes `/data/adb/rkp_mfr_auto.*` and the private export directory. Props return to their stock values on the next reboot.

Check what got detected:
```sh
su -c cat /data/adb/modules/rkp_mfr_auto/last.log
```

Test detection without changing props:
```sh
su -c "/data/adb/ksu/bin/busybox sh /data/adb/modules/rkp_mfr_auto/post-fs-data.sh --dry-run"
```

`--dry-run` prints the detected keystore module, every keybox that was inspected, the chosen `map[3]` manufacturer and any compatibility warnings.

## WebUI

Open the module WebUI from KSU / APatch Manager:
- **Home**: shows Zygisk backend status, the detected keystore module, keybox type (tells you if it's not an RKP keybox so the module isn't needed), detected `map[3]` manufacturer, installed detector apps, a "Pixel Camera detected, fix applied" line when it applies, current props, boot log, and a **Hot Apply** button. Compatibility warnings (multiple keystore modules, conflicting manufacturers, TEESimulator manufacturer overrides, unsafe `map[3]` values) appear here too, and a **Possible Conflicts** card lists other enabled modules that set or mention the manufacturer props or shows props that were changed after this module.
- **Apps**: editable whitelist of installed apps excluded from spoofing (with search and a system-apps toggle; no reboot required). Pixel Camera is handled on its own and doesn't show up here.
- **Settings**:
  - **Debug logging** (off by default; no reboot required) with **Capture Snapshot**, **Export Log** (root-only copy at `/data/adb/rkp_mfr_auto_export/`, mode 0600), **Save to Download** (requires a second confirmation tap, because files in `/sdcard/Download` can be read by other apps with storage access), **Refresh**, **Copy**, and **Clear**.
  - **Language** (`System`, `简体中文`, `English`) — follows the system language by default and can be overridden per device.
  - **Color Theme** (`System`, `Light`, `Dark`, `AMOLED` — no reboot required) and GitHub links.

The WebUI is fully translated into English and Simplified Chinese; missing strings fall back to English.

## Notes on Pixel Camera & strict banking / UPI apps

- **Pixel Camera**: detected only on a real Pixel (brand / system manufacturer is `google`) or a Pixel based ROM. That means any of: the Google `com.google.android.feature.PIXEL_EXPERIENCE` flag is there, Pixel Camera comes preinstalled in the ROM, or the ROM's own props show it's PixelOS, Pixel Experience, Evolution X, Project Elixir, DerpFest, Infinity-X, PixelPlusUI, YAAP, AfterLife, Pixel Extended, Project Blaze, Voltage or Statix. Lineage based ROMs (crDroid etc.) without Pixel Camera built in are skipped. Check Home for "Pixel Camera detected, fix applied". If some other camera app crashes for you, just turn it on in the **Apps** whitelist.
- **Strict banking / UPI apps**:
  1. Toggle the app on in the **Apps** whitelist and force-stop/reopen it. User-whitelisted apps use stealth Java restore + immediate `dlclose` so no Zygisk `.so` stays mapped in memory.
  2. If you still hit issues, turn on **Enable debug log** in Settings, reproduce the issue once, tap **Save to Download**, and share the `.txt` file from `/sdcard/Download/`.

## Roadmap

Easiest first. Details in [docs/roadmap.md](docs/roadmap.md).

- [x] Auto-read `map[3]` manufacturer from the keybox
- [x] WebUI (Home / Apps / Settings, themes)
- [x] Zygisk per-app restore, Pixel Camera detection, editable whitelist
- [x] Debug log export, private by default with an explicit shared copy
- [x] Hot-install and KernelSU / Next update support
- [x] Oh My Keymint / TrickyStore / TrickyStore OSS / TEESimulator / TEESimulator-RS detection and keybox discovery
- [x] English + Simplified Chinese WebUI that follows the system language
- [x] Report issue button with prefilled fields
- [ ] Attestation-only test mode
- [ ] Props health check in WebUI
- [ ] Read-only keybox / OMK audit helper
- [ ] Zygisk Next (ZN) API mode
- [ ] Keep up with detector changes

## Credits

- [dlagia](https://github.com/dlagia): original idea and RKP manufacturer fix script ([`archive/fix-rkp.sh`](archive/fix-rkp.sh)). This module grew from it.
- [ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint): the setup this was originally tested against.
- [5ec1cff/TrickyStore](https://github.com/5ec1cff/TrickyStore), [beakthoven/TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS), [JingMatrix/TEESimulator](https://github.com/JingMatrix/TEESimulator), [Enginex0/TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS): supported keystore providers.
