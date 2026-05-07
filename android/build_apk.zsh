#!/usr/bin/env zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BUILD_TOOLS="${BUILD_TOOLS:-$ANDROID_HOME/build-tools/36.1.0}"
ANDROID_JAR="${ANDROID_JAR:-$ANDROID_HOME/platforms/android-36/android.jar}"

if [[ ! -f "$ANDROID_JAR" ]]; then
  ANDROID_JAR="$ANDROID_HOME/platforms/android-35/android.jar"
fi

AAPT2="$BUILD_TOOLS/aapt2"
D8="$ANDROID_HOME/cmdline-tools/latest/bin/d8"
ZIPALIGN="$BUILD_TOOLS/zipalign"
APKSIGNER="$BUILD_TOOLS/apksigner"
KEYSTORE="$ROOT_DIR/build/debug.keystore"
OUT_APK="$ROOT_DIR/dist/CodexRemote-debug.apk"

for tool in "$AAPT2" "$D8" "$ZIPALIGN" "$APKSIGNER" /usr/bin/javac /usr/bin/keytool; do
  [[ -x "$tool" || -f "$tool" ]] || {
    echo "Missing required build tool: $tool" >&2
    exit 1
  }
done
[[ -f "$ANDROID_JAR" ]] || {
  echo "Missing Android platform jar: $ANDROID_JAR" >&2
  exit 1
}

rm -rf "$ROOT_DIR/build"
mkdir -p "$ROOT_DIR/build/res" "$ROOT_DIR/build/gen" "$ROOT_DIR/build/classes" "$ROOT_DIR/build/dex" "$ROOT_DIR/dist"

"$AAPT2" compile --dir "$ROOT_DIR/res" -o "$ROOT_DIR/build/resources.zip"
"$AAPT2" link \
  -I "$ANDROID_JAR" \
  --manifest "$ROOT_DIR/AndroidManifest.xml" \
  --java "$ROOT_DIR/build/gen" \
  --auto-add-overlay \
  -o "$ROOT_DIR/build/base-unsigned.apk" \
  "$ROOT_DIR/build/resources.zip"

find "$ROOT_DIR/src" "$ROOT_DIR/build/gen" -name '*.java' | sort > "$ROOT_DIR/build/sources.txt"
javac -encoding UTF-8 --release 8 \
  -classpath "$ANDROID_JAR" \
  -d "$ROOT_DIR/build/classes" \
  @"$ROOT_DIR/build/sources.txt"

jar cf "$ROOT_DIR/build/classes.jar" -C "$ROOT_DIR/build/classes" .
"$D8" --min-api 26 --output "$ROOT_DIR/build/dex" "$ROOT_DIR/build/classes.jar"
cp "$ROOT_DIR/build/base-unsigned.apk" "$ROOT_DIR/build/app-unsigned.apk"
(cd "$ROOT_DIR/build/dex" && zip -qr "$ROOT_DIR/build/app-unsigned.apk" classes.dex)

"$ZIPALIGN" -f -p 4 "$ROOT_DIR/build/app-unsigned.apk" "$ROOT_DIR/build/app-aligned.apk"

if [[ ! -f "$KEYSTORE" ]]; then
  keytool -genkeypair \
    -keystore "$KEYSTORE" \
    -storepass android \
    -keypass android \
    -alias androiddebugkey \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Codex Remote Debug,O=Codex Remote,C=HK" >/dev/null
fi

"$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$OUT_APK" \
  "$ROOT_DIR/build/app-aligned.apk"

"$APKSIGNER" verify --verbose "$OUT_APK"
echo "APK: $OUT_APK"
