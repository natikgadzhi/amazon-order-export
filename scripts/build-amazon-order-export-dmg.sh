#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-AmazonOrderExport.xcodeproj}"
SCHEME="${SCHEME:-AmazonOrderExport}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-build/AmazonOrderExport.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-build/export}"
RELEASE_DIR="${RELEASE_DIR:-build/release}"
DMG_STAGING_DIR="${DMG_STAGING_DIR:-build/dmg}"
# Spaced display name, matching CFBundleDisplayName / INFOPLIST_KEY_CFBundleDisplayName.
APP_NAME="${APP_NAME:-Amazon Order Export.app}"
# Keep the DMG (and therefore the published asset) name space-free even though
# the app's display name has spaces. GitHub rewrites spaces in asset names to
# dots on upload, which would break `shasum -a 256 -c AmazonOrderExport-*.dmg`
# against the downloaded file and the Homebrew cask URL; a space-free name keeps
# verification working and the asset tidy (AmazonOrderExport-<version>.dmg).
DMG_BASENAME="${DMG_BASENAME:-AmazonOrderExport}"
DMG_VERSION="${DMG_VERSION:-}"
DMG_NAME="${DMG_NAME:-}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"

# Release-build inputs baked into the archive (default-safe so a local debug run
# works without secrets). SENTRY_DSN is the crash-reporting DSN compiled into
# official releases; CURRENT_PROJECT_VERSION is the "build N" shown in About.
SENTRY_DSN="${SENTRY_DSN:-}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-1}"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/amazon-order-export-release.XXXXXX")"
TEMP_KEYCHAIN_PATH="${TEMP_DIR}/release-signing.keychain-db"
TEMP_KEYCHAIN_PASSWORD="${TEMP_KEYCHAIN_PASSWORD:-$(uuidgen)}"
TEMP_NOTARY_KEY_PATH="${TEMP_DIR}/AuthKey.p8"
KEYCHAIN_CREATED=0

cleanup() {
  if [[ "${KEYCHAIN_CREATED}" == "1" && -f "${TEMP_KEYCHAIN_PATH}" ]]; then
    security delete-keychain "${TEMP_KEYCHAIN_PATH}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command codesign
require_command xcrun
require_command hdiutil
require_command ditto
require_command mktemp
require_command security
require_command base64
require_command curl

mkdir -p "${EXPORT_DIR}" "${RELEASE_DIR}" "${DMG_STAGING_DIR}"

decode_base64_to_file() {
  local input="$1"
  local output="$2"

  if base64 --help 2>&1 | grep -q -- '--decode'; then
    printf '%s' "${input}" | base64 --decode > "${output}"
  else
    printf '%s' "${input}" | base64 -D > "${output}"
  fi
}

import_signing_certificate_if_needed() {
  if [[ -z "${APPLE_DEVELOPER_ID_P12_BASE64:-}" ]]; then
    return
  fi

  # An empty export password is valid (`security import -P ""`), so only fail
  # when the variable is genuinely unset — `+set` distinguishes that from "".
  if [[ -z "${APPLE_DEVELOPER_ID_P12_PASSWORD+set}" ]]; then
    echo "APPLE_DEVELOPER_ID_P12_PASSWORD must be set (may be empty) when APPLE_DEVELOPER_ID_P12_BASE64 is set." >&2
    exit 1
  fi

  local cert_path="${TEMP_DIR}/developer-id.p12"
  decode_base64_to_file "${APPLE_DEVELOPER_ID_P12_BASE64}" "${cert_path}"

  security create-keychain -p "${TEMP_KEYCHAIN_PASSWORD}" "${TEMP_KEYCHAIN_PATH}"
  security set-keychain-settings -lut 21600 "${TEMP_KEYCHAIN_PATH}"
  security unlock-keychain -p "${TEMP_KEYCHAIN_PASSWORD}" "${TEMP_KEYCHAIN_PATH}"
  KEYCHAIN_CREATED=1

  local existing_keychains
  existing_keychains="$(security list-keychains -d user | tr -d '"')"
  # shellcheck disable=SC2086
  security list-keychains -d user -s "${TEMP_KEYCHAIN_PATH}" ${existing_keychains}
  security default-keychain -d user -s "${TEMP_KEYCHAIN_PATH}"

  security import "${cert_path}" \
    -k "${TEMP_KEYCHAIN_PATH}" \
    -P "${APPLE_DEVELOPER_ID_P12_PASSWORD}" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/xcodebuild

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "${TEMP_KEYCHAIN_PASSWORD}" \
    "${TEMP_KEYCHAIN_PATH}" >/dev/null
}

install_apple_intermediates_if_needed() {
  # Only needed in CI, where the temp keychain has no Apple intermediates and
  # the .p12 may not have shipped them. Without the intermediate, the leaf
  # cert fails chain validation and `security find-identity -v` hides it.
  if [[ "${KEYCHAIN_CREATED}" != "1" ]]; then
    return
  fi

  local intermediates=(
    "https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
    "https://www.apple.com/certificateauthority/DeveloperIDCA.cer"
    "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer"
  )

  local url cert_path
  for url in "${intermediates[@]}"; do
    cert_path="${TEMP_DIR}/$(basename "${url}")"
    if curl -fsSL --retry 3 -o "${cert_path}" "${url}"; then
      security import "${cert_path}" -k "${TEMP_KEYCHAIN_PATH}" -T /usr/bin/codesign >/dev/null 2>&1 || true
    else
      echo "Warning: failed to download ${url}" >&2
    fi
  done
}

resolve_app_sign_identity() {
  if [[ -n "${APP_SIGN_IDENTITY}" ]]; then
    return
  fi

  # Pass the temp keychain explicitly in CI and skip `-v`. A fresh CI keychain
  # may lack Apple's Developer ID intermediate, which makes `-v` filter the
  # identity out even when codesign would happily use it.
  local find_identity_args=(-p codesigning)
  if [[ "${KEYCHAIN_CREATED}" == "1" ]]; then
    find_identity_args+=("${TEMP_KEYCHAIN_PATH}")
  fi

  APP_SIGN_IDENTITY="$(
    security find-identity "${find_identity_args[@]}" 2>/dev/null |
      sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' |
      head -n 1
  )"

  if [[ -z "${APP_SIGN_IDENTITY}" ]]; then
    echo "Could not find a Developer ID Application signing identity." >&2
    echo "Set APP_SIGN_IDENTITY or import a .p12 via APPLE_DEVELOPER_ID_P12_BASE64." >&2
    exit 1
  fi
}

resolve_release_metadata() {
  local info_plist="${EXPORT_DIR}/${APP_NAME}/Contents/Info.plist"

  if [[ -z "${DMG_VERSION}" ]]; then
    DMG_VERSION="$(
      /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${info_plist}" 2>/dev/null || true
    )"
  fi

  if [[ -z "${DMG_VERSION}" ]]; then
    echo "Could not determine CFBundleShortVersionString for ${APP_NAME}." >&2
    echo "Set DMG_VERSION explicitly if the bundle does not expose a marketing version." >&2
    exit 1
  fi

  if [[ -z "${DMG_NAME}" ]]; then
    # Hyphen, not space: a space-free asset name survives GitHub's upload rename
    # and keeps `shasum -c` working against the downloaded file.
    DMG_NAME="${DMG_BASENAME}-${DMG_VERSION}.dmg"
  fi
}

archive_app() {
  rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR}/${APP_NAME}" "${DMG_STAGING_DIR}" "${RELEASE_DIR}"
  mkdir -p "${EXPORT_DIR}" "${RELEASE_DIR}" "${DMG_STAGING_DIR}"

  # The .xcodeproj is not committed; regenerate it (also re-runs the
  # embed-build-info pre-build wiring). The workflow runs `make generate` first
  # so GITHUB_SHA is already in the env when embed-build-info bakes the commit;
  # running it here keeps a local invocation self-contained.
  make generate

  # Release-explicit archive. CODE_SIGNING_ALLOWED=NO: we sign the extracted
  # .app ourselves with the Developer ID identity below. SENTRY_DSN and
  # CURRENT_PROJECT_VERSION are baked into the release here (default-safe).
  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    SENTRY_DSN="${SENTRY_DSN}" \
    CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}" \
    archive \
    -archivePath "${ARCHIVE_PATH}"

  ditto \
    "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}" \
    "${EXPORT_DIR}/${APP_NAME}"

  resolve_release_metadata
}

sign_and_verify_app() {
  codesign --force --deep --options runtime --timestamp \
    --sign "${APP_SIGN_IDENTITY}" \
    "${EXPORT_DIR}/${APP_NAME}"

  # Hardened-runtime correctness gate: the Debug build carries
  # com.apple.security.get-task-allow (debugger attach), which notarization
  # rejects. Fail loud here rather than after a slow notary round-trip if a
  # misconfigured Release ever ships that entitlement.
  if codesign -d --entitlements - "${EXPORT_DIR}/${APP_NAME}" 2>&1 | grep -q "get-task-allow"; then
    echo "get-task-allow present — Release misconfigured (would fail notarization)" >&2
    exit 1
  fi

  codesign --verify --deep --strict --verbose=2 "${EXPORT_DIR}/${APP_NAME}"
  spctl -a -vvv "${EXPORT_DIR}/${APP_NAME}" || true
}

build_dmg() {
  rm -rf "${DMG_STAGING_DIR}"
  mkdir -p "${DMG_STAGING_DIR}"

  ditto "${EXPORT_DIR}/${APP_NAME}" "${DMG_STAGING_DIR}/${APP_NAME}"
  ln -s /Applications "${DMG_STAGING_DIR}/Applications"

  hdiutil create \
    -volname "${APP_NAME%.app}" \
    -srcfolder "${DMG_STAGING_DIR}" \
    -ov \
    -format UDZO \
    "${RELEASE_DIR}/${DMG_NAME}"
}

notarize_and_staple_dmg() {
  if [[ -n "${APPLE_NOTARY_API_KEY_BASE64:-}" ]]; then
    if [[ -z "${APPLE_NOTARY_API_KEY_ID:-}" || -z "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
      echo "APPLE_NOTARY_API_KEY_ID and APPLE_NOTARY_ISSUER_ID are required with APPLE_NOTARY_API_KEY_BASE64." >&2
      exit 1
    fi

    decode_base64_to_file "${APPLE_NOTARY_API_KEY_BASE64}" "${TEMP_NOTARY_KEY_PATH}"

    xcrun notarytool submit "${RELEASE_DIR}/${DMG_NAME}" \
      --key "${TEMP_NOTARY_KEY_PATH}" \
      --key-id "${APPLE_NOTARY_API_KEY_ID}" \
      --issuer "${APPLE_NOTARY_ISSUER_ID}" \
      --wait
  elif [[ -n "${NOTARY_KEYCHAIN_PROFILE}" ]]; then
    xcrun notarytool submit "${RELEASE_DIR}/${DMG_NAME}" \
      --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" \
      --wait
  else
    echo "Provide notarization credentials via NOTARY_KEYCHAIN_PROFILE or APPLE_NOTARY_API_KEY_* env vars." >&2
    exit 1
  fi

  xcrun stapler staple "${RELEASE_DIR}/${DMG_NAME}"
  xcrun stapler validate "${RELEASE_DIR}/${DMG_NAME}"
  spctl -a -vvv --type open "${RELEASE_DIR}/${DMG_NAME}" || true
}

print_summary() {
  cat <<EOF
Release artifacts:
  App: ${EXPORT_DIR}/${APP_NAME}
  DMG: ${RELEASE_DIR}/${DMG_NAME}

Signing identity:
  ${APP_SIGN_IDENTITY}

Notarization:
  completed
EOF
}

import_signing_certificate_if_needed
install_apple_intermediates_if_needed
resolve_app_sign_identity
archive_app
sign_and_verify_app
build_dmg
notarize_and_staple_dmg
print_summary
