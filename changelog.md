# v0.3.0

### Changes

- [`76c9d43`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/76c9d43ef0cc47be985565f48364f4cdf64805e2) auto-generate commit-linked changelog for pre-releases and full releases
- [`6bbeea0`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/6bbeea0fed6717c241ecc629fd1745c1a8d9a744) remove mobikwik mentions from readme and webui
- [`4aed68d`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/4aed68d6489067acd5499cb27338367f9e6799aa) add issue templates
- [`658d94d`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/658d94d55a2b4f016a47b74fa97c90936a61cacb) credit dlagia and archive his original fix-rkp.sh
- [`068a487`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/068a487eed4266023571d20a9395eebdfd354e35) update readme for stealth whitelist, stock global mode, gcam auto-detect, and debug logs
- [`d13686c`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/d13686c012a92d8396bf936c124fbcc5ccdcd4aa) stealth dlclose for user-whitelisted apps and stock global manufacturer option
- [`f16d6ac`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/f16d6ac655ebdde2eedffc38c93aaccecb5160a5) detect unknown or future zygisk providers generically by binaries and daemon
- [`344224d`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/344224d5f7dd377f549585dc8fd594770021cbc7) hot-install webui and scripts without pending update lock when zygisk libs are unchanged
- [`695086f`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/695086f1d9c8eddaac12c621aad0c7836ba81beb) style log and github buttons to follow webui themes
- [`fcf96de`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/fcf96de3b9edbe54cce92a02655d06d8476ff0f2) add export log to Download folder button
- [`2fd70bc`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/2fd70bc93755a21b2b5966e21b9671a375e0e751) auto-detect pixel camera and gcam mods by activity and native libs
- [`23dddc0`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/23dddc0ef18160c3c6b0b8c1c44074c191d63dc2) add debug logging toggle, diagnostic snapshot, and github link buttons
- [`e0498fd`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/e0498fd74a166de91d6a230acac6497b5dcad13c) fix zygisk backend detection, empty whitelist, and restore native rkp prop with inverse zygisk restore
- [`5d953cc`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/5d953cca1a1b2dc3dd64d7d1869c6573f54c8388) always dlclose zygisk library to avoid maps detection
- [`fcf83c3`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/fcf83c35dc58ad6653d704a3663c88bcc0ef3521) update repo urls for RKP-Mfr-Auto-Match and add editable installed-apps whitelist tab
- [`d7a68a9`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/d7a68a9bfd4b7caf589305ef94215ee5e07ff547) require zygisk, show backend indicator in module.prop, add waiting for reboot banner
- [`8bb1d60`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/8bb1d606e325bf41e44fad6016fdcf3173f92c2b) add -fno-threadsafe-statics for APP_STL=none
- [`67ee236`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/67ee23658263ee5148f0c279a437390640deff90) include sys/types.h before zygisk.hpp
- [`2d95673`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/2d9567362e125f1fbf95acbdcdd38aea07195e53) add zygisk per-app mode with camera exclusions and webui mode switcher
- [`0235e5b`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/0235e5b5cbded44a364e6f9cef364fa6ff61bc94) match auto pre-release versioning to vX.Y.Z-pre.N

...and 7 more commits. [See more](https://github.com/Najip/RKP-Mfr-Auto-Match/commits/v0.3.0)
