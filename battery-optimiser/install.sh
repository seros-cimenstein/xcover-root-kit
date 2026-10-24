#!/usr/bin/env bash
# install.sh [install|uninstall|status|knobs|on|off|apply KEY=VALUE...|report] — battery-optimiser
# on the rooted phone, over adb.
# Uses $ANDROID_SERIAL, else the Tailscale address saved by phone-adb (remote_control), else
# the only adb device.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z ${ANDROID_SERIAL:-} ]]; then
	ip=$(sed -n 's/^ip=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/remote_control/phone-adb" 2>/dev/null || true)
	if [[ -n $ip ]] && adb devices | grep -q "^$ip:5555[[:space:]]*device"; then
		export ANDROID_SERIAL=$ip:5555
	fi
fi

dir=/data/adb/battery-optimiser
launcher=/data/adb/service.d/battery-optimiser.sh
apk=/data/local/tmp/battery-optimiser.apk

root() {
	adb shell "su -c '$1'"
}

# The pid is checked to still be the daemon (pids get reused).
stop_daemon() {
	root "p=\$(cat $dir/daemon.pid 2>/dev/null) && grep -q battery.sh /proc/\$p/cmdline 2>/dev/null && kill \$p; rm -f $dir/daemon.pid; true"
}

case ${1:-install} in
install)
	[[ $(adb shell su -c id 2>/dev/null) == *uid=0* ]] || { echo "no root over adb (Magisk: allow Shell)" >&2; exit 1; }
	android/build.sh
	adb push battery.sh /data/local/tmp/battery-optimiser.sh >/dev/null
	root "mkdir -p $dir && mv /data/local/tmp/battery-optimiser.sh $dir/battery.sh && chown root:root $dir/battery.sh && chmod 755 $dir/battery.sh"
	# Magisk runs service.d scripts after boot without waiting for them. The daemon re-applies
	# the held knobs at start and keeps them applied.
	printf '%s\n' '#!/system/bin/sh' \
		'# Installed by battery-optimiser/install.sh: keeps the battery settings after boot.' \
		'until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done' \
		"exec $dir/battery.sh daemon" |
		adb shell "su -c 'cat > $launcher && chmod 755 $launcher'"
	# A fresh install applies the optimised values; a reinstall keeps the state (on or off).
	root "[ -f $dir/state ] || $dir/battery.sh on"
	# (Re)start the daemon now, detached from this adb shell, so it runs the new script.
	stop_daemon
	root "setsid nohup $dir/battery.sh daemon >/dev/null 2>&1 </dev/null &"
	# The app is only staged: installing it needs the phone unlocked for Play Protect.
	adb push battery-optimiser.apk "$apk" >/dev/null
	echo "APK staged at $apk; install it with: adb shell pm install -r $apk"
	sleep 1
	root "$dir/battery.sh status"
	;;
uninstall)
	stop_daemon
	root "[ -x $dir/battery.sh ] && $dir/battery.sh off; rm -rf $dir $launcher $apk"
	echo "removed (stock settings restored); the Battery app, if installed, stays until you uninstall it"
	;;
status | knobs | on | off | report)
	root "$dir/battery.sh $1"
	;;
apply)
	shift
	(($#)) || { echo "usage: $0 apply KEY=VALUE ... (see: $0 knobs)" >&2; exit 2; }
	# Values are digits, words and process names; battery.sh validates them again.
	root "$dir/battery.sh apply $* && $dir/battery.sh status"
	;;
*)
	echo "usage: $0 [install|uninstall|status|knobs|on|off|apply KEY=VALUE...|report]" >&2
	exit 2
	;;
esac
