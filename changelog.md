# v0.4.0

### Changes

- [`8ecca1e`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/8ecca1e7a0f6c3183b5edf3b3cd7b443e453984f) Report issue button checked as completed
- [`cd82487`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/cd82487f617ea24a873962e2b8d014e41f2a79fa) show real TEE module name and maintainer for variant builds
- [`852ad8c`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/852ad8cb9ff9770e91445b4f59bb2fc0962b9787) make app list scrollable inside fixed layout and add compact sort controls
- [`912b405`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/912b405de67f30a92166093fb71f523388dad4bb) clean up hot-apply install message and clear Pixel Camera cache only when detected
- [`dcdc3a9`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/dcdc3a9e1dfae30731a8ebf849c554a5b30bb167) add force stop and cache clear button for whitelist changes and random non-RKP standby messages
- [`54c59a7`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/54c59a78ebf1ece900704762a507214e9fd80e6d) push runs as canary CI only, improve install messages and module card status emojis
- [`bbec765`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/bbec76598e65e7ef04a86d21493e8fd9b5d0c0a4) add latest-ci and selected-ci options to promote workflow
- [`b8fb4ff`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/b8fb4ff5cce9f0752099996bcbcb50f8ebd0e9de) require debug log for report issue, smart debug reboot prompt, canary CI naming and promoter workflow
- [`0efab49`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/0efab49ab10d31af612b03523a53abddaccddac7) add pre-filled report issue button and update bug report template
- [`ca20d92`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/ca20d92ab0e344949028c4c5f0e68898e83e7fd3) upload module files directly as versioned CI artifact zip
- [`3544a95`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/3544a9524d285ffcd71dbbc84e7fbaaadf5ee167) detect built-in FolkZygisk, NyaZygisk and YukiZygisk backends
- [`90dbd8f`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/90dbd8fae9e09efa595a873fd62f0a37790f1862) read zygisk module name from module.prop so forks like BreZygisk show right
- [`2897a56`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/2897a569152d4fb322a9df68f19c5ef81686fd53) Fix false-positive keystore module detection
- [`47307e9`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/47307e9d5472bb1619d024684d4a3e5d5aed72d4) Add multi-keystore support, Chinese WebUI, and reliability fixes
- [`b389e5c`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/b389e5cba9b5bcdacfb1e820c6e462ab2093ac0d) add read-only conflict check for other modules touching manufacturer props
- [`c1e0934`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/c1e0934cc5ee04a26a2fc38bf2a61421c57483cb) skip hot-install when a zygisk setting gets reset, so the module card asks for reboot
- [`80a2bf7`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/80a2bf7d826f9c44cdc9432130bdab3bdc274af8) ask for reboot when an old prop toggle gets reset on update
- [`ade4547`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/ade4547bdcd98a47c618d54c2323c035df988b60) reset old prop toggles at install, add uninstall cleanup
- [`e10fe9d`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/e10fe9debc48b24787c762d9fbf3aa24ec41f9a7) hide prop toggles from webui and force them off
- [`1b509c0`](https://github.com/Najip/RKP-Mfr-Auto-Match/commit/1b509c017d1970e55f1afb3f6621edf9936b7a79) pixel rom check: match more pixel based roms by their props

...and 3 more commits. [See more](https://github.com/Najip/RKP-Mfr-Auto-Match/compare/v0.3.1...v0.4.0)
