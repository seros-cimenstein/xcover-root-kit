# xcover-root-kit

Magisk/root tools for the **Samsung Galaxy XCover Pro (SM-G715FN, Exynos 9611, Android 13)**.
Each folder is a separate tool: a root shell script that runs on the phone (started at boot from
Magisk's `service.d`), plus an `install.sh` that builds, copies and controls it from a Linux PC
over adb.

| Tool | What it does | Phone side |
|---|---|---|
| [phone_cooler](phone_cooler/) | Switchable CPU/GPU clock caps (Off / Mild / Cool / Cold / Custom) to keep the phone cooler; Quick Settings tile and app | `cool.sh` daemon + Cooler app |
| [battery-optimiser](battery-optimiser/) | Measured battery settings (scanning off, 30 s timeout, aggressive Doze, charging capped at 85 %, slower charging), held by a daemon that also logs drain per screen state; Quick Settings tile and app | `battery.sh` daemon + Battery app |
| [xcover_guard](xcover_guard/) | Hold the XCover key to toggle "guard mode": screen dark and touches ignored while the phone stays awake for adb/automation agents | `guard.sh` listener + `touchgrab` (C, static arm64) |

## Warning

- **Device-specific.** Written for and tested only on one SM-G715FN. The sysfs paths, clock
  tables, input device names and Samsung settings they touch are specific to this phone and its
  Exynos 9611 kernel; on other devices they will at best do nothing.
- **Root required** (Magisk, with root allowed for adb's Shell).
- These tools write kernel tunables and system settings as root. **Use at your own risk.**

## Requirements (PC side)

- Linux with `adb`, and the phone reachable over adb (USB or `adb connect`). Each `install.sh`
  uses `$ANDROID_SERIAL` if set, else the only connected device.
- phone_cooler, battery-optimiser: a JDK. `android/build.sh` builds the APK without Gradle; the
  Android build-tools and platform jar are downloaded once (~150 MB) into `.sdk/` at the
  repository root, unless `SDK` / `ANDROID_BUILD_TOOLS` / `ANDROID_JAR` point elsewhere.
- xcover_guard: `zig` to cross-compile `touchgrab.c` for arm64.

## License

MIT, see [LICENSE](LICENSE).
