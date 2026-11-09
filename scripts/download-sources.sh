#!/usr/bin/env bash
set -Eeuo pipefail

: "${SRPM_NAME:?SRPM_NAME is required}"
: "${SOURCE_TARBALL:?SOURCE_TARBALL is required}"
: "${SRPM_SHA256:?SRPM_SHA256 is required}"
: "${SOURCE_SHA256:?SOURCE_SHA256 is required}"
: "${FALLBACK_BASE_URL:?FALLBACK_BASE_URL is required}"

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$WORKSPACE/.work/downloads}"
REPO_SOURCE_DIR="${REPO_SOURCE_DIR:-$WORKSPACE/sources/dist}"
REPOSITORY_RAW_BASE="${REPOSITORY_RAW_BASE:-}"

mkdir -p "$DOWNLOAD_DIR"

download_verified() {
  local name="$1"
  local expected="$2"
  local destination="$DOWNLOAD_DIR/$name"
  local candidate="$DOWNLOAD_DIR/.$name.candidate"
  local local_file="$REPO_SOURCE_DIR/$name"

  rm -f "$destination" "$candidate"

  verify_candidate() {
    local source_label="$1"
    if [[ ! -s "$candidate" ]]; then
      echo "WARN: $source_label returned an empty file: $name" >&2
      return 1
    fi
    if ! printf '%s  %s\n' "$expected" "$candidate" | sha256sum --check --status; then
      echo "WARN: SHA256 mismatch from $source_label for $name" >&2
      return 1
    fi
    mv "$candidate" "$destination"
    echo "Verified $name from $source_label"
    return 0
  }

  # 1. Prefer a file checked into this repository (for example, a future
  #    Git-LFS or release-managed source mirror).
  if [[ -s "$local_file" ]]; then
    cp "$local_file" "$candidate"
    if verify_candidate "repository checkout"; then
      return 0
    fi
  fi

  # 2. Try the raw file at the checked-out repository ref.
  if [[ -n "$REPOSITORY_RAW_BASE" ]]; then
    if curl -fL --connect-timeout 20 --max-time 900 \
      --retry 2 --retry-all-errors \
      "$REPOSITORY_RAW_BASE/sources/dist/$name" -o "$candidate"; then
      if verify_candidate "GitHub repository raw URL"; then
        return 0
      fi
    else
      echo "WARN: repository raw URL unavailable for $name" >&2
    fi
  fi

  # 3. Fall back to the established external mirror.
  if curl -fL --connect-timeout 20 --max-time 1800 \
    --retry 5 --retry-all-errors \
    "$FALLBACK_BASE_URL/$name" -o "$candidate"; then
    if verify_candidate "fallback mirror"; then
      return 0
    fi
  fi

  rm -f "$candidate"
  echo "::error::Unable to obtain a SHA256-verified copy of $name from repository or fallback mirror."
  return 1
}

download_verified "$SRPM_NAME" "$SRPM_SHA256"
download_verified "$SOURCE_TARBALL" "$SOURCE_SHA256"

echo "===== Downloaded source checksums ====="
(
  cd "$DOWNLOAD_DIR"
  sha256sum "$SRPM_NAME" "$SOURCE_TARBALL"
)
