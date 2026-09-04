#!/usr/bin/env bash
# Sign a Flutter macOS app for Developer ID distribution, inside out.
#
#   Tools/sign-flutter-mac-app.sh "<path to .app>" "<signing identity>" "<entitlements plist>"
#
# A Flutter app carries nested code: the engine framework, every plugin's
# framework, and any dylib they bring. codesign's --deep is deprecated and
# signs the outer bundle with the entitlements the nested code should not
# have, so each piece of nested code is signed on its own first, with the
# hardened runtime and a secure timestamp (both preconditions for
# notarization), and the app bundle last with its entitlements.
#
# The identity "-" signs ad hoc, which is how the same script is checked on a
# developer's Mac without a certificate.
set -euo pipefail

APP="$1"
IDENTITY="$2"
ENTITLEMENTS="$3"

if [ ! -d "$APP" ]; then
  echo "no app bundle at $APP" >&2
  exit 1
fi

# The hardened runtime is a notarization precondition. Under an ad-hoc
# signature it also refuses to load any non-Apple library, since there is no
# team identity for the engine framework to share with the app, so a local
# dry run signs without it: the same structure, launchable.
OPTIONS=(--options runtime --timestamp)
if [ "$IDENTITY" = "-" ]; then
  OPTIONS=()
fi

sign() {
  codesign --force ${OPTIONS[@]+"${OPTIONS[@]}"} --sign "$IDENTITY" "$@"
}

# Nested code, deepest first: dylibs inside frameworks before the frameworks.
find "$APP/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm -u+x \) -not -path "*/Versions/*/Resources/*" 2>/dev/null | while read -r file; do
  if file "$file" | grep -q "Mach-O"; then
    sign "$file"
  fi
done
find "$APP/Contents/Frameworks" -type d -name "*.framework" 2>/dev/null | while read -r framework; do
  sign "$framework"
done

# The bundle itself carries the entitlements: sandbox, network client, the
# user-selected files the kubeconfig picker needs.
sign --entitlements "$ENTITLEMENTS" "$APP"

codesign --verify --strict --verbose=2 "$APP"
echo "signed $APP as $IDENTITY"
