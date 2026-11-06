# phone_cooler

Makes the rooted Galaxy XCover Pro (SM-G715FN, Exynos 9611, Android 13) run colder by capping
its CPU and GPU clocks, switched from a **Quick Settings tile** ("Cooler": Off / Mild / Cool /
Cold / Custom). The Custom profile is set by hand in the app: clock ranges, governors and online
cores of both CPU clusters, and the GPU's clock range, governor and boosts.

Why: with a few busy apps (WebView apps, banking app, keyboard) the big cores sit around 60 C
and the phone gets warm in the hand. Samsung's own thermal management (SSRM) only steps in once
it is already hot; a lower clock ceiling makes the same work cost less power and heat from the
start, at the price of slower bursts.

## Profiles

| profile | little cores 0-3 | big cores 4-7 | GPU |
|---|---|---|---|
| off (stock) | 1742 MHz | 2314 MHz | 1053 MHz |
| mild | 1742 MHz | 1898 MHz | 764 MHz |
| cool | 1456 MHz | 1508 MHz | 572 MHz |
| cold | 1222 MHz | 1248 MHz | 455 MHz |

Only the maxima change: the governors (schedutil, GPU Interactive) still drop to the lowest
clocks when idle. The profile survives reboots. Selecting a preset puts every other knob back
to stock (all cores online, stock governors and minima); saved custom settings stay saved.

## Manual controls (Custom profile)

Cooler app > **Custom** card opens the manual screen. The live readout (temperatures, clocks
now / max per cluster and GPU, online cores) stays at the top and refreshes every 2 s; the
controls scroll below it. Nothing changes until **Apply**, which saves the settings and switches
to the Custom profile; errors from `cool.sh` are shown above the buttons. **Reset to stock**
fills in the stock values (press Apply to use them). The screen starts from the profile in use:
coming from Cold it shows Cold's clocks (stock for everything else), on Custom the saved custom
settings.

| knob (`cool.sh` key) | values offered | effect | stock |
|---|---|---|---|
| little max / min clock (`little_max`, `little_min`) | the 13 steps 403..1742 MHz | clock range of cores 0-3; min <= max | 403-1742 |
| big max / min clock (`big_max`, `big_min`) | the 15 steps 936..2314 MHz | clock range of cores 4-7; min <= max | 936-2314 |
| CPU governor (`little_governor`, `big_governor`) | schedutil, performance | schedutil follows the load; performance holds the cluster at the highest clock it is allowed (hot: use it with a low max) | schedutil |
| cores online (`cpu1`..`cpu7`) | on / off | an offline core takes no work and draws almost nothing; fewer big cores = less peak heat and multi-core speed | all on |
| GPU max / min clock (`gpu_max`, `gpu_min`) | the 11 steps 260..1053 MHz | GPU clock range; min <= max | 260-1053 |
| GPU governor (`gpu_governor`) | Default, Interactive, Joint, Booster, Dynamic | Samsung's Mali DVFS policies; Interactive jumps to a set clock under high load | Interactive |
| OpenCL boost (`gpu_cl_boost`) | on / off | `gpu_cl_boost_disable`: with it on, compute (OpenCL) jobs push the GPU up | on |
| Interactive jump-to clock (`gpu_highspeed_clock`) | the GPU steps | clock the Interactive governor jumps to above the load threshold (still under the max) | 764 MHz |
| Interactive jump load (`gpu_highspeed_load`) | 50..100 % in steps of 5 | GPU load above which it jumps | 75 % |

Safety limits, enforced by `cool.sh` (the app applies the same rules before sending):

- Only values from the kernel's own tables (or the lists above) are accepted; anything else is
  rejected with the allowed values, and nothing is written unless every value is valid.
- min <= max for each cluster and the GPU. Writes are ordered so the kernel never sees a max
  below the current min or a min above the current max (cpufreq refuses both).
- **cpu0 never goes offline** (the app shows it as always on, `cpu0=0` is rejected): during
  testing a write of 0 to `cpu0/online` was accepted by the kernel, bringing it back hung and
  the phone rebooted. At least one big core (4-7) stays online; the little cluster always has
  cpu0.
- The daemon holds the custom values the way it holds preset caps, in the direction that undoes
  them: a max raised above the setting, a min lowered below it (unless thermal pulled the max
  under it), a core we took offline brought back, a governor or GPU setting changed. It does not
  fight the kernel's thermal limits (a lower max, a core taken offline by Samsung's thermal
  hotplug). `gpu_max_clock` is root-owned as in the presets; `gpu_min_clock` is root-owned too
  when the custom GPU min is above 260 MHz (so HyperHAL's boosts can't lower it), else it stays
  with system.

From a shell (on the phone as root, or `./install.sh knobs|apply` from the laptop):

```
cool.sh knobs          # one call: key=<live>, key.options=<allowed>, key.stock=, key.want=<profile in use>
cool.sh apply big_max=1664000 big_min=936000 cpu7=0 gpu_max=546000 little_governor=performance
cool.sh set custom     # back to the saved custom settings after a preset
```

`apply` changes only the named knobs; the rest keep the values of the profile in use (on
Custom the saved custom values, on a preset that preset's). Custom settings live in
`/data/adb/phone-cooler/custom` (`key=value` lines).

### What can't be changed

- **Voltages**: see Limits below (fused ASV tables, set by the ACPM firmware; needs a custom
  kernel).
- **schedutil `up_rate_limit_us` / `down_rate_limit_us`**: writable, but Samsung's freqvar-tune
  rewrites them from its per-frequency tables on every frequency change (a written 20000 was
  back at 5000 within 0.2 s). The tables themselves (`policy*/schedutil/freqvar_*`, also
  `freqvar_boost` and `freqvar_upscale_ratio`) have an undocumented write format and were left
  alone.
- **GPU shader core mask** (`11500000.mali/core_mask`, 3 cores): a driver debug interface;
  lowering the GPU max does the same job, so it is not offered.
- **GPU Static governor**: the driver's test pattern (it steps through the clocks regardless of
  load); hidden from the choices.
- **SSRM's limits** (`/sys/power/cpufreq_max_limit` / `cpufreq_min_limit`, `cpuhp`), the Mali
  power policy, DVFS period and GPU power-off delay: Samsung's own thermal/boost plumbing or
  driver internals with no cooling benefit; not touched.
- With the little cluster on performance and max 1222 MHz, it sat at 1053 MHz for 10 s:
  something below cpufreq (Samsung's QoS) can still hold a cluster under its max.

## Install (from the laptop, over adb)

```
./install.sh              # build the APK, copy cool.sh + boot launcher, start the daemon, stage the APK
./install.sh status
./install.sh set cool     # off|mild|cool|cold|custom, without the tile
./install.sh knobs        # every knob with its allowed values
./install.sh apply big_max=1664000 gpu_max=546000   # custom settings, as in the app
./install.sh uninstall    # stock clocks back, daemon stopped, files removed
```

It uses `$ANDROID_SERIAL`, else the Tailscale address saved by `phone-adb` (part of a separate
remote-control setup, not in this repo), else the only adb device. Needs root for adb's shell
(Magisk: Shell allowed) and a JDK; the Android build tools come from `.sdk/` at the repository
root, downloaded on first build (see `android/build.sh`).

The app is only copied to `/data/local/tmp/cooler.apk`. Install it with the phone unlocked (Play
Protect asks to confirm):

```
adb shell pm install -r /data/local/tmp/cooler.apk
```

### Add the tile

1. Pull the notification panel down fully (two swipes), tap the pencil (edit).
2. Find **Cooler** (snowflake) among the available tiles and drag it into the active ones.
3. Tap it: each tap moves Off > Mild > Cool > Cold > Off (with Custom after Cold once custom
   settings were saved). The subtitle shows the profile; the tile is lit for any profile other
   than Off.

The **first tap** makes Magisk ask whether "Cooler" may get root. The prompt can open behind
the notification panel: close the panel and press Grant (choose "Forever"). Until then the tile
shows "No root". Opening the Cooler app from the launcher shows the profile cards with the
live `cool.sh status`, and raises the same prompt in the foreground. "Not installed" means the
app has root but `/data/adb/phone-cooler/cool.sh` is missing (run `./install.sh`).

The tile asks the script for the current profile every time the panel shows it (so changes
made from the laptop show up too), which is one `su` call each time. If Magisk's "granted"
toast gets annoying: Magisk > Superuser > Cooler > turn off Notification.

On the phone, agents can also run
`su -c /data/adb/phone-cooler/cool.sh set|get|next|status|knobs|apply`.

## How it works

- `cool.sh` (`/data/adb/phone-cooler/`) writes the per-cluster `scaling_max_freq`
  (`/sys/devices/system/cpu/cpufreq/policy0` and `policy4`) and `/sys/kernel/gpu/gpu_max_clock`
  (custom: also the mins, governors, `cpuN/online` and the GPU knobs of the table above), and
  remembers the profile in `/data/adb/phone-cooler/profile`. Only knobs whose live value differs
  are written. A CPU max is never written below the current min (boosts raise the min for a
  moment).
- `/data/adb/service.d/phone-cooler.sh`: Magisk runs it after boot; it waits for boot completion
  and starts `cool.sh daemon`, which applies the remembered profile and then checks every 30 s
  whether a cap was raised above the profile (custom: whether any custom value was undone, see
  the rules above); if so it logs `phone-cooler` to logcat and re-applies. Values below the cap
  (thermal throttling) are left alone. A round is builtin reads only and a timed `read` on a
  fifo (`/data/adb/phone-cooler/tick`) instead of `sleep`, so it forks nothing.
- The daemon's pid file is checked against the process's command line, not with `kill -0`
  alone. On 2026-11-03 the file still held 5224 from the 11-02 boot, which was now a
  `media.codec` thread: `kill -0` succeeded, so every boot since then the daemon thought it was
  already running and exited. No profile was applied after a reboot, while the tile kept
  showing the saved one and `status` said "daemon: running".
- The app (`dev.cooler`, ~29 KB, no permissions) is a `TileService` that runs
  `su -c '/data/adb/phone-cooler/cool.sh next'` on a background thread when tapped and
  `cool.sh get` whenever the panel shows the tile, plus the profile screen and the manual screen
  (`cool.sh knobs` once when it opens, `cool.sh status` every 2 s, `cool.sh apply ...` on Apply).

### What else writes these knobs (measured)

A monitor sampled every 0.5 s all caps, mins, `/sys/power/cpufreq_{max,min}_limit` and the
thermal cooling states while idling and under an 8-core load:

- **CPU `scaling_max_freq`**: never rewritten by userspace. Only the kernel's thermal cooling
  (`thermal-cpufreq-1`) lowered the big cluster for a few seconds under load (seen with stock
  caps), then went back to the value we wrote. SSRM/HyperHAL boost and throttle through
  `/sys/power/cpufreq_min_limit` / `cpufreq_max_limit` instead (min boosts to 2314000 several
  times a minute, max throttles 2184000 > 1664000 when warm); the min boosts did not lift our
  max: under load with the cool caps the big cores never ran above 1508 MHz.
- **GPU `gpu_max_clock`**: rewritten every one to few seconds by Samsung's HyperHAL (on SSRM's
  behalf), often back to the full 1053000, which immediately undid a plain write. Polling cannot
  keep up with that, and the Mali driver's other knob (`dvfs_max_lock`) is the same lock slot.
  So while a profile is on, `cool.sh` chowns `gpu_max_clock` to root: HyperHAL's writes then
  fail (logcat: `HYPER-HAL ... Couldn't Open Sysfs - /sys/kernel/gpu/gpu_max_clock`), and the
  cap holds. Profile off gives the file back to system. With the file locked at 455 MHz, the
  Mali `time_in_state` showed 0 ms above 455 MHz over a 60 s window of normal use, and
  `gpu_max_clock` stayed 455000 while HyperHAL boosted `gpu_min_clock` to 1053000 (the max
  lock wins). The kernel's own GPU thermal limit (G3D zone, TMU lock) keeps working; what is
  lost while a profile is on is SSRM's softer GPU throttling (it set 683 MHz at ~58 C), which
  matters only for mild (764 MHz).
- **The custom knobs** (2026-10-24, 80 s monitor at 0.5 s while the phone was in use, these
  set away from stock: little governor performance, big min 1040 MHz, cpu7 offline, GPU min
  338 MHz, GPU governor Default, CL boost off, Interactive 546 MHz / 85 %): nothing rewrote any
  of them; only SSRM's `cpufreq_min_limit` boosts came and went. Each write read back as
  written; with cpu4, then also cpu5 and cpu6 offline, policy4 kept working on the remaining
  cores and they came back online cleanly. The Mali driver accepts a GPU min above the max (the
  max lock wins). Switching the CPU governor away and back resets `up_rate_limit_us` to 10000,
  and freqvar-tune rewrites both rate limits
  on each frequency change, hence they are not offered. The daemon test: with custom little
  governor performance, writing schedutil by hand was undone 8 s later (next 30 s round;
  logcat `phone-cooler: rewritten: little_governor=schedutil, re-applying custom`).

## Limits

- **No undervolting.** The CPU/GPU voltages come from the per-chip ASV tables (ECT, fused at
  the factory; `/sys/kernel/debug/ect/asv_table` and the Mali `asv_table` are read-only) and
  are set by the ACPM power-management firmware on every clock change. The kernel exposes no
  voltage table to edit. The only voltage files are debugfs regulator test hooks
  (`/sys/kernel/debug/exynos-rgt/vdd_cpucl0|vdd_cpucl1|vdd_g3d/voltage`, BUCK3/2/5): the
  cpufreq/GPU drivers are not consumers of those regulators, so a write there would be a
  one-shot override that the next DVFS step (many per second) replaces, with a crash risk if it
  lands too low; not tried. A real undervolt needs a custom kernel. Lower clocks still save
  power superlinearly, because each lower step also runs at the lower voltage from that table.

## Measurements

2026-10-23, on battery, screen on with the usual background apps (DevDeck+, banking app,
keyboard, Brave audio). Each run: `cool.sh set <profile>`, wait until the BIG sensor is
<= 50 C (it drops within seconds once idle), then 60 s of 8 parallel `yes > /dev/null` as root.
Average clocks from the cpufreq `time_in_state` delta; power from the battery's
`current_now` x `voltage_now`, sampled every second. Two rounds back to back (off, cool, cold,
off, cool, cold); the BIG sensor drops back within a second after the load, so the peak is the
telling number.

| run | profile | BIG start / peak / end C | LITTLE start / end C | big avg MHz (max seen) | little avg MHz | battery power |
|---|---|---|---|---|---|---|
| 1 | off | 45 / 86 / 51 | 44 / 48 | 1679 (2210) | 1557 | 2593 mW |
| 1 | cool | 49 / 66 / 50 | 48 / 47 | 1356 (1508) | 1321 | 1678 mW |
| 1 | cold | 49 / 58 / 48 | 47 / 46 | 1154 (1248) | 1117 | 1340 mW |
| 2 | off | 53 / 72 / 49 | 47 / 48 | 1450 (1664) | 1377 | 1831 mW |
| 2 | cool | 50 / 66 / 49 | 48 / 47 | 1347 (1508) | 1312 | 1628 mW |
| 2 | cold | 49 / 60 / 49 | 48 / 47 | 1156 (1248) | 1121 | 1358 mW |

- Stock clocks hit 86 C on the big cores within the minute, after which the kernel thermal
  cooling and SSRM (`cpufreq_max_limit` 1664000) throttled them; in round 2 the phone was
  still warm from round 1, so SSRM held the big cores at 1664 MHz from the start, and stock
  only reached 72 C.
- Cool: peak 66 C, about 35 % less power than unthrottled stock (1.65 W vs 2.59 W).
  Cold: peak 58-60 C, about half the power (1.35 W).
- The caps held for the whole load: the big cores never ran above 1508 / 1248 MHz, no
  `phone-cooler` re-apply was logged (nothing raised a cap), and HyperHAL's four attempts to
  rewrite `gpu_max_clock` during the cool/cold runs failed on the root-owned file.
- Daemon cost: 30 ms of CPU in 5 minutes (`/proc/<pid>/stat` utime+stime), about 0.01 % of
  one core. The first version, which used `sleep 30`, spent ~10x that on forking `sleep`.
  With the custom knobs (all 20 knobs' wanted values rebuilt each round, builtins only): 60 ms
  in 150 s on the cold preset (2026-10-24), about 0.04 % of one core.
