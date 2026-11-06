# battery-optimiser

Cuts the battery drain of the rooted Galaxy XCover Pro (SM-G715FN, Exynos 9611, Android 13,
4050 mAh) and caps charging at 85 % so the cell lasts longer. One root script (`battery.sh`)
applies a set of measured settings, a small daemon keeps them applied, freezes `mosh-client`
while the screen is off and logs the drain per screen state so the result can be checked. The
**Battery app** (Quick Settings tile + screen) switches it and sets every knob from the phone.

By default everything the remote-control setup needs keeps working: Tailscale, adb over
Tailscale (a separate remote-control setup), DevDeck/DevDeck+, Termux and PhoneDeck are on the user Doze
whitelist, so the stronger Doze doesn't cut their network. For the most battery, `exempt`
(the apps you tick as Doze-exempt) can take those exemptions away too, at the price of remote
control while the phone sleeps (see [Doze exemptions](#doze-exemptions)). CPU/GPU clocks are
[phone_cooler](../../phone_cooler/)'s job;
nothing here touches them.

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

## The app

`install.sh` only copies the app to `/data/local/tmp/battery-optimiser.apk`; install it with
`adb shell pm install -r /data/local/tmp/battery-optimiser.apk` (if Play Protect asks, confirm
on the phone). Opening it the first time makes Magisk ask for root for "Battery" (Grant,
Forever); until then it shows "No root".

- **Battery screen** (launcher icon: a battery with a plus):
  - the on/off card at the top: on applies the optimised values, off puts the stock ones back;
  - **Now**: level, current (mA out of / into the battery), the kernel charge limit, screen state,
    battery status, frozen processes and whether the daemon runs, from `battery.sh now` every
    2 s while the screen is open (builtin reads only);
  - **Drain**: `battery.sh report` (own log plus batterystats), loaded on open, "Refresh report";
  - **Settings**: every knob with its allowed values, plus "now" and "stock" under each. Nothing
    changes until **Apply**, which saves them as the optimised values and turns the optimiser on;
    **Defaults** fills in the built-in optimised values (press Apply to use them). Errors from
    `battery.sh` show above the buttons. **What is Doze?** (tap to open) explains Doze, its two
    stages, what still works while it sleeps and what an exemption is; the Doze cards spell out
    each option. **Doze exemptions: apps** opens a list of the launcher
    apps to tick: ticked ones stay or become Doze-exempt, unticked ones lose it (the `exempt`
    knob; until you choose, it shows the apps exempt "as found"), with the apps exempt now and
    what the optimiser removed or added. **Doze exemptions: Google and Samsung** (Keep / Remove)
    is `exempt_sys`. **Keep these apps
    running** opens a list of the launcher apps to tick (the `allow` knob) and shows which of
    them are Unrestricted now.
- **Quick Settings tile "Battery"**: pull the panel down twice, tap the pencil, drag Battery in.
  A tap runs `battery.sh toggle` (optimised <-> stock; it takes a few seconds), the subtitle shows
  Optimised or Stock, and the tile is lit while on. It asks `battery.sh get` whenever the panel
  shows it, so changes from the laptop show up.

The app (`dev.batteryoptimiser`, no permissions) runs `su -c /data/adb/battery-optimiser/battery.sh
...` on a background thread; the commands it uses are `get`, `toggle`, `now`, `knobs`, `apply` and
`report`.

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
| `stay_awake` | `global stay_on_while_plugged_in` | 7 | 0 | the screen goes off while charging instead of staying lit; it also lifts Samsung's ~1.2 A screen-on charge limit, so `fast_charge` matters (see [Charging heat](#charging-heat)) | no |
| `protect_battery` | `global protect_battery` | 0 | 1 | Samsung's "Protect battery": charging stops at 85 % (`batt_full_capacity`) | yes |
| `fast_charge` | `system adaptive_fast_charging` | 1 | 0 | Samsung's "Fast charging": off charges at 5 V instead of 9 V, so less current and heat while charging (see [Charging heat](#charging-heat)) | yes |
| `doze` | DeviceConfig `device_idle` | stock | aggressive | deep Doze about 2 minutes after the screen goes off instead of 35 min at the earliest | yes |
| `exempt` | user Doze whitelist (`dumpsys deviceidle whitelist`) | keep | keep | the apps you list are Doze-exempt, every other user exemption is taken away (see below) | yes |
| `exempt_sys` | system Doze whitelist (`dumpsys deviceidle sys-whitelist`) | keep | keep | `remove` takes Google Play services' and Samsung extras' exemptions away (see below) | yes |
| `allow` | Doze whitelist + app-op `RUN_ANY_IN_BACKGROUND` | none | none | apps you pick stay "Unrestricted", whatever `exempt` says (see below) | yes |
| `freeze` | cgroup freezer | none | `mosh-client` | processes frozen while the screen is off (see below) | daemon |

"Held" knobs are put back by the daemon if something changes them (checked each time the
screen goes off). `protect_battery` is also watched through the kernel limit every 5 s round,
since Samsung turns it off by itself after a long time on the charger; the daemon toggles the
setting once to make BatteryService write 85 again. The others are applied once by `on`/`apply`: turning
Bluetooth on for headphones or changing the timeout in Settings sticks. To keep a different
value, set it as the optimised value: `./install.sh apply bluetooth=1`. A held knob added by an
update is first applied by the daemon at its start, which records its stock value too, so
`off` restores it.

Allowed values (`./install.sh knobs` lists them):

- `wifi_scan`, `ble_scan`, `bluetooth`, `protect_battery`, `fast_charge`: 0 or 1.
- `screen_timeout`: 15000, 30000, 60000, 120000, 300000, 600000, 1800000, 2147483647 (never), ms.
- `stay_awake`: 0..7, a bit mask (1 AC, 2 USB, 4 wireless).
- `doze`: `stock` or `aggressive`.
- `exempt`: `keep` (user exemptions as found), `none`, or a comma list of installed package
  names that are Doze-exempt, e.g. `exempt=com.tailscale.ipn,com.termux`.
- `exempt_sys`: `keep` or `remove`.
- `allow`: `none`, or a comma list of installed package names, e.g.
  `allow=com.brave.browser` (anything not installed is rejected).
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
until the next maintenance window; wakelocks of those apps are ignored. Push messages that apps
send as high priority (WhatsApp, banking) still arrive through Google Play services while it is
exempt.

### Doze exemptions

An exempt app ("Unrestricted" in the app's battery settings) keeps its network, jobs and
wakelocks while the phone is in Doze. Found on this phone:

- user exemptions: Tailscale, DevDeck+, DevDeck, Termux, Termius, PhoneDeck;
- system exemptions (21): Google Play services, dialer, messages, IMS (VoLTE calls), clock,
  contacts, emergency alerts and SOS, Knox Guard, and Samsung extras (screenshots, file sharing,
  one-handed mode, blue light filter, handwriting, video, adaptive brightness), plus the
  calendar and download providers and the shell.

| knob | what loses the exemption | what stops while the phone sleeps |
|---|---|---|
| `exempt=keep` (default) | nothing | nothing new |
| `exempt=<list>` | every user exemption not in the list (the list's apps are made exempt) | for the unlisted ones of Tailscale, DevDeck/DevDeck+, Termux, PhoneDeck: adb over Tailscale, the DevDeck links and agent notifications, mosh, Termux jobs, until the screen comes on or a maintenance window |
| `exempt=none` | all user exemptions | all of the above |
| `exempt_sys=remove` | Google Play services, calendar and download providers and the Samsung extras above | push messages (WhatsApp, banks, Gmail) and Google sync: they wait for a maintenance window (light Doze every 15 min to 1 h, deep Doze every 1 h growing to 6 h) |

Never removed: dialer, messages, IMS, emergency alerts, SOS (safety assurance), clock, contacts,
Knox Guard, CSC, provisioning and shell, so calls, SMS, alarms and emergency alerts keep working.
The `allow` apps are never removed either.

Both knobs record what they change in `/data/adb/battery-optimiser/exempt`: `user <pkg>` (a
user exemption removed), `add <pkg>` (an exemption added for the list), `sys <pkg>` (a system
one removed); `keep` (and `off`) put exactly those back and take the added ones away again. An
app leaving `allow` that `exempt` lists stays exempt (its record moves to `exempt`), and the
other way round. Both knobs are held: an app made "Unrestricted" by hand (or by an app asking
for it) that isn't listed loses it at the next screen-off. `allow` is applied before `exempt`,
so an app moving between the two in one apply is never mistaken for one of your own
exemptions.

With Tailscale unlisted, it keeps running, but Android's Doze network rules block a non-exempt app
from light Doze on (15 s after the screen goes off with the `aggressive` constants), so the
laptop loses adb until the screen comes on or a maintenance window opens. Verified on the phone:
with all user exemptions removed, netpolicy no longer lists `POWER_SAVE_ALLOWLIST` for Tailscale's
or Termux's uid; with the system ones removed too, not for Google Play services either; after
`keep`, all of them have it again.

### Apps you keep running (`allow`)

Every package in `allow` is made "Unrestricted", as in the app's battery settings: it gets a
user Doze exemption and its `RUN_ANY_IN_BACKGROUND` app-op is set back to allowed if it was
`ignore`. `exempt` never removes these. Taking an app off the list undoes exactly what
was changed for it (recorded in `/data/adb/battery-optimiser/allowed` as
`<package> <1 if we added the exemption> <app-op mode before>`): an app that was Restricted
before is Restricted again. The knob is held: if something restricts the app again, the
daemon makes it Unrestricted at the next screen-off (logcat
`rewritten: allow=none, re-applying com.brave.browser`).

Why Brave's background play dropped: Brave was **Restricted** (`RUN_ANY_IN_BACKGROUND: ignore`;
it was not set by this tool; 32 more apps had it, among them Firefox, SoundCloud, ChatGPT and
Claude). Android kills a restricted app shortly after it is cached in the background:
`dumpsys activity exit-info com.brave.browser` showed the main process killed at 14:36 and 14:49
with `cached idle & background restricted`. The kill reason is the restriction, not Doze, so
`allow` lifts the restriction as well as adding the Doze exemption.

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

### Charging heat

After the optimiser went on, charging got noticeably warmer. Samsung's saved batterystats
(`/data/log/batterystats`, one file per charge cycle, about a day of history each) show why. The
charger was the same 9 V fast charger throughout (`online=6`, Samsung's 9 V TA cable type):

| charge | screen | into the battery | battery temp | skin max |
|---|---|---|---|---|
| 10-23 12:28 (before) | on 95 % | 1.2 A | 32.5 to 34.5 °C | 39 °C |
| 10-23 19:39 (before) | off | 1.5 A | 31.1 to 33.1 °C | 37 °C |
| 10-31 21:54 | off | 2.3 A for 47 min | 32.5 to 35.5 °C | 42 °C |
| 11-01 12:12 | on | 1.2 A | 32.7 °C | 35 °C |
| 11-02 16:05 | off | 2.6 A | 31.1 to 34.1 °C in 18 min | 41 °C |

With the screen on, Samsung caps the charge current at about 1.2 A (bit `0x200` set in
batterystats' `current_event` on every screen-on stretch). With `stay_awake=7` the screen stayed
lit while plugged in, so the phone mostly charged at that cap. With `stay_awake=0` and a 30 s
timeout, the screen goes off and fast charging runs at 2.3 to 2.7 A, about twice the current
and roughly four times the heat in the cell (I²R). The 10-23 screen-off charge also ran at only
1.5 A on the same cable type; nothing in the logs explains it (a different charger or cable
would). None of it reached a battery temperature Samsung acts on: 35.5 °C was the highest.

`fast_charge=0` turns Samsung's "Fast charging" off (`system adaptive_fast_charging`). Samsung
passes it to the charger driver at once: `/sys/class/sec/switch/afc_disable` went 0 to 1 and
back with the setting (tested unplugged). With it off, the charger stays at 5 V. Its current
and temperature are still to be measured on the next charge.

### Screen timeout and guard mode

Guard mode sets the timeout to "never" and puts its saved value back when it ends. While guard
mode is on, `battery.sh` reads and writes the timeout in guard's state file
(`/data/adb/xcover-guard/state`, `timeout=` line) instead, so guard ends with the optimised
timeout. Agents that drive the phone without guard mode need `input keyevent KEYCODE_WAKEUP`
after 30 s of no input.

## What it doesn't change (and why)

- **CPU/GPU clocks**: [phone_cooler](../../phone_cooler/). Its custom profile was at the lowest steps when this
  was written (little 403 MHz, big 936 MHz, GPU 260 MHz). The live rail voltages at those steps
  were 600 mV (little), 687 mV (big) and 581 mV (GPU, its floor). The ECT table puts the next
  little step (598 MHz) at 656 mV, so each cycle at 403 MHz costs about (600/656)^2 = 84 % of
  the switching energy of one at 598 MHz: the bottom of the little cluster is not yet at a
  voltage floor where running faster would be free.
- **Undervolting**: not possible on the stock kernel (see phone_cooler's Limits).
- **Tailscale, adb, DevDeck+** (while `exempt` lists them): the largest remaining drain is the always-on
  Tailscale link over LTE. Its keepalives, adb sessions and DevDeck+'s link (pings every 10 s
  while visible, every 10 min when hidden) are what remote control needs; unlisting them stops
  them while the phone sleeps. Wi-Fi is far cheaper than LTE for the same link (in the stats
  above: Wi-Fi 21 mAh for 8 h connected; LTE radio 3157 mAh), so being on Wi-Fi is the biggest
  thing left.
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
- The daemon's pid file is trusted only if that process's command line is `battery.sh daemon`.
  A pid file survives a reboot, and by then its number belongs to another process
  (phone_cooler's daemon stopped starting because of exactly that).
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
- `dumpsys deviceidle` shows the new constants (15 s, 15 min, 1 h, 30 s, 15 s, 1 min). The
  hold is needed: at the 13:27:22 screen-off the daemon found the DeviceConfig keys gone (cause
  not found) and put them back (logcat `rewritten: doze=stock, re-applying aggressive`), and
  deep Doze followed at 13:29:10.
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
- The app, recorded on a scrcpy virtual display (the real screen untouched): every section
  rendered with live values (61 %, 648 mA out, limit 85 %, the drain report, each knob with
  now/stock); root worked for its uid. `battery.sh toggle` printed `off` / `on` with exit 0, and
  during the `off` Protect battery stayed off (an earlier version wrote the state after
  restoring, so a daemon round in between turned it back on).
