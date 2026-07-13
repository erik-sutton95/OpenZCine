#!/bin/sh
# Xcode Cloud: write Frame.io PKCE public-client values from workflow environment variables.
# Frameio.local.xcconfig is gitignored (kept out of the public repo); without this the build
# ships with an empty FrameioClientID. Empty-safe: missing vars reproduce the default
# behaviour (Frame.io login disabled, non-fatal).
set -eu

cat > "$CI_PRIMARY_REPOSITORY_PATH/ios/Runner/Frameio.local.xcconfig" <<EOF
FRAMEIO_CLIENT_ID = ${FRAMEIO_CLIENT_ID:-}
FRAMEIO_REDIRECT_URI = ${FRAMEIO_REDIRECT_URI:-}
FRAMEIO_URL_SCHEME = ${FRAMEIO_URL_SCHEME:-}
EOF

if [ -z "${FRAMEIO_CLIENT_ID:-}" ]; then
  echo "warning: FRAMEIO_CLIENT_ID not set — Frame.io login will be disabled in this build."
fi
