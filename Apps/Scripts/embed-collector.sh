#!/bin/sh
# Xcode build phase: builds bento-collector for every architecture in $ARCHS and embeds it, with
# its LaunchAgent plist, in the app. The outputs are declared in project.yml so Xcode re-signs the
# app bundle afterwards.
set -eu

export PATH="${HOME}/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
command -v cargo >/dev/null || { echo "error: cargo not found; install Rust (brew install rustup)"; exit 1; }

services="${SRCROOT}/../services"
if [ "${CONFIGURATION}" = "Release" ]; then
  profile=release
  profile_flag=--release
else
  profile=debug
  profile_flag=
fi

slices=""
for arch in ${ARCHS}; do
  case "${arch}" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "error: unsupported architecture ${arch}"; exit 1 ;;
  esac
  rustup target add "${triple}" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  cargo build --manifest-path "${services}/Cargo.toml" -p bento-collector --target "${triple}" ${profile_flag}
  slices="${slices} ${services}/target/${triple}/${profile}/bento-collector"
done

macos_dir="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
agents_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
mkdir -p "${macos_dir}" "${agents_dir}"
# shellcheck disable=SC2086
lipo -create ${slices} -output "${macos_dir}/bento-collector"
cp "${SRCROOT}/Bento/LaunchAgents/io.github.alexcding.bento.collector.plist" "${agents_dir}/"

# Nested executables are signed before Xcode signs the app bundle. Notarization needs a secure
# timestamp; ad-hoc and debug builds skip it so they work offline.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "${CONFIGURATION}" = "Release" ] && [ "${identity}" != "-" ]; then
  timestamp=--timestamp
else
  timestamp=--timestamp=none
fi
codesign --force --options runtime "${timestamp}" --sign "${identity}" "${macos_dir}/bento-collector"
