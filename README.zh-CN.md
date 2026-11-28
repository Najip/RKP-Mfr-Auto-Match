# RKP 厂商自动匹配

[English](README.md) | [简体中文](README.zh-CN.md)

用于 KSU / APatch / Magisk 的简单模块：根据当前生效的 RKP 密钥库自动匹配厂商属性。

最初的想法与第一版 RKP 修复脚本来自 [dlagia](https://github.com/dlagia)，他的原始脚本归档在 [`archive/fix-rkp.sh`](archive/fix-rkp.sh)。非常感谢他。

本模块不再硬编码 `nubia`（或公开 RKP 密钥库所属的其他 OEM），而是在开机时直接从你的密钥库模块**实际使用**的 `keybox.xml` 中读取 `map[3]`，通过 `resetprop` 应用，并由 Zygisk 处理 Pixel 相机和白名单应用的恢复。之后更换其他公开 RKP 密钥库时仍然有效。

## 支持的密钥库模块

模块会检测设备上安装的密钥库 / 认证提供者，并读取该提供者使用的密钥库：

| 密钥库模块 | 模块 ID | 密钥库位置 |
| --- | --- | --- |
| [Oh My Keymint](https://github.com/ITxiao6666/OhMyKeymint) | `oh_my_keymint` | `/data/misc/keystore/omk/keybox.xml` |
| [TrickyStore](https://github.com/5ec1cff/TrickyStore) | `tricky_store` | `/data/adb/tricky_store/keybox.xml` |
| [TrickyStore OSS](https://github.com/beakthoven/TrickyStoreOSS) | `tricky_store` | `/data/adb/tricky_store/keybox.xml`（以及 `target.txt` 中的 `[file.xml]` 标题） |
| [TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS) | `tricky_store` | `/data/adb/tricky_store/keybox.xml`（以及 `target.txt` 中的 `[file.xml]` 标题） |
| [TEESimulator](https://github.com/JingMatrix/TEESimulator) | `teesim` | `/data/adb/teesim/config.json` 中每个 profile 引用的密钥库 |
| 未知 / 旧版环境 | - | `/data/adb/TEESimulator/keybox.xml`、`/data/adb/omk/keybox.xml` |

当前密钥库的选择规则：

- **已启用的模块优先于仅存在于磁盘上的路径。** 残留的 Oh My Keymint 密钥库不会再覆盖已启用的 TrickyStore / TEESimulator，此前这会导致应用错误的厂商。
- **优先级最高的已启用模块具有决定权**（TEESimulator → TrickyStore 系列 → Oh My Keymint）。按其密钥库顺序检查，第一个包含 `map[3]` 的 RKP 密钥库生效。
- **支持多密钥库配置。** 会解析 TEESimulator 的 profile，以及 TrickyStore / TEESimulator-RS 的 `[file.xml]` 标题，因此备用密钥库也能被发现。
- **冲突会被报告。** 若同时启用多个密钥库模块，或正在使用的密钥库声明了不同的厂商，WebUI 会显示兼容性提示，而不是静默选择其中一个。
- **不会使用已禁用的模块。** 如果唯一的密钥库模块处于禁用状态，模块会等待，而不是用过期数据伪装。

同一时间只应保留一个密钥库模块：它们挂接同一个 keystore 路径，安装第二个通常会禁用或破坏第一个。

## 功能

开机时（`post-fs-data`），模块先检测当前生效的密钥库模块及其密钥库（见上表），然后用 BusyBox 的 `awk` / `base64` / `od` 从证书扩展（`1.3.6.1.4.1.11129.2.1.30`，`map[3]`）中提取 RKP 厂商，并与 **Zygisk** 配合（必需：ReZygisk、Zygisk Next、BreZygisk、NeoZygisk、Magisk Zygisk，或任何兼容的 Zygisk 提供者）：

- **默认模式**：通过 `resetprop -n` 将 `ro.product.manufacturer` 和 `ro.product.manufacturer_for_attestation` 设为 RKP 厂商，使检测器在无 Zygisk 映射的情况下通过；我们的 Zygisk `.so` 会立即调用 `DLCLOSE_MODULE_LIBRARY`（普通应用 / 检测器中不残留任何 Zygisk 映射）。
- **Pixel 相机**：仅当真实 Pixel 相机（`com.google.android.GoogleCamera`）安装在真正的 Google Pixel 或基于 Pixel 的 ROM 上时，才恢复原始厂商（`Build.MANUFACTURER` + native 属性），以避免崩溃。GCam 移植版和 OEM 相机不做处理。
- **用户白名单应用**：在 WebUI **应用** 页开启的应用（保存在 `/data/adb/rkp_mfr_auto.exclude`）会通过隐蔽的 Java `Build.MANUFACTURER` 恢复，并立即调用 `DLCLOSE_MODULE_LIBRARY`，因此 `/proc/self/maps` 中不会残留常驻的 PLT hook 或 `.so` 映射。
- 在 KSU / APatch / Magisk 模块页面更新描述，显示检测到的密钥库模块、Zygisk 后端和 RKP 状态。

如果密钥库不是 RKP（没有 `map[3]`），或手机已经匹配，则不会修改任何内容。

## 安装与热安装

在 KSU / APatch / Magisk 中刷入 Releases 里的 zip。如果仍存在 `rkp_nubia` 这类旧的硬编码模块，`customize.sh` 会以非破坏性方式将其禁用（可在管理器中重新启用），避免两个模块同时修改 `ro.product.manufacturer`。

- 如果从旧版本升级且 Zygisk native 库未改变（仅 WebUI / 脚本更新），`customize.sh` 会直接热安装到 `/data/adb/modules/rkp_mfr_auto`，并清除 KernelSU 的待处理 `update` 标记，使 WebUI 无需重启即可立即访问。
- 首次安装、Zygisk `.so` 发生变化，或此次更新需要重置旧的 Zygisk 设置时，会走普通安装流程，模块卡片会提示重启。
- 更换密钥库或切换密钥库模块后，也可以在 WebUI 中点击 **立即应用**。
- 卸载模块时会执行 `uninstall.sh`，删除 `/data/adb/rkp_mfr_auto.*` 和私有导出目录。属性会在下次重启后恢复原始值。

检查检测结果：
```sh
su -c cat /data/adb/modules/rkp_mfr_auto/last.log
```

在不修改属性的情况下测试检测：
```sh
su -c "/data/adb/ksu/bin/busybox sh /data/adb/modules/rkp_mfr_auto/post-fs-data.sh --dry-run"
```

`--dry-run` 会输出检测到的密钥库模块、检查过的所有密钥库、选中的 `map[3]` 厂商以及兼容性提示。

## WebUI

从 KSU / APatch 管理器打开模块 WebUI：
- **首页**：显示 Zygisk 后端状态、检测到的密钥库模块、密钥库类型（如果不是 RKP 密钥库，会提示无需本模块）、检测到的 `map[3]` 厂商、已安装的检测器应用、应用修复时的 Pixel 相机提示、当前属性、启动日志，以及 **立即应用** 按钮。兼容性提示（多个密钥库模块、厂商冲突、TEESimulator 厂商覆盖、不安全的 `map[3]` 值）也会显示在这里；**可能的冲突** 卡片会列出其他会设置或提及厂商属性的已启用模块，并显示在本模块之后被修改过的属性。
- **应用**：可编辑的免伪装应用白名单（支持搜索和系统应用开关；无需重启）。Pixel 相机单独处理，不会出现在这里。
- **设置**：
  - **调试日志**（默认关闭；无需重启），包含 **抓取快照**、**导出日志**（保存到 `/data/adb/rkp_mfr_auto_export/`，权限 0600，仅 root 可读）、**保存到下载目录**（需要二次确认，因为 `/sdcard/Download` 中的文件可能被具有存储权限的其他应用读取）、**刷新**、**复制** 和 **清除**。
  - **语言**（`跟随系统`、`简体中文`、`English`）——默认跟随系统语言，也可在设备上手动覆盖。
  - **颜色主题**（`跟随系统`、`浅色`、`深色`、`AMOLED`——无需重启）以及 GitHub 链接。

WebUI 已完整翻译为英文和简体中文，缺失的字符串会回退到英文。

## 关于 Pixel 相机与严格的银行 / UPI 应用

- **Pixel 相机**：仅在真正的 Pixel（品牌 / 系统厂商为 `google`）或基于 Pixel 的 ROM 上检测。判断依据包括：存在 Google 的 `com.google.android.feature.PIXEL_EXPERIENCE` 特性、ROM 预装 Pixel 相机，或 ROM 自身属性表明其为 PixelOS、Pixel Experience、Evolution X、Project Elixir、DerpFest、Infinity-X、PixelPlusUI、YAAP、AfterLife、Pixel Extended、Project Blaze、Voltage 或 Statix。未内置 Pixel 相机的 Lineage 系 ROM（如 crDroid）会被跳过。可在首页查看 Pixel 相机修复提示。如果其他相机应用崩溃，将其加入 **应用** 白名单即可。
- **严格的银行 / UPI 应用**：
  1. 先在 **应用** 白名单中开启该应用，然后强行停止并重新打开。白名单应用使用隐蔽的 Java 恢复并立即 `dlclose`，内存中不会保留 Zygisk `.so`。
  2. 如果仍有问题，请在设置中开启 **启用调试日志**，复现一次问题，点击 **保存到下载目录**，并分享 `/sdcard/Download/` 中的 `.txt` 文件。

## 路线图

由易到难，详情见 [docs/roadmap.md](docs/roadmap.md)。

- [x] 从密钥库自动读取 `map[3]` 厂商
- [x] WebUI（首页 / 应用 / 设置，主题）
- [x] Zygisk 按应用恢复、Pixel 相机检测、可编辑白名单
- [x] 调试日志导出（默认私有，可显式保存到下载目录）
- [x] 热安装以及 KernelSU / Next 更新支持
- [x] Oh My Keymint / TrickyStore / TrickyStore OSS / TEESimulator / TEESimulator-RS 检测与密钥库发现
- [x] 跟随系统语言的英文 + 简体中文 WebUI
- [x] 带预填字段的问题报告按钮
- [ ] 仅认证测试模式
- [ ] WebUI 属性健康检查
- [ ] 只读密钥库 / OMK 审计助手
- [ ] Zygisk Next（ZN）API 模式
- [ ] 跟进检测器变化

## 致谢

- [dlagia](https://github.com/dlagia)：最初的想法与 RKP 厂商修复脚本（[`archive/fix-rkp.sh`](archive/fix-rkp.sh)），本模块由此发展而来。
- [ITxiao6666/OhMyKeymint](https://github.com/ITxiao6666/OhMyKeymint)：最初测试所用的环境。
- [5ec1cff/TrickyStore](https://github.com/5ec1cff/TrickyStore)、[beakthoven/TrickyStoreOSS](https://github.com/beakthoven/TrickyStoreOSS)、[JingMatrix/TEESimulator](https://github.com/JingMatrix/TEESimulator)、[Enginex0/TEESimulator-RS](https://github.com/Enginex0/TEESimulator-RS)：受支持的密钥库提供者。
