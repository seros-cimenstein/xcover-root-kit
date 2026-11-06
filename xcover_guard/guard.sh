#!/system/bin/sh
# xcover-guard: hold the XCover key (left side) to switch guard mode on or off.
# Guard mode: backlight off and touches ignored, while the phone stays awake and unlocked, so
# agents keep driving it over adb (input, uiautomator, screencap) but nothing you touch reaches
# it. Runs as root (Magisk); installed by install.sh on the laptop.
#
#   guard.sh on|off|toggle|status   switch it by hand (e.g. adb shell su -c '... on')
#   guard.sh listen                  key listener + watchdog (started at boot from service.d)

DIR=/data/adb/xcover-guard
STATE=$DIR/state          # exists while guard mode is on; holds what to restore
LOCK=$DIR/lock            # held while guard mode changes or the watchdog checks it
PIDS=$DIR/listen.pid     # the listener's main loop and watchdog (pids, checked before use)
TICK=$DIR/tick           # fifo: guard_on wakes the watchdog, which sleeps on it while off
GRAB=$DIR/touchgrab       # holds an exclusive grab on the touchscreen (see touchgrab.c)
GRABPID=$DIR/grab.pid    # the touchgrab started last: the watchdog's cheap liveness check
# The panel driver relights the backlight whenever Android writes a brightness, even with
# bl_power off; so guard mode also sets Android's brightness to its minimum (1 of 306: a write
# lights almost nothing) and the watchdog puts the raw brightness back to 0 within 0.5 s.
BLPOWER=/sys/class/backlight/panel/bl_power
BL=/sys/class/backlight/panel/brightness
KEYCODE=00fc              # XCover key as `getevent -l` names it (code 252)
HOLD_S=0.7                # hold at least this long; shorter presses (pocket bumps) do nothing
NO_TIMEOUT=2147483647

# /dev/input/eventN of the input device named $1 (numbers can change between boots).
input_dev() {
	awk -v name="$1" '
		/^N: / { hit = ($0 == "N: Name=\"" name "\"") }
		hit && /^H: / { for (i = 1; i <= NF; i++) if ($i ~ /^event/) { print "/dev/input/" $i; exit } }
	' /proc/bus/input/devices
}

# Run "$@" holding the lock, so a toggle (key or adb) and the watchdog never interleave.
locked() {
	(flock 9 && "$@") 9>"$LOCK"
}

# True if pid $1 is a guard.sh listener (main loop or watchdog). A pid file can be left from a
# previous boot, when its numbers belong to other processes: never kill one without this check.
is_listener() {
	c=
	[ -n "$1" ] && read -r c 2>/dev/null <"/proc/$1/cmdline"
	case $c in */guard.sh*listen) ;; *) return 1 ;; esac
}

# Stops a running listener: its main loop, its watchdog and its getevent.
stop_listener() {
	if [ -f "$PIDS" ]; then
		for p in $(cat "$PIDS"); do
			[ "$p" != $$ ] && is_listener "$p" && kill "$p"
		done
		rm -f "$PIDS"
	fi
	pkill -f "getevent -lt $(input_dev gpio_keys)"
}

# Grab the touchscreen (only one grab; a dead one is replaced). Grabs are killed by process
# name, not a saved pid, so none can be lost track of; the saved pid only lets the watchdog
# see the grab alive without forking. fd 9 (the lock) and fd 8 (the watchdog's fifo) are not
# inherited.
grab_touch() {
	pidof touchgrab >/dev/null && return 0
	"$GRAB" "$(input_dev sec_touchscreen)" 9>&- 8>&- &
	echo $! >"$GRABPID"
}

# True if the touchgrab started last still runs (builtin reads only).
grabbed() {
	gp= gc=
	read -r gp 2>/dev/null <"$GRABPID"
	[ -n "$gp" ] && read -r gc 2>/dev/null <"/proc/$gp/cmdline"
	case $gc in */touchgrab*) ;; *) return 1 ;; esac
}

buzz() {
	cmd vibrator_manager synced -f oneshot "$1" >/dev/null 2>&1
}

awake() {
	dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
}

guard_on() {
	[ -f "$STATE" ] && return 0
	if ! awake; then
		echo "screen is off: wake and unlock the phone first" >&2
		return 1
	fi
	{
		echo "timeout=$(settings get system screen_off_timeout)"
		echo "brightness=$(settings get system screen_brightness)"
	} >"$STATE"
	# Never time out, so the phone stays awake and unlocked for the agent.
	settings put system screen_off_timeout $NO_TIMEOUT
	grab_touch
	settings put system screen_brightness 1
	echo 0 >"$BL"
	echo 4 >"$BLPOWER"
	buzz 90
	# Wake the watchdog (it sleeps on the fifo while guard mode is off).
	[ -p "$TICK" ] && echo on 1<>"$TICK"
	log -t xcover-guard "on"
}

# $1 = "screen-off": the screen went off by itself (power key); no buzz then.
# Off never leaves a grab behind, even without state: a stray one would keep the screen lit
# but deaf to touch.
guard_off() {
	pkill -x touchgrab
	[ -f "$STATE" ] || return 0
	timeout=$(sed -n 's/^timeout=//p' "$STATE")
	brightness=$(sed -n 's/^brightness=//p' "$STATE")
	rm -f "$STATE"
	echo 0 >"$BLPOWER"
	case $brightness in '' | null | 0 | 1) brightness=100 ;; esac
	# Android writes the panel brightness itself when its setting changes.
	settings put system screen_brightness "$brightness"
	case $timeout in '' | null) timeout=60000 ;; esac
	settings put system screen_off_timeout "$timeout"
	if [ "$1" != screen-off ]; then
		buzz 60
		sleep 0.15
		buzz 60
	fi
	log -t xcover-guard "off${1:+ ($1)}"
}

toggle() {
	if [ -f "$STATE" ]; then guard_off; else guard_on; fi
}

status() {
	if [ -f "$STATE" ]; then echo "guard: on"; else echo "guard: off"; fi
	read -r p 2>/dev/null <"$PIDS"
	if is_listener "$p"; then
		echo "listener: running"
	else
		echo "listener: not running"
	fi
	if pidof touchgrab >/dev/null; then g=grabbed; else g=free; fi
	echo "touch=$g backlight=$([ "$(cat $BLPOWER)" = 0 ] && echo on || echo off)"
}

# One watchdog step, under the lock. Off: make sure no grab is left. On: keep the backlight off;
# with $1 = check, also turn guard mode off if the screen went off, else re-grab the touchscreen.
# Returns 1 while guard mode is off.
watch_step() {
	if [ ! -f "$STATE" ]; then
		pkill -x touchgrab
		return 1
	fi
	if [ "$1" = check ] && ! awake; then
		guard_off screen-off
		return 0
	fi
	read -r x <"$BL"
	[ "$x" = 0 ] || echo 0 >"$BL"
	read -r x <"$BLPOWER"
	[ "$x" = 4 ] || echo 4 >"$BLPOWER"
	[ "$1" = check ] && grab_touch
	return 0
}

# While on: the backlight every 0.5 s and the grab every 2 s with builtin reads, the screen
# every 2 s (dumpsys), so the phone is usable when woken; the lock is only taken to fix
# something. While off: it sleeps on the fifo until guard_on writes to it, so it costs nothing.
# (Polling every 2 s while off, with pkill/flock/subshells each round, took 8.7 % of a core all
# day; while on, pidof and flock every 2 s doubled the cost of the screen check.)
# The fifo stays open on fd 8, so a write while the watchdog is busy is not lost.
watchdog() {
	exec 8<>"$TICK"
	n=0
	while :; do
		if [ ! -f "$STATE" ]; then
			if [ $n != 0 ]; then
				# Just turned off. A grab forked by a re-grab right before guard off may not
				# have been named touchgrab yet when guard off killed it; this sweep gets it.
				n=0
				read -r -t 1 -u8 _
				locked watch_step
				continue
			fi
			read -r -u8 _
			continue
		fi
		n=$((n + 1))
		b= p=
		read -r b <"$BL"
		read -r p <"$BLPOWER"
		if [ "$b" != 0 ] || [ "$p" != 4 ]; then
			locked watch_step
		elif [ $((n % 4)) = 0 ] && { ! grabbed || ! awake; }; then
			locked watch_step check
		fi
		read -r -t 0.5 -u8 _
	done
}

listen() {
	mkdir -p "$DIR"
	[ -p "$TICK" ] || mkfifo "$TICK"
	keydev=$(input_dev gpio_keys)
	# One listener: stop a previous one (re-install or manual restart).
	stop_listener
	echo $$ >"$PIDS"
	# A boot or restart never leaves guard mode half on.
	locked guard_off
	watchdog &
	echo $! >>"$PIDS"
	while :; do
		getevent -lt "$keydev" 2>/dev/null |
			awk -v code="$KEYCODE" -v hold="$HOLD_S" '
				$0 ~ code {
					gsub(/[\[\]]/, "")
					if ($NF == "DOWN") d = $1
					else if ($NF == "UP") {
						if (d != "" && $1 - d >= hold) { print "toggle"; fflush() }
						d = ""
					}
				}' |
			while read -r _; do
				locked toggle
			done
		sleep 2
	done
}

case $1 in
on) locked guard_on ;;
off) locked guard_off ;;
toggle) locked toggle ;;
status) status ;;
listen) listen ;;
stop) stop_listener ;;
*)
	echo "usage: $0 on|off|toggle|status|listen|stop" >&2
	exit 2
	;;
esac
