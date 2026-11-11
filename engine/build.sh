#!/bin/sh
# One-command engine build (E0 acceptance). arm64-only per D20.
# Requires: Xcode command line tools, CMake, Homebrew boost + openssl@3.
set -eu

cd "$(dirname "$0")"

# Reproducible checkout: libtorrent needs only its try_signal dependency in
# this build configuration (webtorrent is off). No-op when already present.
if [ -d ../.git ]; then
  git -C third_party/libtorrent submodule update --init --depth 1 deps/try_signal
fi

BUILD_DIR="${BUILD_DIR:-build}"
CONFIG="${CONFIG:-Release}"

cmake -S . -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PREFIX_PATH="/opt/homebrew;/opt/homebrew/opt/openssl@3" \
  -DBOOST_ROOT=/opt/homebrew \
  -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3

cmake --build "$BUILD_DIR" --config "$CONFIG" --parallel

echo "built: $BUILD_DIR/drift-engine"
"$BUILD_DIR/drift-engine" --version
