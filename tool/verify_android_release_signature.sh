#!/usr/bin/env bash
# Check the JAR signature used by some OEM installers as well as Android's v2 block.
set -euo pipefail
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
apk="${1:?Usage: tool/verify_android_release_signature.sh APK}"
apksigner="$ANDROID_HOME/build-tools/36.0.0/apksigner"
# The app targets minSdk 24. Asking the verifier to cover API 23 as well
# makes it actually validate the v1 signature, even on a v2-capable APK.
certs="$("$apksigner" verify --verbose --print-certs --min-sdk-version 23 "$apk")"
for scheme in 'v1 scheme (JAR signing)' 'v2 scheme (APK Signature Scheme v2)'; do
  grep -Fxq "Verified using $scheme: true" <<< "$certs" || {
    echo "APK is missing a valid $scheme: $apk" >&2; exit 1;
  }
done
# SHA-256 of the established production signer (public certificate, not the key).
production_cert=e3b7ff5dabbafc1dab652a2893b163547b1fb2c51d8e508ace7945a271581c4f
[[ "$(awk '/^Signer #[0-9]+ certificate SHA-256 digest:/{print $NF}' <<< "$certs")" == "$production_cert" ]] || {
  echo "APK does not have the established production signer: $apk" >&2; exit 1;
}
