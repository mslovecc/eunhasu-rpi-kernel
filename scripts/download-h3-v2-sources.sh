#!/usr/bin/env bash
set -Eeuo pipefail

: "$SRPM_NAME"
: "$SOURCE_TARBALL"
: "$SRPM_SHA256"
: "$SOURCE_SHA256"
: "$FALLBACK_BASE_URL"
: "$GITHUB_WORKSPACE"
: "$RELEASE_TAG"

WORKSPACE="$GITHUB_WORKSPACE"
DOWNLOAD_DIR="$WORKSPACE/.work/downloads"
RELEASE_BASE_URL="https://github.com/mslovecc/eunhasu-rpi-kernel/releases/download/$RELEASE_TAG"
mkdir -p "$DOWNLOAD_DIR"

download_verified() {
  local filename="$1"
  local expected="$2"
  local destination="$DOWNLOAD_DIR/$filename"
  local candidate="$DOWNLOAD_DIR/.$filename.candidate"
  local url

  rm -f "$destination" "$candidate"
  for url in "$RELEASE_BASE_URL/$filename" "$FALLBACK_BASE_URL/$filename"; do
    echo "Downloading $filename from $url"
    if ! curl -fL --connect-timeout 20 --max-time 1800 \
      --retry 3 --retry-all-errors "$url" -o "$candidate"; then
      echo "::warning::Download failed from $url; trying next source."
      rm -f "$candidate"
      continue
    fi
    if printf '%s  %s\n' "$expected" "$candidate" | sha256sum --check --status; then
      mv "$candidate" "$destination"
      echo "Verified $filename"
      return 0
    fi
    echo "::warning::SHA256 mismatch from $url; trying next source."
    rm -f "$candidate"
  done

  echo "::error::Could not obtain a SHA256-verified $filename from Release or fallback mirror."
  return 1
}

download_verified "$SRPM_NAME" "$SRPM_SHA256"
download_verified "$SOURCE_TARBALL" "$SOURCE_SHA256"

(
  cd "$DOWNLOAD_DIR"
  sha256sum "$SRPM_NAME" "$SOURCE_TARBALL"
)
