# battery-optimiser

Cuts the battery drain of the rooted Galaxy XCover Pro (SM-G715FN, Exynos 9611, Android 13,
4050 mAh) and caps charging at 85 % so the cell lasts longer. One root script (`battery.sh`)
applies a set of measured settings, a small daemon keeps them applied, freezes chosen processes
(by default `mosh-client`) while the screen is off and logs the drain per screen state so the
result can be checked. The **Battery app** (Quick Settings tile + screen) switches it and sets
every knob from the phone.

The full write-up (where the battery went before, every knob and why, Doze exemptions, charging
heat, how it works, measurements) is in [docs/README-full.md](docs/README-full.md).

## What it changes

| knob | optimised value | stock (as found) |
|---|---|---|
| `wifi_scan`, `ble_scan` | Wi-Fi / Bluetooth LE "always scanning" off | on |
| `bluetooth` | off | on |
| `screen_timeout` | 30 s | never |
| `stay_awake` | screen goes off while charging | stays on while plugged in |
| `protect_battery` | Samsung "Protect battery": charging stops at 85 % | off |
| `fast_charge` | Samsung adaptive fast charging off (5 V instead of 9 V, less heat) | on |
| `doze` | aggressive Doze via DeviceConfig (deep Doze about 2 min after screen off) | stock |
| `exempt`, `exempt_sys` | keep (optional: take user or Google/Samsung Doze exemptions away) | keep |
| `allow` | none (optional: apps that stay Unrestricted) | none |
| `freeze` | `mosh-client` frozen while the screen is off | none |

`off` puts back the stock values recorded when each knob was first changed. CPU/GPU clocks are
not touched; that is [phone_cooler](../phone_cooler/)'s job.

## Install (from a Linux PC, over adb)

```
./install.sh            # build the app, copy battery.sh + boot launcher, apply the optimised values,
                        # start the daemon, stage the APK
./install.sh status     # every knob: now / optimised / stock, screen, battery, frozen processes
./install.sh report     # drain per screen state from the daemon's log, plus batterystats
./install.sh apply screen_timeout=60000 bluetooth=1   # change optimised values
./install.sh off        # put the stock values back (on: apply again)
./install.sh uninstall  # stock values back, daemon stopped, files removed
```

It uses `$ANDROID_SERIAL`, else the Tailscale address saved by `phone-adb` (part of a separate
remote-control setup, not in this repo), else the only adb device. Needs root for adb's shell
(Magisk: Shell allowed) and a JDK; the Android build tools come from `.sdk/` at the repository
root, downloaded on first build (see `android/build.sh`).

`install.sh` only copies the app to `/data/local/tmp/battery-optimiser.apk`; install it with
`adb shell pm install -r /data/local/tmp/battery-optimiser.apk` (if Play Protect asks, confirm
on the phone). Opening it the first time makes Magisk ask for root for "Battery".

## Status

Tested only on one Galaxy XCover Pro (SM-G715FN) on Android 13 with Magisk. The settings and
measurements are specific to that phone; root required, use at your own risk.
