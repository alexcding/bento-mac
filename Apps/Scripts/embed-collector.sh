#!/bin/sh
# Xcode build phase of the BentoCollector helper target: builds bento-collector and the bundled
# protocol plugins for every architecture in $ARCHS and puts them in the helper's Contents/MacOS.
# Xcode then signs the helper with its entitlements; bento-collector is its main executable.
set -eu

export PATH="${HOME}/.cargo/bin:/opt/homebrew/opt/rustup/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
command -v cargo >/dev/null || { echo "error: cargo not found; install Rust (brew install rustup)"; exit 1; }

# The daemon finds plugin executables next to itself.
binaries="bento-collector bento-plugin-bilibili bento-plugin-telegram"

services="${SRCROOT}/../services"
if [ "${CONFIGURATION}" = "Release" ]; then
  profile=release
  profile_flag=--release
else
  profile=debug
  profile_flag=
fi

triples=""
for arch in ${ARCHS}; do
  case "${arch}" in
    arm64) triple=aarch64-apple-darwin ;;
    x86_64) triple=x86_64-apple-darwin ;;
    *) echo "error: unsupported architecture ${arch}"; exit 1 ;;
  esac
  rustup target add "${triple}" >/dev/null 2>&1 || true
  packages=""
  for binary in ${binaries}; do packages="${packages} -p ${binary}"; done
  # shellcheck disable=SC2086
  cargo build --manifest-path "${services}/Cargo.toml" ${packages} --target "${triple}" ${profile_flag}
  triples="${triples} ${triple}"
done

macos_dir="${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}"
mkdir -p "${macos_dir}"

# The plugins are nested code, signed here; Xcode signs the main executable with the bundle. Notarization needs a secure
# timestamp; ad-hoc and debug builds skip it so they work offline.
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [ "${CONFIGURATION}" = "Release" ] && [ "${identity}" != "-" ]; then
  timestamp=--timestamp
else
  timestamp=--timestamp=none
fi

for binary in ${binaries}; do
  slices=""
  for triple in ${triples}; do slices="${slices} ${services}/target/${triple}/${profile}/${binary}"; done
  # shellcheck disable=SC2086
  lipo -create ${slices} -output "${macos_dir}/${binary}"
  if [ "${binary}" != "${EXECUTABLE_NAME}" ]; then
    codesign --force --options runtime "${timestamp}" --sign "${identity}" "${macos_dir}/${binary}"
  fi
done
