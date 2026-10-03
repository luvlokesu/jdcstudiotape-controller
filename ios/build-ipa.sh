#!/bin/bash
# Compila la app del mando para iPhone / iPad SIN firmar y la empaqueta como JDController-unsigned.ipa (en esta carpeta).
# La usan el flujo de GitHub Actions (.github/workflows/ios.yml, macOS en la nube) y cualquier Mac con Xcode 15+.
# La .ipa sin firmar se instala firmándola con tu Apple ID (Sideloadly / AltStore; con cuenta gratuita dura 7 días)
# o con tu cuenta de desarrollador (TestFlight / ad hoc).
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate
rm -rf build Payload JDController-unsigned.ipa
xcodebuild -project JDController.xcodeproj -target JDController -configuration Release -sdk iphoneos \
  SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload
cp -R build/Release-iphoneos/JDController.app Payload/
zip -qry JDController-unsigned.ipa Payload
rm -rf Payload
echo "Lista: $PWD/JDController-unsigned.ipa ($(du -h JDController-unsigned.ipa | cut -f1))"
