# xcover_guard

Guard mode for the rooted Galaxy XCover Pro (SM-G715FN): **hold the XCover key** (left side) to
make the screen dark and ignore touches while an agent drives the phone. Hold it again to end it.

While guard mode is on:
- the backlight is off and the touchscreen is switched off at the driver
  (`/sys/class/sec/tsp/input/enabled`), so a hand, pocket or desk can't tap anything;
- the phone stays awake and unlocked (screen timeout set to "never"), so agents keep working
  over adb: `input tap/swipe/text`, `uiautomator dump`, `screencap` (it still shows the real
  screen; only the backlight is off);
- the physical keys (power, volume, top key) still work.

Feedback: one buzz = on, two buzzes = off. A short press of the XCover key does nothing; it must
be held for at least 0.7 s, so pocket bumps don't toggle it.

Safety nets:
- if the screen goes off (power key), guard mode ends by itself, so the phone is normal when
  you wake it;
- a reboot always starts with guard mode off;
- the backlight and touch are re-applied every 2 s while on, in case Android turns them back on.

## Install / control (from the laptop, over adb)

```
./install.sh            # copy guard.sh to the phone, start the key listener (and at every boot)
./install.sh on|off     # switch it remotely
./install.sh status
./install.sh uninstall  # guard off, listener stopped, files removed
```

It uses `$ANDROID_SERIAL`, else the Tailscale address saved by `phone-adb` (`../remote_control`),
else the only adb device. Needs root for adb's shell (Magisk: Shell allowed).

On the phone, agents can also run `su -c /data/adb/xcover-guard/guard.sh on|off|status`.

## How it works

- `guard.sh` (on the phone, `/data/adb/xcover-guard/`): `listen` reads the key device
  (`/dev/input/event4`, gpio_keys) with `getevent`; the XCover key is code 252 (`00fc`). A hold
  of 0.7 s or more toggles. A watchdog loop keeps backlight and touch off and ends guard mode
  when the screen turns off. `state` holds the backlight level and screen timeout to restore.
- `/data/adb/service.d/xcover-guard.sh`: Magisk starts it after every boot; it runs `listen`.
- The top key (KEY_MACRO17, Samsung: torch) is not used. If an app is later assigned to the
  XCover key in Settings > Advanced features, both that app and guard mode will react to it.

Test without touching the phone (simulated 1 s hold):

```
adb shell "su -c 'sendevent /dev/input/event4 1 252 1; sendevent /dev/input/event4 0 0 0; sleep 1; sendevent /dev/input/event4 1 252 0; sendevent /dev/input/event4 0 0 0'"
```
