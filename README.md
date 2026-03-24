# palazikBox

> ColorOS 16 / OxygenOS 16 porting toolkit for Xiaomi 11 Ultra/Pro  
> By [@tm_palaziks](https://t.me/tm_palaziks) · Version V2.0 (Bash)

---

## Overview

**palazikBox** is an interactive bash script that automates the process of porting ColorOS 16 / OxygenOS 16 to Xiaomi devices. It handles partition merging, build.prop patching, smali-level APK/JAR modifications, debloating, and more — all from a simple numbered menu.

---

## Requirements

- Linux (Arch, Manjaro, Debian, Ubuntu, Android, or derivatives)
- Java JDK 8+
- Python 3
- `sed`, `awk`, `find` (standard GNU tools)
- Unpacked ColorOS ROM partitions in the working directory
- `RES/` folder with all required resource files (see below)

---

## Quick Start

```bash
# 1. Download or extract palazikBox to a folder
cd palazikbox

# 2. Run setup — installs dependencies and downloads APKEditor.jar
bash setup.sh

# 3. Place your unpacked ROM partitions in this directory
#    (system/, product/, system_ext/, my_*, vendor/, etc.)

# 4. Add your apex's, overlays and more to RES/RES/

# 5. Launch the porter
bash cos_toolbox.sh
```

---

## File Structure

```
palazikBox/
├── cos_toolbox.sh        # Main porting script
├── setup.sh              # Dependency installer
├── README.md
│
├── tools/
│   └── APKEditor.jar     # Downloaded automatically by setup.sh
│
├── RES/                  # Your resource files (provide yourself)
│   ├── RES/              # Generic ROM overlay files
│   ├── face/             # Face unlock files + face.dex
│   ├── FOD/              # systemui.dex + services.dex
│   ├── privacy/          # settings.dex + safecenter.dex
│   ├── brightness/       # MTK brightness config files
│   ├── vibration/        # Vibration config files
│   ├── odmhals/          # ODM HAL files + file_contexts.txt
│   ├── optimization/     # ROM optimization files
│   └── nadswap/          # NAND swap files
│
├── config/ (file contexts)
├── system/               # Unpacked ROM partitions (you provide)
├── system_ext/
├── product/
├── vendor/
├── odm/
├── my_bigball/
├── my_carrier/
└── ...
```

---

## Menu Options

| # | Option | Description |
|---|--------|-------------|
| 1 | **Full Port** | Runs all 5 base steps in sequence |
| 2 | Fix SuperVOOC | Patches charging animation in `oplus-services.jar` + `SystemUI.apk` |
| 3 | Fix AOD | Patches doze override methods in `oplus-services.jar` |
| 4 | Fix 24H Fullscreen AOD | Patches `SmoothTransitionController` in `SystemUI.apk` |
| 5 | Fix Face Unlock | Copies face files, patches `services.jar` + `SystemUI.apk` |
| 6 | Fix FOD | Injects FOD dex into `SystemUI.apk` + `services.jar` |
| 7 | Fix FOD Animation | Patches `OnScreenFingerprintUiMech` in `SystemUI.apk` |
| 8 | Fix Video Playback | Removes SR video features from multimedia XML |
| 9 | Fix Brightness (MTK) | Copies brightness files + adds AMOLED props |
| 10 | Fix OPlus Privacy | Injects privacy dex into `Settings.apk` + `SafeCenter.apk` |
| 11 | Fix NAND Swap | Adds swap props + copies nadswap files |
| 12 | Fix Vibration | Copies vibration config files |
| 13 | Fix Device Specs | Interactively sets device name, CPU, camera, screen props |
| 14 | Fake Enforcing | Writes SELinux chmod rules to `init.<codename>.rc` |
| 15 | Spoof Bootloader | Adds locked/verified boot props to `vendor/build.prop` |
| 16 | Disable Signature Verification | Patches signature scheme checks in `services.jar` |
| 17 | Disable Secure Flag | Patches `Window.setFlags()` in `framework.jar` (enables screenshots) |
| 18 | Add ODM HALs | Copies ODM HAL files + appends SELinux contexts |
| 19 | Optimize ROM | Copies optimization files + adds my_* partition imports |
| 20 | Debloat ROM | Removes a predefined list of bloatware apps |
| 21 | About | Credits and version info |

### Full Port steps (mode 1)

1. Merge `my_*` partitions into `system/`
2. Copy `RES/RES/` overlay files
3. Add `my_*` partition imports to `system/system/build.prop`
4. Remove screen zoom props from `system/my_product/build.prop`
5. Add extra display props (density, resolution)

---

## How APK/JAR Patching Works

All APK and JAR files are processed using **APKEditor**:

```bash
# Unpack
java -jar tools/APKEditor.jar d -f -i file.apk -o output_folder/

# Repack
java -jar tools/APKEditor.jar b -i output_folder/ -o new_file.apk
```

Smali files inside unpacked folders are patched using `sed` and inline `python3` for multi-line regex patterns. No `smali.jar` or `baksmali.jar` needed.

---

## Backup

Every APK/JAR that gets modified is automatically backed up before patching:

```
SystemUI.apk      →  SystemUI.apk.bak
services.jar      →  services.jar.bak
framework.jar     →  framework.jar.bak
```

Backups are created only once — re-running a mode will not overwrite an existing `.bak`.

---

## Logs

All operations are logged to:

```
logs/palazikbox.log
```

If something fails, check the log for the full error output.

---

## Credits

- [@trdyun](https://coolapk.com) (Coolapk)
- [@rianixia](https://github.com/rianixia)
- @LazyBones
- Danda
- @兰微塔鱼 (Coolapk)
- gabi
- @mi12autism
- @lnsiv

---

## License

Personal / educational use only. Not affiliated with OPPO, OnePlus, or Xiaomi.
