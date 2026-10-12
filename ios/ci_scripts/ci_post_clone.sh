#!/bin/sh
# Xcode Cloud: write Frame.io PKCE public-client values from workflow environment variables.
# Frameio.local.xcconfig is gitignored (kept out of the public repo); without this the build
# ships with an empty FrameioClientID. Empty-safe: missing vars reproduce the default
# behaviour (Frame.io login disabled, non-fatal).
set -eu

# Candidate (OpenCine CORE-02 + MEDIA-01): the Runner project takes OpenCineCore, OpenCineMedia
# and OpenCineNikon (VENDOR-02) from the OpenCine checkout at ../OpenCine, pinned by SHA in
# opencine-pins.txt. Works only once that repository is published and Xcode Cloud may read it.
# Delete when the app pins it by url + version.
"$CI_PRIMARY_REPOSITORY_PATH/scripts/checkout-opencine.sh"

cat > "$CI_PRIMARY_REPOSITORY_PATH/ios/Runner/Frameio.local.xcconfig" <<EOF
FRAMEIO_CLIENT_ID = ${FRAMEIO_CLIENT_ID:-}
FRAMEIO_REDIRECT_URI = ${FRAMEIO_REDIRECT_URI:-}
FRAMEIO_URL_SCHEME = ${FRAMEIO_URL_SCHEME:-}
EOF

if [ -z "${FRAMEIO_CLIENT_ID:-}" ]; then
  echo "warning: FRAMEIO_CLIENT_ID not set — Frame.io login will be disabled in this build."
fi

# Sentry public DSN for the Cocoa SDK (SENTRY_DSN_IOS, SENTRY_DSN the fallback), written by
# OpenCine's shared script so https:// is not read as an xcconfig comment. Never echo the value.
cd "$CI_PRIMARY_REPOSITORY_PATH"
if [ "${SENTRY_UPLOAD_ENABLED:-}" = "true" ]; then
  python3 ../OpenCine/scripts/sentry/sentry-dsn-xcconfig.py --out ios/Runner/Reliability.local.xcconfig --require
else
  python3 ../OpenCine/scripts/sentry/sentry-dsn-xcconfig.py --out ios/Runner/Reliability.local.xcconfig
fi
