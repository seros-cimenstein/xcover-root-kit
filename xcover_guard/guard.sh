#!/system/bin/sh
# xcover-guard: hold the XCover key (left side) to switch guard mode on or off.
# Guard mode: backlight off and touchscreen ignored, while the phone stays awake and unlocked,
# so agents keep driving it over adb (input, uiautomator, screencap) but nothing you touch
# reaches it. Runs as root (Magisk); installed by install.sh on the laptop.
#
#   guard.sh on|off|toggle|status   switch it by hand (e.g. adb shell su -c '... on')
#   guard.sh listen                  key listener + watchdog (started at boot from service.d)

DIR=/data/adb/xcover-guard
STATE=$DIR/state          # exists while guard mode is on; holds what to restore
PIDS=$DIR/listen.pid
TOUCH=/sys/class/sec/tsp/input/enabled
BL=/sys/class/backlight/panel/brightness
KEYDEV=/dev/input/event4  # gpio_keys
KEYCODE=00fc              # XCover key as `getevent -l` names it (code 252)
HOLD_S=0.7                # hold at least this long; shorter presses (pocket bumps) do nothing
NO_TIMEOUT=2147483647

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
		echo "bl=$(cat $BL)"
		echo "timeout=$(settings get system screen_off_timeout)"
	} >"$STATE"
	# Never time out, so the phone stays awake and unlocked for the agent.
	settings put system screen_off_timeout $NO_TIMEOUT
	echo 0 >"$TOUCH"
	echo 0 >"$BL"
	buzz 90
	log -t xcover-guard "on"
}

# $1 = "screen-off": the screen went off by itself (power key); the framework restores the
# backlight when it wakes, and writing it now would light an off panel.
guard_off() {
	echo 1 >"$TOUCH"
	[ -f "$STATE" ] || return 0
	bl=$(sed -n 's/^bl=//p' "$STATE")
	timeout=$(sed -n 's/^timeout=//p' "$STATE")
	rm -f "$STATE"
	case $timeout in '' | null) timeout=60000 ;; esac
	settings put system screen_off_timeout "$timeout"
	if [ "$1" != screen-off ]; then
		case $bl in '' | 0) bl=100 ;; esac
		echo "$bl" >"$BL"
		buzz 60
		sleep 0.15
		buzz 60
	fi
	log -t xcover-guard "off${1:+ ($1)}"
}

status() {
	if [ -f "$STATE" ]; then echo "guard: on"; else echo "guard: off"; fi
	if [ -f "$PIDS" ] && kill -0 "$(head -n1 "$PIDS")" 2>/dev/null; then
		echo "listener: running"
	else
		echo "listener: not running"
	fi
	echo "touch=$(cat $TOUCH) backlight=$(cat $BL)"
}

# While on: keep the backlight and touch off (the framework or driver may switch them back),
# and turn guard mode off if the screen goes off, so the phone is usable when woken.
watchdog() {
	while :; do
		if [ -f "$STATE" ]; then
			if ! awake; then
				guard_off screen-off
			else
				[ "$(cat $BL)" = 0 ] || echo 0 >"$BL"
				[ "$(cat $TOUCH)" = 0 ] || echo 0 >"$TOUCH"
			fi
		fi
		sleep 2
	done
}

listen() {
	mkdir -p "$DIR"
	# One listener: stop a previous one (re-install or manual restart).
	if [ -f "$PIDS" ]; then
		for p in $(cat "$PIDS"); do kill "$p" 2>/dev/null; done
		pkill -f "getevent -lt $KEYDEV" 2>/dev/null
	fi
	echo $$ >"$PIDS"
	# A boot or restart never leaves guard mode half on.
	[ -f "$STATE" ] && guard_off
	watchdog &
	echo $! >>"$PIDS"
	while :; do
		getevent -lt "$KEYDEV" 2>/dev/null |
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
				if [ -f "$STATE" ]; then guard_off; else guard_on; fi
			done
		sleep 2
	done
}

case $1 in
on) guard_on ;;
off) guard_off ;;
toggle) if [ -f "$STATE" ]; then guard_off; else guard_on; fi ;;
status) status ;;
listen) listen ;;
*)
	echo "usage: $0 on|off|toggle|status|listen" >&2
	exit 2
	;;
esac
