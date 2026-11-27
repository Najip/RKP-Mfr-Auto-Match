# Roadmap details

Short notes on what's planned, easiest first. Nothing here is promised, it depends on what detectors do and what I can test on my own phone (tested with OhMyKeymint; TrickyStore, TrickyStore OSS, TEESimulator and TEESimulator-RS are detected and their keyboxes are read, but reports from those setups are welcome).

## Why

Detection of a global `ro.product.manufacturer` change is easy if a detector compares it with the other `ro.product.*.manufacturer` props, `build.prop` or the fingerprint. So the plan is to touch less globally and do more per process.

## 0. Multi keystore provider support (done)

The module now finds the keystore module that is actually enabled (Oh My Keymint, TrickyStore, TrickyStore OSS, TEESimulator, TEESimulator-RS), follows its real keybox (including TEESimulator profiles and `[file.xml]` headers in `target.txt`), and warns about multiple enabled modules or keyboxes that disagree about the manufacturer. Next step would be per-provider quirks, for example reading TEESimulator's profile identity instead of only `map[3]`.

## 1. Attestation-only test mode (easy)

Only set `ro.product.manufacturer_for_attestation` and leave `ro.product.manufacturer` alone. If the detector passes like this, nothing else needs to be spoofed and Pixel Camera / banking apps don't need any workaround. Will be a toggle in Settings, off by default, needs reboot.

## 2. Props health check in WebUI (easy)

Read-only check on the Home tab. Shows if manufacturer props across system / vendor / odm / product agree with each other and with the fingerprint, so you can see what a detector would see. Changes nothing.

## 3. Report issue button (done)

Button in Settings that asks for confirmation, collects version, device, root manager, Zygisk backend, keystore setup and a short diagnostic log, and opens the GitHub bug report form with those fields pre-filled. No background network, nothing is sent unless you submit it on GitHub.

## 4. Keybox sync helper (medium)

Optional helper based on the idea from dlagia's `omk-keybox-sync.sh` (keybox swap, graceful OMK restart, audit). Only the read-only audit part is planned inside the module. Clearing Play Store data or editing other modules' configs stays out of it.

## 5. Zygisk Next (ZN) API mode (hard)

Native-only module using the Zygisk Next API (`zn_module`) for Zygisk Next, NyaZygisk and ZNNext. Idea is to hook property reads only in the processes that need it (keystore2 / attestation) so global props stay stock. Auto-enabled when a ZN-capable backend is detected, normal Zygisk stays as fallback. Needs a lot of testing, and it won't help if the detector compares the RKP cert directly against props inside its own process.

## 6. Keep up with detector changes (ongoing)

Duck Detector already has an RKP manufacturer check. Google could tighten RKP metadata checks later too. I'll adjust when something changes, the debug log helps a lot here.
