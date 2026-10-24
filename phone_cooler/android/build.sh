#!/usr/bin/env bash
# Builds cooler.apk without Gradle: aapt2 compile/link -> javac -> d8 -> zipalign -> apksigner.
# Needs a JDK and, from the Android SDK, build-tools plus a platform android.jar (API 30). By
# default it reuses LanPad's ../../phone_synaptic_trackpad/.sdk; if that is missing they are
# downloaded there (~150 MB) unless SDK / ANDROID_BUILD_TOOLS / ANDROID_JAR are set.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd .. && pwd)
SDK=${SDK:-$(cd "$ROOT/.." && pwd)/phone_synaptic_trackpad/.sdk}
BT=${ANDROID_BUILD_TOOLS:-$SDK/android-37.0}
JAR=${ANDROID_JAR:-$SDK/android-11/android.jar}

if [[ ! -x $BT/d8 || ! -f $JAR ]]; then
    mkdir -p "$SDK"
    for z in build-tools_r37_linux.zip platform-30_r03.zip; do
        curl -fsSL -o "$SDK/$z" "https://dl.google.com/android/repository/$z"
        unzip -q -o "$SDK/$z" -d "$SDK"
        rm "$SDK/$z"
    done
fi

OUT=build
rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex" "$OUT/gen"

"$BT/aapt2" compile --dir res -o "$OUT/res.zip"
"$BT/aapt2" link -I "$JAR" --manifest AndroidManifest.xml --java "$OUT/gen" -o "$OUT/unsigned.apk" \
    "$OUT/res.zip"

javac --release 11 -nowarn -Xlint:-options -encoding UTF-8 -classpath "$JAR" -d "$OUT/classes" \
    $(find src "$OUT/gen" -name '*.java')
"$BT/d8" --release --min-api 29 --lib "$JAR" --output "$OUT/dex" $(find "$OUT/classes" -name '*.class')
(cd "$OUT/dex" && "$BT/aapt" add -f ../unsigned.apk classes.dex >/dev/null)
"$BT/zipalign" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

# Debug-signed with the standard Android debug key (created if missing).
KS=${ANDROID_KEYSTORE:-$HOME/.android/debug.keystore}
if [[ ! -f $KS ]]; then
    mkdir -p "$(dirname "$KS")"
    keytool -genkeypair -keystore "$KS" -storepass android -keypass android -alias androiddebugkey \
        -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US"
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --v4-signing-enabled false \
    --out "$ROOT/cooler.apk" "$OUT/aligned.apk"
rm -rf "$OUT"
echo "built $ROOT/cooler.apk"
