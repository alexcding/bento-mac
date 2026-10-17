#!/bin/sh
# Xcode build phase: builds bento-collector and embeds it, with its LaunchAgent plist, in the app.
set -eu

export PATH="${HOME}/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
command -v cargo >/dev/null || { echo "error: cargo not found; install Rust (brew install rustup)"; exit 1; }

services="${SRCROOT}/../services"
if [ "${CONFIGURATION}" = "Release" ]; then
  profile=release
  cargo build --manifest-path "${services}/Cargo.toml" -p bento-collector --release
else
  profile=debug
  cargo build --manifest-path "${services}/Cargo.toml" -p bento-collector
fi

macos_dir="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
agents_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
mkdir -p "${macos_dir}" "${agents_dir}"
cp "${services}/target/${profile}/bento-collector" "${macos_dir}/bento-collector"
cp "${SRCROOT}/Bento/LaunchAgents/"*.plist "${agents_dir}/"

# Nested executables are signed before Xcode signs the app bundle.
codesign --force --options runtime --timestamp=none \
  --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "${macos_dir}/bento-collector"
