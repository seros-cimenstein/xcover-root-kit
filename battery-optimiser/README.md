# battery-optimiser

Cuts the battery drain of the rooted Galaxy XCover Pro (SM-G715FN, Exynos 9611, Android 13,
4050 mAh) and caps charging at 85 % so the cell lasts longer. One root script (`battery.sh`)
applies a set of measured settings, a small daemon keeps them applied, freezes `mosh-client`
while the screen is off and logs the drain per screen state so the result can be checked.

Everything the remote-control setup needs keeps working: Tailscale, adb over Tailscale
(`../remote_control`), DevDeck/DevDeck+, Termux and PhoneDeck are on the user Doze whitelist,
so the stronger Doze doesn't cut their network. CPU/GPU clocks are `../phone_cooler`'s job;
nothing here touches them.

```
./install.sh            # copy battery.sh + boot launcher, apply the optimised values, start the daemon
./install.sh status     # every knob: now / optimised / stock, screen, battery, frozen processes
./install.sh report     # drain per screen state from the daemon's log, plus batterystats
./install.sh apply screen_timeout=60000 bluetooth=1   # change optimised values
./install.sh off        # put the stock values back (on: apply again)
./install.sh uninstall  # stock values back, daemon stopped, files removed
```

## Where the battery went (before)

`dumpsys batterystats --charged` on 2026-10-24, covering 29 h on battery since 10-22 23:03
(several top-ups in between, 8045 mAh discharged in total):

| | time | used | average |
|---|---|---|---|
| screen off | 18 h 49 m | 3595 mAh | **191 mA** (4.7 %/h) |
| screen on | 10 h 26 m | 4450 mAh | 426 mA |

A phone in deep sleep draws well under 20 mA, so the screen-off drain was the problem:

- **The CPU was awake 91 % of the screen-off time** (17 h 13 m uptime of 18 h 49 m), and the
  LTE radio was active 21 h of the 29 h. 23,847 wakeups came from the modem (`INT_MBOX_CP2AP`),
  one every 4.4 s: network packets.
- **Tailscale was the largest consumer: 2572 mAh** (2119 mAh of it LTE radio, 14 h 29 m radio
  active, 1 h 48 m of CPU). It carries all the remote traffic: adb from the laptop (uid 2000:
  116 MB sent, radio 2 h 27 m), DevDeck+ and mosh.
- **mosh in Termux ran in the background for 19 h** (radio 2 h 11 m; 139,270 packets received,
  110,432 sent, about 1.6 per second each way). mosh-client sends a heartbeat every 3 s, and the
  LTE radio stays in its high-power state for several seconds after each packet, so it never
  got to idle while mosh was open.
- **Bluetooth scanned for the whole 29 h with no paired device at all** (bonded devices:
  none): Google Play services (Fast Pair / Eddystone filters, low-power mode) and a Samsung
  system scanner.
- **Wi-Fi was off, but the chip was in "scanning" state 21 h** ("Wi-Fi scanning" for location);
  3184 wakeups from the Wi-Fi/BT chip (`INT_MBOX_WLBT2AP`). The kernel log showed a scan every
  123 s.
- **Deep Doze was reached only 3 times** (8 h in total, light Doze 9 h): stock Doze waits
  15 min after the screen goes off, then another 20 min with no motion.
- **The screen never timed out** (`screen_off_timeout` = 2147483647, "never") and **stayed on
  whenever the phone was plugged in** (`stay_on_while_plugged_in` = 7: AC, USB and wireless),
  which also heats the battery while it charges.
- Other apps were minor: Brave 1008 mAh (screen and audio, 3 h), WhatsApp 992 mAh (camera,
  32 min of video calls), DevDeck+ 648 mAh (screen-on use; its link wakelock is only held while
  it is visible), Google Play services 154 mAh.

## What it changes

| knob | setting | stock (found) | optimised | why | held |
|---|---|---|---|---|---|
| `wifi_scan` | `global wifi_scan_always_enabled` | 1 | 0 | stops the Wi-Fi chip scanning for location while Wi-Fi is off | yes |
| `ble_scan` | `global ble_scan_always_enabled` | 1 | 0 | stops apps scanning Bluetooth LE while Bluetooth is off | yes |
| `bluetooth` | `cmd bluetooth_manager enable/disable` | on | off | nothing is paired; ends Google Play services' constant LE scanning | no |
| `screen_timeout` | `system screen_off_timeout` | never | 30000 (30 s) | with "never" the panel stayed lit until the power button; the screen-on average was 426 mA | no |
| `stay_awake` | `global stay_on_while_plugged_in` | 7 | 0 | screen off while charging: less power and less heat in the charging cell | no |
| `protect_battery` | `global protect_battery` | 0 | 1 | Samsung's "Protect battery": charging stops at 85 % (`batt_full_capacity`) | yes |
| `doze` | DeviceConfig `device_idle` | stock | aggressive | deep Doze about 2 minutes after the screen goes off instead of 35 min at the earliest | yes |
| `freeze` | cgroup freezer | none | `mosh-client` | processes frozen while the screen is off (see below) | daemon |

"Held" knobs are put back by the daemon if something changes them (checked each time the
screen goes off). `protect_battery` is also watched through the kernel limit every 5 s round,
since Samsung turns it off by itself after a long time on the charger; the daemon toggles the
setting once to make BatteryService write 85 again. The others are applied once by `on`/`apply`: turning
Bluetooth on for headphones or changing the timeout in Settings sticks. To keep a different
value, set it as the optimised value: `./install.sh apply bluetooth=1`.

Allowed values (`./install.sh knobs` lists them):

- `wifi_scan`, `ble_scan`, `bluetooth`, `protect_battery`: 0 or 1.
- `screen_timeout`: 15000, 30000, 60000, 120000, 300000, 600000, 1800000, 2147483647 (never), ms.
- `stay_awake`: 0..7, a bit mask (1 AC, 2 USB, 4 wireless).
- `doze`: `stock` or `aggressive`.
- `freeze`: `none`, or a comma list of process names as in `/proc/<pid>/comm` (at most 15
  characters), e.g. `freeze=mosh-client,ssh`.

`apply` validates everything first and writes nothing unless all of it is valid. `off` puts
back the stock values recorded when each knob was first changed and forgets them; the next
`on` records fresh ones.

### Doze

Stock (Samsung's values on this phone) and optimised DeviceIdleController constants:

| constant | stock | optimised |
|---|---|---|
| `light_after_inactive_to` (screen off to light Doze) | 1 min | 15 s |
| `light_idle_to` / `light_max_idle_to` (light Doze window, grows to the max) | 5 min / 20 min | 15 min / 1 h |
| `inactive_to` (screen off to the deep-Doze path) | 15 min | 30 s |
| `idle_after_inactive_to` (idle-pending to sensing) | 20 min | 15 s |
| `motion_inactive_to` (wait after motion before trying again) | 7 min | 1 min |

On Android 13 these live in DeviceConfig (`device_config put device_idle ...`); the old
`global device_idle_constants` setting is ignored (tested: a value written there did not show
up in `dumpsys deviceidle`). `sensing_to` and `locating_to` stay stock: in Android 13 a sensing
timeout restarts the progression instead of skipping the check, so setting them to 0 (as old
"aggressive Doze" guides do) would keep the phone out of deep Doze.

What Doze holds back: network, jobs, syncs and ordinary alarms of apps not on the whitelist,
until the next maintenance window. Push messages that apps send as high priority (WhatsApp,
banking) still arrive through Google Play services. The user whitelist (`dumpsys deviceidle
whitelist`): Tailscale, DevDeck+, DevDeck, Termux, Termius, PhoneDeck; system apps such as
Google Play services, the dialer and messages are exempt as before.

### Freezing while the screen is off

When the screen goes off the daemon moves every process whose name is in `freeze` into its own
cgroup-v1 freezer group (`/dev/freezer/battery-optimiser`) and freezes it; when the screen comes
on it thaws them and moves them back. A frozen process just isn't scheduled. Unlike `SIGSTOP`,
its parent doesn't notice: a `SIGSTOP`ped `mosh` would be reported to Termux's bash as a stopped
job, bash would take the terminal back, and the resumed client would be stuck in the
background. Tested with a stand-in process under a parent shell: frozen, its counter stood
still for 3 s; thawed, it went on, and the parent saw nothing.

mosh is built for this: the server stops sending after 40 s without hearing from the client
(`SERVER_ASSOCIATION_TIMEOUT`), keeps the session, and the client catches up on the first
packet after it thaws. So with the screen off, mosh costs nothing after 40 s, instead of
keeping the LTE radio up with a packet every 3 s. Children forked by a frozen process are
frozen with it.

"Screen off" means the panel's raw backlight (`/sys/class/backlight/panel/brightness`) is 0
while `../xcover_guard`'s guard mode is off. Guard mode holds the backlight at 0 with the display
on while agents drive the phone, so it counts as on. The daemon checks every 5 s of awake time,
so a process thaws at most 5 s after the screen comes on. Samsung's "early wake-up"
(`setEarlyWakeUp` in logcat) lights the panel before the phone is interactive, and that counts
as on too: at 13:31:14 the log shows 11 s "on" while Doze, which only looks at the interactive
state, stayed idle.

### Screen timeout and guard mode

Guard mode sets the timeout to "never" and puts its saved value back when it ends. While guard
mode is on, `battery.sh` reads and writes the timeout in guard's state file
(`/data/adb/xcover-guard/state`, `timeout=` line) instead, so guard ends with the optimised
timeout. Agents that drive the phone without guard mode need `input keyevent KEYCODE_WAKEUP`
after 30 s of no input.

## What it doesn't change (and why)

- **CPU/GPU clocks**: `../phone_cooler`. Its custom profile was at the lowest steps when this
  was written (little 403 MHz, big 936 MHz, GPU 260 MHz). The live rail voltages at those steps
  were 600 mV (little), 687 mV (big) and 581 mV (GPU, its floor). The ECT table puts the next
  little step (598 MHz) at 656 mV, so each cycle at 403 MHz costs about (600/656)^2 = 84 % of
  the switching energy of one at 598 MHz: the bottom of the little cluster is not yet at a
  voltage floor where running faster would be free.
- **Undervolting**: not possible on the stock kernel (see phone_cooler's Limits).
- **Tailscale, adb, DevDeck+**: the largest remaining drain is the always-on Tailscale link
  over LTE. Its keepalives, adb sessions and DevDeck+'s link (pings every 10 s while visible,
  every 10 min when hidden) are what remote control needs. Wi-Fi is far cheaper than LTE for
  the same link (in the stats above: Wi-Fi 21 mAh for 8 h connected; LTE radio 3157 mAh), so
  being on Wi-Fi is the biggest thing left.
- **Samsung's system BLE scanner**: with Bluetooth off, a system_server component (Samsung
  manufacturer filter, id 75) keeps the controller in `BLE_ON` and scans 160 ms out of every
  3120 ms (5 %). Turning BLE scanning off, Bluetooth off again and Multi control off did not
  stop it; it is part of system_server and was left alone. Google's scans stopped.
- **Wakelock blocking**: needs a custom kernel; the stock one has no wakelock blocker.
- **Android's cached-apps freezer** (`use_freezer`): needs a cgroup-v2 `cgroup.freeze`, which
  this 4.14 kernel lacks; Samsung's own freezer (Freecess, `/dev/freezer/frozen`) does that job.
- **Battery saver** (`low_power`): it also limits the CPU (phone_cooler covers that) and turns
  off background data for apps not exempt from it, which risks the remote-control links.
  Its useful part for standby, faster deep Doze, is in the `doze` knob.
- **Load average of 17-18**: it is not CPU use. 16 TrustZone and storage kernel threads
  (`tz_worker_thread`, `tz_iwsock`, `scsi_srpmb_work`, ...) wait in uninterruptible sleep (D)
  all the time, and Linux counts D tasks in the load average.
- **Log volume**: 4139 lines a minute while typing, almost all Samsung input/IME logging; it
  stops with the screen off. Raising the global log level would also hide the `log -t` lines of
  these tools.
- **Animations** (already 0.5x), **dark mode** (an LCD panel gains nothing from it), brightness
  (a personal choice; manual 120 of 255): untouched.

## How it works

- `battery.sh` (`/data/adb/battery-optimiser/`) applies each knob whose live value differs and
  records the value it replaced in `stock`; the optimised values are the defaults in the script,
  overridden by `settings` (`key=value` lines, written by `apply`); `state` says on or off.
- `/data/adb/service.d/battery-optimiser.sh`: Magisk runs it after boot; it waits for boot
  completion and starts `battery.sh daemon`, which re-applies the held knobs, then wakes every
  5 s of awake time: builtin reads only (backlight, guard state file, battery status, the
  optimiser's state file, the kernel charge limit), and a
  timed `read` on a fifo (`tick`) instead of `sleep`, so a round forks nothing. On a screen
  change it freezes or thaws, checks the held knobs (this part forks `settings` and
  `device_config`) and logs. Commands wake it through the fifo when the state or settings change.
  A timer that isn't a wakeup alarm doesn't wake a suspended phone, so the daemon doesn't keep
  it awake.
- `drain.log`: one line per screen change, charger change and daemon start:
  `<epoch s> <event> <screen> <battery status> <charge counter uAh> <level %>`. `report` adds up
  the intervals that started on battery per screen state (skipping those that end at a daemon
  start: a reboot or reinstall) and lists the screen-off stretches of 30 min or more; then the same
  numbers from batterystats since the last full charge.
- The daemon logs to logcat as `battery-optimiser` (re-applied knobs, freezes).

## Measurements (after)

2026-10-24, right after `./install.sh`:

- Bluetooth classic off; Google Play services' LE scans stopped (`dumpsys bluetooth_manager`:
  6 started / 6 stopped, no ongoing scan of its own). Samsung's system scanner remains (above).
- Wi-Fi off now really means off: `dumpsys wifi` shows `DisabledState` with 0 active mode
  managers. Before, Wi-Fi off kept a scan-only client running (batterystats: "scanning" 21 h).
- Daemon cost: 0.46 s of CPU in 310 s (`/proc/<pid>/stat` utime+stime), 0.15 % of one core,
  mostly kernel time for the sysfs reads (200 reads of the battery `status` file cost 7 ticks,
  of the backlight 2).
- `dumpsys deviceidle` shows the new constants (15 s, 15 min, 1 h, 30 s, 15 s, 1 min).
- Kernel charge limit `batt_full_capacity` = 85 (100 before), set by Samsung's BatteryService
  from the `protect_battery` setting (logcat: `fileWriteInt ... batt_full_capacity value : 85`).
- `off` then `on`: every knob went back to its recorded stock value (Bluetooth on, timeout
  never, stay-awake 7, limit 100 %, the DeviceConfig keys deleted) and then to the optimised
  ones again; with guard mode on, the timeout went into guard's state file both ways.
- Screen detection against PowerManager's log: power-button off at 13:06:53 was logged at
  13:06:59; off at 13:07:44 / on at 13:07:53 were logged at 13:07:49 / 13:07:56. Off periods
  shorter than the 5 s round (two of them) are not seen, which only matters for freezing.
- After a reboot (a manual reset, `power_off_reset_reason.txt`: `ONSRC: MRST`), Magisk started
  the daemon, every held knob was still applied and Bluetooth stayed off. Samsung's system BLE
  scanner put the controller back in `BLE_ON` at boot, as before.
- Doze, screen off at 13:27:22 with the phone lying still: light Doze at 13:28:38, **deep Doze
  at 13:29:10, 108 s after the screen went off** (stock: 35 min at the earliest); it left deep
  Doze at 13:31:59 on motion (the phone was picked up).
- First drain numbers from `report`, right after the reboot, so with boot work in them and too
  short to stand for a day: screen off 7 min, 8 mAh, 65 mA average; screen on 36 min, 254 mAh,
  415 mA. Before: 191 mA screen off. `./install.sh report` after a day or two of normal use
  gives the real screen-off average; the log keeps growing.
