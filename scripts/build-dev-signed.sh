#!/bin/sh
# Build Window Minder with the local self-signed "Window Minder Dev" identity.
# Xcode passes that name to codesign. This script does not read the Keychain.
set -eu
cd "$(dirname "$0")/.."
exec xcodebuild \
  -project WindowMinder.xcodeproj \
  -scheme WindowMinder \
  -configuration Debug \
  -destination 'platform=macOS' \
  build \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=Window Minder Dev" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  DEVELOPMENT_TEAM=
