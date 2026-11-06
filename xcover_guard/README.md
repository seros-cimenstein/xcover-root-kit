# xcover_guard

Guard mode for the rooted Galaxy XCover Pro (SM-G715FN): **hold the XCover key** (left side) to
make the screen dark and ignore touches while an agent drives the phone. Hold it again to end it.

While guard mode is on:
- the screen is dark and every touch is ignored, including the Home/Back bar;
- the phone never sleeps or locks (screen timeout set to "never"), so agents keep working over
  adb: `input tap/swipe/text`, `uiautomator dump`, `screencap` (it still shows the real screen;
  only the backlight is off);
- the physical keys (power, volume, top key) still work.

Feedback: one buzz = on, two buzzes = off. A short press of the XCover key does nothing; it must
be held for at least 0.7 s, so pocket bumps don't toggle it.

Safety nets:
- if the screen goes off (power key), guard mode ends by itself, so the phone is normal when
  you wake it;
- a reboot always starts with guard mode off, and the saved brightness and timeout are restored;
- darkness is re-checked every 0.5 s and the touch block every 2 s while on;
- while off, no touch grab is ever left running: guard off kills any `touchgrab` process, and
  the watchdog sweeps once more a second later, so a lit screen always takes touches.
- the listener's pid file is checked against the process's command line before anything is
  killed: after a reboot its old numbers belong to other processes.

## Install / control (from the laptop, over adb)

```
./install.sh            # build touchgrab (zig), copy everything, start the key listener (also at boot)
./install.sh on|off     # switch it remotely
./install.sh status
./install.sh uninstall  # guard off, listener stopped, files removed
```

It uses `$ANDROID_SERIAL`, else the Tailscale address saved by `phone-adb` (part of a separate
remote-control setup, not in this repo), else the only adb device. Needs root for adb's shell
(Magisk: Shell allowed) and `zig` on the laptop to cross-compile the helper.

On the phone, agents can also run `su -c /data/adb/xcover-guard/guard.sh on|off|status`
(`stop` stops the listener).

## How it works

- **Touch block:** `touchgrab` (`touchgrab.c`, a static arm64 binary) holds an exclusive
  `EVIOCGRAB` on the `sec_touchscreen` input device, so Android's input system gets none of its
  events. Input injected by agents doesn't come from that device and still works. The driver's
  own "enabled" switch (`/sys/class/sec/tsp/input/enabled`) was tried first: it reads back 0 but
  touches still arrive. Grabs are found and killed by process name (`pidof`/`pkill -x
  touchgrab`); the saved `grab.pid` only lets the watchdog see the grab alive without forking.
- **Lock:** every switch (key, `on`/`off`/`toggle`) and every watchdog fix runs under `flock`
  on `lock`, so they never interleave. Without it, a watchdog re-grab could land between guard
  off's kill and its state removal, leaving a grab running with the screen lit.
- **Watchdog cost:** while off it sleeps on a fifo (`tick`) that guard on writes to: no polling.
  While on, the backlight is read every 0.5 s and the grab (saved pid + command line) every
  2 s with shell builtins; only the screen check forks (`dumpsys power`, every 2 s), and the
  lock is taken only to fix something. Measured: 0 CPU ticks in 10 s while off, 4.4 % of a
  core while on. The earlier version polled every 2 s while off with `pkill`, `flock` and
  subshells: 8.7 % of a core around the clock (2146 s of CPU in 7 h of uptime, 2026-11-03),
  and about 10 % while on.
- **Darkness:** the panel's `bl_power` is set to off and the raw brightness to 0. The panel driver
  relights the backlight whenever Android writes a brightness, even with `bl_power` off, so
  Android's brightness setting is also dropped to its minimum (1 of 306) and the watchdog puts
  the raw value back to 0 within 0.5 s. The user's brightness and timeout are saved in `state`
  and restored when guard mode ends.
- **Awake:** `screen_off_timeout` is set to "never" while on (tested 45 s past the normal 30 s
  timeout: the phone stayed awake and unlocked).
- **Key:** `guard.sh listen` reads the `gpio_keys` device with `getevent`; the XCover key is code
  252 (`00fc`). Devices are looked up by name, since the `eventN` numbers can change.
- `/data/adb/service.d/xcover-guard.sh`: Magisk starts the listener after every boot.
- The top key (KEY_MACRO17, Samsung: torch) is not used. If an app is later assigned to the
  XCover key in Settings > Advanced features, both that app and guard mode will react to it.

Test without touching the phone (simulated 1 s hold):

```
adb shell "su -c 'sendevent /dev/input/event4 1 252 1; sendevent /dev/input/event4 0 0 0; sleep 1; sendevent /dev/input/event4 1 252 0; sendevent /dev/input/event4 0 0 0'"
```
