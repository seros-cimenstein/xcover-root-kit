#!/system/bin/sh
# battery-optimiser: cuts the battery drain of the rooted Galaxy XCover Pro (SM-G715FN,
# Android 13) and caps charging at 85 % for battery life. Runs as root (Magisk); installed to
# /data/adb/battery-optimiser by install.sh. See README.md for what each knob does and the
# measurements behind it.
#
#   battery.sh on                  apply the optimised values (the stock ones are saved first)
#   battery.sh off                 put the saved stock values back
#   battery.sh get | toggle        print on/off | switch on<->off and print the new state (tile)
#   battery.sh status              every knob (now / optimised / stock), screen, battery, daemon
#   battery.sh now                 the app's readout: state, screen, battery, limit, frozen, daemon
#   battery.sh knobs               machine-readable: key=<live>, key.want=, key.stock=,
#                                  key.default=, key.options=
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
EXEMPT=$DIR/exempt    # "user|add|sys <pkg>": Doze exemptions exempt/exempt_sys removed or added
ALLOWED=$DIR/allowed  # "<pkg> <0|1> <mode>": what `allow` changed per app, undone on removal
GUARD=/data/adb/xcover-guard/state # exists while xcover_guard's guard mode is on
BL=/sys/class/backlight/panel/brightness
BATT=/sys/class/power_supply/battery
FREEZER=/dev/freezer
FZ=$FREEZER/battery-optimiser
POLL_S=5

# allow comes before exempt: an app leaving allow is settled (exemption taken back, or handed
# to exempt) before exempt sorts the user exemptions into its own and the user's.
KEYS="wifi_scan ble_scan bluetooth screen_timeout stay_awake protect_battery fast_charge doze allow exempt exempt_sys freeze"
# Held knobs are put back by the daemon (checked when the screen goes off); the others are
# only applied by on/apply, so turning Bluetooth on or changing the timeout by hand sticks.
HELD="wifi_scan ble_scan protect_battery fast_charge doze allow exempt exempt_sys"
TIMEOUTS="15000 30000 60000 120000 300000 600000 1800000 2147483647"
# Doze (DeviceIdleController, DeviceConfig namespace device_idle). Stock: light doze 1 min after
# the screen goes off, deep doze only after 15 min inactive + 20 min idle-pending with no motion.
# sensing_to/locating_to stay stock: on Android 13 a sensing timeout restarts the progression.
DOZE="light_after_inactive_to=15000 light_idle_to=900000 light_max_idle_to=3600000 \
inactive_to=30000 idle_after_inactive_to=15000 motion_inactive_to=60000"
# System Doze exemptions that `exempt_sys=remove` removes: Google Play services (push messages wait
# for Doze's maintenance windows) and Samsung extras. Never removed: dialer, messages, IMS
# (VoLTE calls), emergency alerts and SOS, clock, contacts, Knox Guard, CSC, provisioning, shell.
SYS_EXTRA="com.google.android.gms com.android.providers.calendar com.android.providers.downloads \
com.sec.android.easyonehand com.samsung.android.app.smartcapture \
com.samsung.android.allshare.service.fileshare com.samsung.adaptivebrightnessgo \
com.samsung.android.bluelightfilter com.samsung.android.sdk.handwriting com.samsung.android.video"

# D = optimised default of knob $1.
default() {
	case $1 in
	wifi_scan | ble_scan | bluetooth | stay_awake | fast_charge) D=0 ;;
	screen_timeout) D=30000 ;;
	protect_battery) D=1 ;;
	doze) D=aggressive ;;
	exempt | exempt_sys) D=keep ;;
	allow) D=none ;;
	freeze) D=mosh-client ;;
	esac
}

# O = allowed values of knob $1 (freeze: a comma list of process names, or none).
options() {
	case $1 in
	wifi_scan | ble_scan | bluetooth | protect_battery | fast_charge) O="0 1" ;;
	screen_timeout) O=$TIMEOUTS ;;
	stay_awake) O="0 1 2 3 4 5 6 7" ;;
	doze) O="stock aggressive" ;;
	exempt) O="keep|none|package[,package...]" ;;
	exempt_sys) O="keep remove" ;;
	allow) O="none|package[,package...]" ;;
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
	# Samsung's "Fast charging" (9 V adaptive fast charging); 0 charges at 5 V: less current, less heat.
	fast_charge) T=system N=adaptive_fast_charging ;;
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
	elif [ "$1" = exempt ]; then
		live_exempt
	elif [ "$1" = exempt_sys ]; then
		# remove once every SYS_EXTRA exemption we took is still gone; with none recorded and
		# none left (packages missing) both values look the same, so the wanted one.
		exemptions
		records
		if [ -n "$ES" ]; then L=keep; elif [ -n "$R_SYS" ]; then L=remove; else L=$v_exempt_sys; fi
	elif [ "$1" = allow ]; then
		live_allow
	else
		eval "L=\$v_$1" # freeze: nothing to read back; the daemon applies it
	fi
}

# EU = user Doze exemptions now (apps set to "Unrestricted") except the `allow` ones, WU = every
# user exemption, ES = the SYS_EXTRA ones still exempt, WL = every exempt package (user and
# system); space-separated.
exemptions() {
	EU= WU= ES= WL=
	for line in $(dumpsys deviceidle whitelist); do
		p=${line#*,}
		p=${p%%,*}
		case $line in
		user,* | system,*) WL="${WL:+$WL }$p" ;;
		esac
		case $line in
		user,*)
			WU="${WU:+$WU }$p"
			case ",$v_allow," in *",$p,"*) ;; *) EU="${EU:+$EU }$p" ;; esac
			;;
		system,*) case " $SYS_EXTRA " in *" $p "*) ES="${ES:+$ES }$p" ;; esac ;;
		esac
	done
}

# R_USER / R_ADD / R_SYS = what EXEMPT records: user exemptions `exempt` removed, exemptions
# `exempt` added, SYS_EXTRA exemptions `exempt_sys` removed (space-separated).
records() {
	R_USER= R_ADD= R_SYS=
	[ -f "$EXEMPT" ] || return 0
	while read -r kind p; do
		case $kind in
		user) R_USER="$R_USER $p" ;;
		add) R_ADD="$R_ADD $p" ;;
		sys) R_SYS="$R_SYS $p" ;;
		esac
	done <"$EXEMPT"
}

# Writes R_USER / R_ADD / R_SYS back to EXEMPT (removed when empty).
save_records() {
	{
		for p in $R_USER; do echo "user $p"; done
		for p in $R_ADD; do echo "add $p"; done
		for p in $R_SYS; do echo "sys $p"; done
	} >"$EXEMPT.tmp" && mv "$EXEMPT.tmp" "$EXEMPT"
	[ -s "$EXEMPT" ] || rm -f "$EXEMPT"
}

# L = the `exempt` packages (v_exempt) that are user-exempt now, then the other user exemptions
# outside `allow`; "none" if empty. keep while nothing is recorded and that list isn't the
# wanted one: the user exemptions are as found (before the first change, or one added by hand
# since, which then differs from a wanted list either way).
live_exempt() {
	exemptions
	records
	L=
	for p in ${v_exempt//,/ }; do
		case " $WU " in *" $p "*) L="${L:+$L,}$p" ;; esac
	done
	for p in $EU; do
		case ",$v_exempt," in *",$p,"*) ;; *) L="${L:+$L,}$p" ;; esac
	done
	L=${L:-none}
	[ -z "$R_USER$R_ADD" ] && [ "$L" != "$v_exempt" ] && L=keep
}

# Takes back an exemption `exempt` added to package $1. An `allow` app that allow found exempt
# (because of us) gets allow's flag instead, so taking it off `allow` removes the exemption.
unadd() {
	if [ -f "$ALLOWED" ] && grep -q "^$1 0 " "$ALLOWED"; then
		while read -r p wl mode; do
			[ "$p" = "$1" ] && wl=1
			echo "$p $wl $mode"
		done <"$ALLOWED" >"$ALLOWED.tmp" && mv "$ALLOWED.tmp" "$ALLOWED"
	else
		dumpsys deviceidle whitelist "-$1" >/dev/null 2>&1 || ERR="$ERR exempt:$1"
	fi
}

# User Doze exemptions $1: keep puts back what we removed and takes back what we added; a
# comma list (or none) makes exactly those packages exempt: other user exemptions are removed
# (never the `allow` apps), missing ones added. Everything is recorded so keep/off undo it.
put_exempt() {
	records
	if [ "$1" = keep ]; then
		for p in $R_USER; do dumpsys deviceidle whitelist "+$p" >/dev/null 2>&1 || ERR="$ERR exempt:$p"; done
		for p in $R_ADD; do unadd "$p"; done
		R_USER= R_ADD=
	else
		list=${1//,/ }
		[ "$1" = none ] && list=
		exemptions
		nu= na=
		for p in $R_ADD; do
			case " $list " in *" $p "*) na="$na $p" ;; *) unadd "$p" ;; esac
		done
		for p in $R_USER; do
			case " $list " in
			*" $p "*) dumpsys deviceidle whitelist "+$p" >/dev/null 2>&1 || ERR="$ERR exempt:$p" ;;
			*) nu="$nu $p" ;;
			esac
		done
		# EU was read before unadd: our own additions are not the user's exemptions.
		for p in $EU; do
			case " $list $R_ADD " in
			*" $p "*) ;;
			*)
				nu="$nu $p"
				dumpsys deviceidle whitelist "-$p" >/dev/null 2>&1 || ERR="$ERR exempt:$p"
				;;
			esac
		done
		for p in $list; do
			case " $WU $R_USER $na " in
			*" $p "*) ;;
			*)
				na="$na $p"
				dumpsys deviceidle whitelist "+$p" >/dev/null 2>&1 || ERR="$ERR exempt:$p"
				;;
			esac
		done
		R_USER=$nu R_ADD=$na
	fi
	save_records
}

# SYS_EXTRA exemptions $1: keep puts back what we removed, remove removes the ones still there.
put_exempt_sys() {
	records
	for p in $R_SYS; do dumpsys deviceidle sys-whitelist "+$p" >/dev/null 2>&1 || ERR="$ERR exempt_sys:$p"; done
	R_SYS=
	if [ "$1" = remove ]; then
		exemptions
		for p in $ES; do
			R_SYS="$R_SYS $p"
			dumpsys deviceidle sys-whitelist "-$p" >/dev/null 2>&1 || ERR="$ERR exempt_sys:$p"
		done
	fi
	save_records
}

# M = RUN_ANY_IN_BACKGROUND app-op mode of package $1: ignore means "Restricted" in the app's
# battery settings (the system kills it once it is cached in the background).
bgmode() {
	M=$(cmd appops get "$1" RUN_ANY_IN_BACKGROUND 2>/dev/null)
	case $M in
	RUN_ANY_IN_BACKGROUND:*)
		M=${M#*: }
		M=${M%%;*}
		;;
	*) M=default ;;
	esac
}

# L = the `allow` packages (v_allow) that are "Unrestricted" now (Doze-exempt and not
# background-restricted), then the ones we changed earlier that are no longer listed (so
# removing an app from the list differs from the live value and gets undone); "none" if empty.
live_allow() {
	exemptions
	L=
	for p in ${v_allow//,/ }; do
		[ "$p" = none ] && continue
		case " $WL " in *" $p "*) ;; *) continue ;; esac
		bgmode "$p"
		case $M in ignore | deny) continue ;; esac
		L="${L:+$L,}$p"
	done
	[ -f "$ALLOWED" ] && while read -r p _; do
		case ",$v_allow," in *",$p,"*) ;; *) L="${L:+$L,}$p" ;; esac
	done <"$ALLOWED"
	L=${L:-none}
}

# Makes the packages in $1 (comma list or none) "Unrestricted" and undoes it for packages no
# longer listed. ALLOWED records per package what we changed: "<pkg> <1 if we added the Doze
# exemption> <app-op mode before>", so removal puts back exactly that.
put_allow() {
	list=${1//,/ }
	[ "$1" = none ] && list=
	if [ -f "$ALLOWED" ]; then
		: >"$ALLOWED.tmp"
		while read -r p wl mode; do
			case " $list " in
			*" $p "*) echo "$p $wl $mode" >>"$ALLOWED.tmp" ;;
			*)
				# An app `exempt` lists stays exempt, now as exempt's addition.
				if [ "$wl" = 1 ]; then
					case ",$v_exempt," in
					*",$p,"*) echo "add $p" >>"$EXEMPT" ;;
					*) dumpsys deviceidle whitelist "-$p" </dev/null >/dev/null 2>&1 ;;
					esac
				fi
				case $mode in
				ignore | deny)
					cmd appops set "$p" RUN_ANY_IN_BACKGROUND "$mode" </dev/null >/dev/null 2>&1 || ERR="$ERR allow:$p"
					;;
				esac
				;;
			esac
		done <"$ALLOWED"
		mv "$ALLOWED.tmp" "$ALLOWED"
	fi
	exemptions
	for p in $list; do
		bgmode "$p"
		known=
		[ -f "$ALLOWED" ] && while read -r q _; do [ "$q" = "$p" ] && known=1; done <"$ALLOWED"
		if [ -z "$known" ]; then
			wl=0
			case " $WL " in
			*" $p "*) ;;
			*)
				# Removed by `exempt` earlier: it was the user's own exemption, so it stays
				# when it leaves the allow list again (and `exempt` removes it then if unlisted).
				if [ -f "$EXEMPT" ] && grep -qxF "user $p" "$EXEMPT"; then
					grep -vxF "user $p" "$EXEMPT" >"$EXEMPT.tmp"
					mv "$EXEMPT.tmp" "$EXEMPT"
				else
					wl=1
				fi
				;;
			esac
			echo "$p $wl $M" >>"$ALLOWED"
		fi
		case " $WL " in *" $p "*) ;; *) dumpsys deviceidle whitelist "+$p" >/dev/null 2>&1 || ERR="$ERR allow:$p" ;; esac
		case $M in ignore | deny) cmd appops set "$p" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || ERR="$ERR allow:$p" ;; esac
	done
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
	elif [ "$1" = exempt ]; then
		put_exempt "$2"
	elif [ "$1" = exempt_sys ]; then
		put_exempt_sys "$2"
	elif [ "$1" = allow ]; then
		put_allow "$2"
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
	# State first: a daemon round in between would otherwise see "on" and put held knobs back
	# (it turned Protect battery on again in the middle of an `off` once).
	echo off >"$STATE"
	poke
	load_stock
	ERR=
	for k in $KEYS; do
		eval "s=\$s_$k"
		[ -n "$s" ] && put "$k" "$s"
	done
	rm -f "$STOCK"
	thaw
	[ -z "$ERR" ] || { echo "not all restored (refused):$ERR" >&2; return 1; }
}

# apply key=value ...: validates everything first; nothing is written unless all of it is valid.
apply_custom() {
	want
	bad= installed=
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
		elif [ "$k" = allow ] || [ "$k" = exempt ]; then
			# Installed package names, comma-separated (exempt: or keep).
			case $k=$v in
			*=none | exempt=keep) eval "v_$k=\$v" ;;
			*=*[!A-Za-z0-9._,]* | *=,* | *, | *,,*) bad="$bad
$k: $v is not $O" ;;
			*)
				[ -n "$installed" ] || installed=" $(pm list packages | sed 's/^package://' | tr '\n' ' ') "
				miss=
				for p in ${v//,/ }; do
					case $installed in *" $p "*) ;; *) miss="$miss $p" ;; esac
				done
				if [ -n "$miss" ]; then
					bad="$bad
$k: not installed:$miss"
				else
					eval "v_$k=\$v"
				fi
				;;
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

# Puts back held knobs that something else changed (forks; run when the screen goes off). A knob
# with no stock value yet (one added by an update) gets it recorded first, so `off` restores it.
hold() {
	load_stock
	for k in $HELD; do
		eval "w=\$v_$k s=\$s_$k"
		live "$k"
		if [ "$L" != "$w" ]; then
			log -t battery-optimiser "rewritten: $k=$L, re-applying $w"
			[ -z "$s" ] && echo "$k=$L" >>"$STOCK"
			put "$k" "$w"
		fi
	done
}

# DPID = the daemon's pid if it runs (builtin reads only). The pid file can be left from a
# previous boot, its number now used by another process, so the command line must be ours:
# with `kill -0` alone a media.codec thread passed for phone_cooler's daemon, which then never
# started again after a reboot.
daemon_running() {
	DPID= dc=
	[ -f "$PIDFILE" ] && read -r DPID <"$PIDFILE" || return 1
	read -r dc 2>/dev/null <"/proc/$DPID/cmdline"
	case $dc in */battery.sh*daemon) ;; *) DPID= && return 1 ;; esac
}

daemon() {
	if daemon_running && [ "$DPID" != $$ ]; then
		echo "daemon already running (pid $DPID)" >&2
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
	frozen
	echo "frozen:${f:- none}"
	if daemon_running; then echo "daemon: running (pid $DPID)"; else echo "daemon: not running"; fi
}

# f = the frozen processes as " name(pid) ...".
frozen() {
	f=
	[ -f "$FZ/cgroup.procs" ] || return 0
	while read -r p; do
		c=
		read -r c 2>/dev/null <"/proc/$p/comm"
		f="$f $c($p)"
	done <"$FZ/cgroup.procs"
}

# The app's 2 s readout: builtin reads only, key=value lines.
now() {
	if is_on; then echo "state=on"; else echo "state=off"; fi
	screen
	battery
	read -r P <"$BATT/capacity"
	read -r cur <"$BATT/current_now"
	read -r cap <"$BATT/batt_full_capacity"
	frozen
	daemon_running
	g=0
	[ -f "$GUARD" ] && g=1
	echo "screen=$S"
	echo "level=$P"
	echo "status=$B"
	echo "current=$cur"
	echo "limit=$cap"
	echo "frozen=${f# }"
	echo "daemon=$DPID"
	echo "guard=$g"
}

knobs() {
	want
	load_stock
	if is_on; then echo "state=on"; else echo "state=off"; fi
	for k in $KEYS; do
		live "$k"
		options "$k"
		default "$k"
		eval "echo \"$k=\$L\"; echo \"$k.want=\$v_$k\"; echo \"$k.stock=\$s_$k\""
		echo "$k.default=$D"
		echo "$k.options=$O"
	done
	# exempt: the user exemptions now (outside allow) and what exempt removed or added;
	# exempt_sys: what it removed (comma lists, for the app).
	exemptions
	records
	echo "exempt.apps=${EU// /,}"
	r=${R_USER# } a=${R_ADD# } s=${R_SYS# }
	echo "exempt.removed=${r// /,}"
	echo "exempt.added=${a// /,}"
	echo "exempt_sys.removed=${s// /,}"
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
get) if is_on; then echo on; else echo off; fi ;;
toggle)
	if is_on; then turn_off && echo off; else turn_on && echo on; fi
	;;
status) status ;;
now) now ;;
knobs) knobs ;;
apply)
	shift
	if [ $# = 0 ]; then turn_on; else apply_custom "$@"; fi
	;;
report) report ;;
daemon) daemon ;;
*)
	echo "usage: battery.sh on | off | get | toggle | status | now | knobs | apply key=value ... | report | daemon" >&2
	exit 2
	;;
esac
