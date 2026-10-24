#!/system/bin/sh
# battery-optimiser: cuts the battery drain of the rooted Galaxy XCover Pro (SM-G715FN,
# Android 13) and caps charging at 85 % for battery life. Runs as root (Magisk); installed to
# /data/adb/battery-optimiser by install.sh. See README.md for what each knob does and the
# measurements behind it.
#
#   battery.sh on                  apply the optimised values (the stock ones are saved first)
#   battery.sh off                 put the saved stock values back
#   battery.sh status              every knob (now / optimised / stock), screen, battery, daemon
#   battery.sh knobs               machine-readable: key=<live>, key.want=, key.stock=, key.options=
#   battery.sh apply key=value ... change optimised values and apply them (turns the optimiser on)
#   battery.sh report              battery drain per screen state, from the daemon's log
#   battery.sh daemon              keep it applied: freezes the `freeze` processes while the
#                                  screen is off, re-applies held knobs, logs the drain
#                                  (started at boot from /data/adb/service.d/battery-optimiser.sh)
#
# Clocks, governors and cores are phone_cooler's job (../phone_cooler); nothing here touches them.

DIR=/data/adb/battery-optimiser
STATE=$DIR/state      # "on" while the optimiser is applied
WANT=$DIR/settings    # key=value: optimised values changed with `apply` (defaults below)
STOCK=$DIR/stock      # key=value: values found before the first change, put back by `off`
LOG=$DIR/drain.log    # <epoch s> <event> <screen> <battery status> <charge uAh> <level %>
PIDFILE=$DIR/daemon.pid
TICK=$DIR/tick        # fifo: the daemon sleeps on it; commands write a line to wake it
GUARD=/data/adb/xcover-guard/state # exists while xcover_guard's guard mode is on
BL=/sys/class/backlight/panel/brightness
BATT=/sys/class/power_supply/battery
FREEZER=/dev/freezer
FZ=$FREEZER/battery-optimiser
POLL_S=5

KEYS="wifi_scan ble_scan bluetooth screen_timeout stay_awake protect_battery doze freeze"
# Held knobs are put back by the daemon (checked when the screen goes off); the others are
# only applied by on/apply, so turning Bluetooth on or changing the timeout by hand sticks.
HELD="wifi_scan ble_scan protect_battery doze"
TIMEOUTS="15000 30000 60000 120000 300000 600000 1800000 2147483647"
# Doze (DeviceIdleController, DeviceConfig namespace device_idle). Stock: light doze 1 min after
# the screen goes off, deep doze only after 15 min inactive + 20 min idle-pending with no motion.
# sensing_to/locating_to stay stock: on Android 13 a sensing timeout restarts the progression.
DOZE="light_after_inactive_to=15000 light_idle_to=900000 light_max_idle_to=3600000 \
inactive_to=30000 idle_after_inactive_to=15000 motion_inactive_to=60000"

# D = optimised default of knob $1.
default() {
	case $1 in
	wifi_scan | ble_scan | bluetooth | stay_awake) D=0 ;;
	screen_timeout) D=30000 ;;
	protect_battery) D=1 ;;
	doze) D=aggressive ;;
	freeze) D=mosh-client ;;
	esac
}

# O = allowed values of knob $1 (freeze: a comma list of process names, or none).
options() {
	case $1 in
	wifi_scan | ble_scan | bluetooth | protect_battery) O="0 1" ;;
	screen_timeout) O=$TIMEOUTS ;;
	stay_awake) O="0 1 2 3 4 5 6 7" ;;
	doze) O="stock aggressive" ;;
	freeze) O="none|name[,name...]" ;;
	esac
}

# Settings table and name of a settings-backed knob $1: sets T and N.
setting() {
	case $1 in
	wifi_scan) T=global N=wifi_scan_always_enabled ;;
	ble_scan) T=global N=ble_scan_always_enabled ;;
	bluetooth) T=global N=bluetooth_on ;;
	screen_timeout) T=system N=screen_off_timeout ;;
	stay_awake) T=global N=stay_on_while_plugged_in ;;
	protect_battery) T=global N=protect_battery ;;
	*) return 1 ;;
	esac
}

# Guard mode keeps the screen on ("never") and puts its saved timeout back when it ends, so
# while it is on, the screen timeout lives in its state file.
guard_timeout() {
	G=
	[ -f "$GUARD" ] || return 1
	# gk/gv: callers loop over k.
	while IFS== read -r gk gv; do [ "$gk" = timeout ] && G=$gv; done <"$GUARD"
	return 0
}

# L = live value of knob $1 (forks `settings`/`device_config`; not for the daemon's poll).
live() {
	if [ "$1" = screen_timeout ] && guard_timeout; then
		L=${G:-null}
	elif setting "$1"; then
		L=$(settings get $T $N)
	elif [ "$1" = doze ]; then
		cfg=$(device_config list device_idle)
		L=aggressive
		for kv in $DOZE; do
			case "
$cfg
" in *"
$kv
"*) ;; *) L=stock ;; esac
		done
	else
		eval "L=\$v_$1" # freeze: nothing to read back; the daemon applies it
	fi
}

# Writes value $2 to knob $1 ("null" deletes the setting); a failed write is added to ERR.
put() {
	if [ "$1" = screen_timeout ] && guard_timeout; then
		sed -i "s/^timeout=.*/timeout=$2/" "$GUARD" || ERR="$ERR $1=$2"
	elif [ "$1" = bluetooth ]; then
		if [ "$2" = 1 ]; then cmd bluetooth_manager enable; else cmd bluetooth_manager disable; fi >/dev/null 2>&1 ||
			ERR="$ERR $1=$2"
	elif setting "$1"; then
		if [ "$2" = null ]; then settings delete $T $N; else settings put $T $N "$2"; fi >/dev/null 2>&1 ||
			ERR="$ERR $1=$2"
	elif [ "$1" = doze ]; then
		for kv in $DOZE; do
			if [ "$2" = aggressive ]; then
				device_config put device_idle "${kv%%=*}" "${kv#*=}"
			else
				device_config delete device_idle "${kv%%=*}"
			fi >/dev/null 2>&1 || ERR="$ERR doze:${kv%%=*}"
		done
	fi
}

# Sets v_<key> for every knob: the defaults, overridden by the settings file.
want() {
	for k in $KEYS; do
		default "$k"
		eval "v_$k=\$D"
	done
	[ -f "$WANT" ] || return 0
	while IFS== read -r k v; do
		case " $KEYS " in *" $k "*) eval "v_$k=\$v" ;; esac
	done <"$WANT"
}

# Sets s_<key> from the stock file (empty for knobs not recorded).
load_stock() {
	for k in $KEYS; do eval "s_$k="; done
	[ -f "$STOCK" ] || return 0
	while IFS== read -r k v; do
		case " $KEYS " in *" $k "*) eval "s_$k=\$v" ;; esac
	done <"$STOCK"
}

is_on() {
	st=
	[ -f "$STATE" ] && read -r st <"$STATE"
	[ "$st" = on ]
}

# Wakes the daemon so it re-reads the state and settings at once. Opening the fifo read-write
# never blocks, even with no daemon.
poke() {
	if [ -p "$TICK" ]; then echo reload 1<>"$TICK"; fi
}

# Applies the wanted values of knobs $@ that differ from their live value; records the stock
# value of each knob the first time it is changed.
apply_keys() {
	ERR=
	load_stock
	for k in "$@"; do
		[ "$k" = freeze ] && continue
		eval "w=\$v_$k s=\$s_$k"
		live "$k"
		[ "$L" = "$w" ] && continue
		[ -z "$s" ] && echo "$k=$L" >>"$STOCK"
		put "$k" "$w"
	done
	[ -z "$ERR" ]
}

turn_on() {
	mkdir -p "$DIR"
	want
	apply_keys $KEYS || echo "not all applied (refused):$ERR" >&2
	echo on >"$STATE"
	poke
}

turn_off() {
	load_stock
	ERR=
	for k in $KEYS; do
		eval "s=\$s_$k"
		[ -n "$s" ] && put "$k" "$s"
	done
	echo off >"$STATE"
	rm -f "$STOCK"
	thaw
	poke
	[ -z "$ERR" ] || { echo "not all restored (refused):$ERR" >&2; return 1; }
}

# apply key=value ...: validates everything first; nothing is written unless all of it is valid.
apply_custom() {
	want
	bad=
	for a in "$@"; do
		k=${a%%=*}
		v=${a#*=}
		case " $KEYS " in
		*" $k "*) ;;
		*)
			bad="$bad
unknown knob: $k (one of: $KEYS)"
			continue
			;;
		esac
		options "$k"
		if [ "$a" = "$k" ] || [ -z "$v" ]; then
			bad="$bad
$k: missing value (one of: $O)"
		elif [ "$k" = freeze ]; then
			# Process names as in /proc/<pid>/comm (at most 15 characters), comma-separated.
			case $v in
			none) eval "v_$k=\$v" ;;
			*[!A-Za-z0-9._,:-]* | ,* | *, | *,,*) bad="$bad
freeze: $v is not none or a comma list of process names" ;;
			*) eval "v_$k=\$v" ;;
			esac
		else
			case " $O " in
			*" $v "*) eval "v_$k=\$v" ;;
			*) bad="$bad
$k: $v is not one of: $O" ;;
			esac
		fi
	done
	if [ -n "$bad" ]; then
		echo "rejected, nothing changed:$bad" >&2
		return 2
	fi
	mkdir -p "$DIR"
	for k in $KEYS; do
		eval "echo \"$k=\$v_$k\""
	done >"$WANT.tmp" && mv "$WANT.tmp" "$WANT"
	turn_on
}

# ---- daemon side: builtin reads only in the poll ----

# S = on|off. The panel's raw brightness is 0 while the display is off; guard mode also holds it
# at 0 with the display on (agents at work), so that counts as on.
screen() {
	b=1
	read -r b <"$BL"
	if [ "$b" = 0 ] && [ ! -e "$GUARD" ]; then S=off; else S=on; fi
}

# B = battery status (Discharging, Charging, Full, Not_charging); read every round.
battery() {
	read -r B <"$BATT/status"
	B=${B// /_}
}

# Appends a log line with the charge counter (uAh) and level (%), read only here.
logline() {
	read -r C <"$BATT/charge_counter"
	read -r P <"$BATT/capacity"
	echo "${EPOCHREALTIME%.*} $1 $S $B $C $P" >>"$LOG"
}

# Freezes every process named in v_freeze (cgroup v1 freezer: the process just stops being
# scheduled, its parent sees nothing, unlike SIGSTOP which a shell's job control reports).
freeze() {
	[ "$v_freeze" = none ] && return
	[ -d "$FZ" ] || mkdir "$FZ" 2>/dev/null || return
	n=0
	for p in /proc/[0-9]*; do
		c=
		read -r c 2>/dev/null <"$p/comm"
		case ",$v_freeze," in
		*",$c,"*) echo "${p#/proc/}" 2>/dev/null >"$FZ/cgroup.procs" && n=$((n + 1)) ;;
		esac
	done
	[ $n -gt 0 ] && echo FROZEN >"$FZ/freezer.state" && log -t battery-optimiser "screen off: froze $n ($v_freeze)"
}

# Thaws and moves the frozen processes back to the root freezer group.
thaw() {
	[ -d "$FZ" ] || return 0
	echo THAWED >"$FZ/freezer.state"
	while read -r p; do echo "$p" 2>/dev/null >"$FREEZER/cgroup.procs"; done <"$FZ/cgroup.procs"
}

# Puts back held knobs that something else changed (forks; run when the screen goes off).
hold() {
	for k in $HELD; do
		eval "w=\$v_$k"
		live "$k"
		if [ "$L" != "$w" ]; then
			log -t battery-optimiser "rewritten: $k=$L, re-applying $w"
			put "$k" "$w"
		fi
	done
}

daemon_pid() {
	[ -f "$PIDFILE" ] && read -r pid <"$PIDFILE" && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

daemon() {
	pid=$(daemon_pid)
	if [ -n "$pid" ] && [ "$pid" != $$ ]; then
		echo "daemon already running (pid $pid)" >&2
		return 1
	fi
	mkdir -p "$DIR"
	[ -p "$TICK" ] || mkfifo "$TICK"
	echo $$ >"$PIDFILE"
	# Keep the log bounded (a few hundred lines a day).
	if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 20000 ]; then
		tail -n 10000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
	fi
	want
	on=
	is_on && on=1
	[ -n "$on" ] && hold
	screen
	battery
	logline start
	lastS=$S lastB=$B
	[ -n "$on" ] && [ "$S" = off ] && freeze
	pbcheck=1
	while :; do
		# A timed read on the fifo instead of `sleep`: no fork per round. A line means a command
		# changed the state or settings. The state file is read every round as well, in case a
		# line got lost (a fifo drops what is written while nobody has it open).
		poked=
		read -t $POLL_S _ <>"$TICK" && poked=1
		screen
		battery
		was=$on
		on=
		is_on && on=1
		if [ -n "$poked" ] || [ "$on" != "$was" ] || [ "$S" != "$lastS" ]; then
			want
			pbcheck=1
		fi
		if [ -n "$poked" ] || [ "$on" != "$was" ]; then
			thaw
			[ -n "$on" ] && [ "$S" = off ] && [ "$lastS" = off ] && freeze
		fi
		if [ "$S" != "$lastS" ]; then
			logline screen
			lastS=$S lastB=$B
			if [ -n "$on" ]; then
				if [ "$S" = off ]; then
					freeze
					hold
				else
					thaw
				fi
			fi
		elif [ "$B" != "$lastB" ]; then
			logline power
			lastB=$B
		fi
		# Samsung turns Protect battery off by itself after a long time on the charger
		# (TURN_OFF_PROTECT_BATTERY_BY_LONG_TERM_TA); the kernel limit shows it at once. Checked
		# once per screen change or command, so a limit that won't come back doesn't loop.
		if [ -n "$pbcheck" ] && [ -n "$on" ] && [ "$v_protect_battery" = 1 ]; then
			read -r cap <"$BATT/batt_full_capacity"
			if [ "$cap" = 100 ]; then
				pbcheck=
				log -t battery-optimiser "protect battery was turned off, turning it back on"
				settings put global protect_battery 0
				settings put global protect_battery 1
			fi
		fi
	done
}

# ---- reports ----

status() {
	want
	load_stock
	if is_on; then echo "battery-optimiser: on"; else echo "battery-optimiser: off"; fi
	printf '%-16s %-12s %-12s %s\n' knob now optimised stock
	for k in $KEYS; do
		live "$k"
		eval "w=\$v_$k s=\$s_$k"
		printf '%-16s %-12s %-12s %s\n' "$k" "$L" "$w" "${s:--}"
	done
	[ -f "$GUARD" ] && echo "(guard mode is on: screen_timeout is the value it restores)"
	screen
	battery
	read -r P <"$BATT/capacity"
	read -r cur <"$BATT/current_now"
	read -r cap <"$BATT/batt_full_capacity"
	echo "screen: $S; battery: $P % $B, $cur mA now, charge limit $cap %"
	f=
	[ -f "$FZ/cgroup.procs" ] && while read -r p; do
		read -r c 2>/dev/null <"/proc/$p/comm"
		f="$f $c($p)"
	done <"$FZ/cgroup.procs"
	echo "frozen:${f:- none}"
	if pid=$(daemon_pid); then echo "daemon: running (pid $pid)"; else echo "daemon: not running"; fi
}

knobs() {
	want
	load_stock
	if is_on; then echo "state=on"; else echo "state=off"; fi
	for k in $KEYS; do
		live "$k"
		options "$k"
		eval "echo \"$k=\$L\"; echo \"$k.want=\$v_$k\"; echo \"$k.stock=\$s_$k\""
		echo "$k.options=$O"
	done
}

# Discharge per screen state from the log: the interval between two lines counts for the
# earlier line's screen state while that line says Discharging; intervals that end at a daemon
# start (reboot) are skipped. Then batterystats' since-last-charge numbers for comparison.
report() {
	[ -f "$LOG" ] || { echo "no log yet (the daemon writes $LOG)"; return 1; }
	awk '
	function dur(s) { return sprintf("%dh %02dm", s / 3600, s % 3600 / 60) }
	function when(t, f,   c, x) { c = "date -d @" t " \"+" f "\""; c | getline x; close(c); return x }
	NR == 1 { first = $1 }
	NR > 1 && pB == "Discharging" && $2 != "start" && $1 > pt {
		d = $1 - pt; mah = (pc - $5) / 1000
		t[pS] += d; q[pS] += mah
		if (pS == "off" && d >= 1800) {
			n++; per[n] = sprintf("  %s  %s  %6.1f mAh  %5.1f mA", when(pt, "%m-%d %H:%M"), dur(d), mah, mah * 3600 / d)
		}
	}
	{ pt = $1; pS = $3; pB = $4; pc = $5 }
	END {
		printf "own log since %s:\n", when(first, "%Y-%m-%d %H:%M")
		for (s in t) if (t[s] > 0)
			printf "  screen %-3s on battery %s: %.0f mAh, %.1f mA average (%.2f %%/h of 4050 mAh)\n", s, dur(t[s]), q[s], q[s] * 3600 / t[s], q[s] * 3600 / t[s] / 40.5
		if (n) {
			print "screen-off periods of 30 min or more (start, length, used, average):"
			for (i = (n > 15 ? n - 14 : 1); i <= n; i++) print per[i]
		}
	}' "$LOG"
	dumpsys batterystats --charged | awk '
	function secs(s,   a, i, n, x) {
		n = split(s, a, " "); x = 0
		for (i = 1; i <= n; i++) {
			if (a[i] ~ /ms$/) continue
			if (a[i] ~ /d$/) x += a[i] * 86400; else if (a[i] ~ /h$/) x += a[i] * 3600
			else if (a[i] ~ /m$/) x += a[i] * 60; else if (a[i] ~ /s$/) x += a[i]
		}
		return x
	}
	/^  Time on battery screen off:/ { sub(/.*off: /, ""); sub(/ \(.*/, ""); off = secs($0) }
	/^  Time on battery:/ { sub(/.*battery: /, ""); sub(/ \(.*/, ""); all = secs($0) }
	/^  Screen off discharge:/ { offmah = $4 }
	/^  Discharge:/ { allmah = $2 }
	END {
		print "batterystats since the last full charge:"
		if (off > 0) printf "  screen off %.1f h: %d mAh, %.1f mA average\n", off / 3600, offmah, offmah * 3600 / off
		if (all > off) printf "  screen on %.1f h: %d mAh, %.1f mA average\n", (all - off) / 3600, allmah - offmah, (allmah - offmah) * 3600 / (all - off)
	}'
}

case $1 in
on) turn_on ;;
off) turn_off ;;
status) status ;;
knobs) knobs ;;
apply)
	shift
	if [ $# = 0 ]; then turn_on; else apply_custom "$@"; fi
	;;
report) report ;;
daemon) daemon ;;
*)
	echo "usage: battery.sh on | off | status | knobs | apply key=value ... | report | daemon" >&2
	exit 2
	;;
esac
