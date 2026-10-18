#!/usr/bin/env bash
# Install azguard from the latest cdobratz/AzGuard GitHub release.
# Usage:
#   curl -sSL https://azguard.dev/install.sh | bash
#   curl -sSL https://azguard.dev/install.sh | bash -s -- --prefix ~/.local/bin

set -euo pipefail

REPO="cdobratz/AzGuard"
DEFAULT_PREFIX="/usr/local/bin"
FALLBACK_PREFIX="${HOME:-}/.local/bin"
WORK=""

cleanup() {
  if [ -n "$WORK" ]; then
    rm -rf "$WORK"
    WORK=""
  fi
}
trap cleanup EXIT

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

classify_os() {
  case "$1" in
    Linux) printf 'linux\n' ;;
    Darwin) printf 'darwin\n' ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf 'windows\n' ;;
    *) return 1 ;;
  esac
}

classify_arch() {
  case "$1" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) return 1 ;;
  esac
}

detect_os() {
  local raw name
  raw="$(uname -s)"
  name="$(classify_os "$raw")" || die "Unsupported operating system: ${raw}. This installer supports linux and darwin (amd64 and arm64)."
  if [ "$name" = "windows" ]; then
    die "This installer does not support Windows. Install with Scoop: scoop bucket add azguard https://github.com/cdobratz/scoop-azguard && scoop install azguard"
  fi
  printf '%s\n' "$name"
}

detect_arch() {
  local raw name
  raw="$(uname -m)"
  name="$(classify_arch "$raw")" || die "Unsupported architecture: ${raw}. This installer supports amd64 and arm64."
  printf '%s\n' "$name"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print tolower($1)}'
  else
    die "sha256sum or shasum is required to verify the download"
  fi
}

# verify_checksum FILE ASSET_NAME CHECKSUMS_FILE
# Prints nothing and returns 0 on match. Returns 1 on mismatch or a missing entry.
verify_checksum() {
  local file="$1"
  local name="$2"
  local sums="$3"
  local expected actual

  expected="$(awk -v name="$name" '
    {
      file = $2
      sub(/^\*/, "", file)
      if (file == name) {
        print tolower($1)
        exit
      }
    }
  ' "$sums")"

  if [ -z "$expected" ]; then
    printf 'error: checksums.txt has no entry for %s\n' "$name" >&2
    return 1
  fi

  actual="$(sha256_file "$file")"
  if [ "$actual" != "$expected" ]; then
    printf 'error: checksum mismatch for %s\nexpected %s\ngot      %s\n' "$name" "$expected" "$actual" >&2
    return 1
  fi
  log "Checksum verified (${actual})"
}

latest_tag() {
  local url tag
  url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")" \
    || die "Could not look up the latest ${REPO} release"
  tag="${url##*/}"
  case "$tag" in
    v[0-9]*) printf '%s\n' "$tag" ;;
    *) die "Unexpected latest-release URL: ${url}" ;;
  esac
}

choose_prefix() {
  if [ -n "${PREFIX}" ]; then
    printf '%s\n' "$PREFIX"
    return
  fi
  if [ -d "$DEFAULT_PREFIX" ] && [ -w "$DEFAULT_PREFIX" ]; then
    printf '%s\n' "$DEFAULT_PREFIX"
    return
  fi
  if [ -z "${HOME:-}" ]; then
    die "HOME is not set and ${DEFAULT_PREFIX} is not writable. Pass --prefix."
  fi
  printf '%s\n' "$FALLBACK_PREFIX"
}

install_release() {
  local os="$1"
  local arch="$2"
  local dest="$3"
  local tag version ext asset url archive sums

  tag="$(latest_tag)"
  version="${tag#v}"
  case "$os" in
    linux) ext="tar.gz" ;;
    darwin) ext="zip" ;;
    *) die "Unsupported operating system: ${os}" ;;
  esac
  asset="azguard_${version}_${os}_${arch}.${ext}"
  url="https://github.com/${REPO}/releases/download/${tag}/${asset}"

  need curl
  WORK="$(mktemp -d)"

  log "Downloading ${asset} from ${tag}..."
  archive="${WORK}/${asset}"
  sums="${WORK}/checksums.txt"
  curl -fsSL -o "$archive" "$url" || die "Download failed: ${url}"
  curl -fsSL -o "$sums" "https://github.com/${REPO}/releases/download/${tag}/checksums.txt" \
    || die "Download failed: checksums.txt for ${tag}"

  verify_checksum "$archive" "$asset" "$sums" || exit 1

  log "Extracting..."
  case "$ext" in
    tar.gz) tar -xzf "$archive" -C "$WORK" ;;
    zip)
      need unzip
      unzip -q -o "$archive" -d "$WORK"
      ;;
  esac

  [ -f "${WORK}/azguard" ] || die "Archive did not contain an azguard binary"

  mkdir -p "$dest" || die "Could not create ${dest}. Pass --prefix with a writable directory."
  [ -w "$dest" ] || die "${dest} is not writable. Pass --prefix ${FALLBACK_PREFIX:-~/.local/bin}."

  install -m 0755 "${WORK}/azguard" "${dest}/azguard"
  log "Installed ${dest}/azguard"

  case ":${PATH}:" in
    *":${dest}:"*) ;;
    *) log "Add ${dest} to PATH to run azguard by name." ;;
  esac

  "${dest}/azguard" version
}

usage() {
  cat <<'EOF'
Usage: install.sh [--prefix DIR]

Download the latest AzGuard release for this machine (linux or darwin,
amd64 or arm64), verify it against checksums.txt, and install the binary.

  --prefix DIR   Install directory. Default: /usr/local/bin when that
                 directory is writable, otherwise ~/.local/bin.

Windows is not supported. Use Scoop:
  scoop bucket add azguard https://github.com/cdobratz/scoop-azguard
  scoop install azguard
EOF
}

self_test() {
  local file name good bad
  WORK="$(mktemp -d)"
  file="${WORK}/azguard_1.0.5_linux_amd64.tar.gz"
  name="azguard_1.0.5_linux_amd64.tar.gz"
  printf 'azguard-checksum-fixture' >"$file"
  good="${WORK}/good.txt"
  bad="${WORK}/bad.txt"
  printf '%s  %s\n' "$(sha256_file "$file")" "$name" >"$good"
  verify_checksum "$file" "$name" "$good"

  printf '0000000000000000000000000000000000000000000000000000000000000000  %s\n' "$name" >"$bad"
  if verify_checksum "$file" "$name" "$bad" 2>/dev/null; then
    die "checksum mismatch was accepted"
  fi

  if verify_checksum "$file" "missing-asset.tar.gz" "$good" 2>/dev/null; then
    die "missing checksum entry was accepted"
  fi

  classify_os Linux >/dev/null
  classify_os Darwin >/dev/null
  [ "$(classify_os MINGW64_NT-10.0)" = "windows" ]
  if classify_os FreeBSD >/dev/null; then
    die "FreeBSD was accepted"
  fi
  [ "$(classify_arch x86_64)" = "amd64" ]
  [ "$(classify_arch aarch64)" = "arm64" ]
  [ "$(classify_arch arm64)" = "arm64" ]
  if classify_arch i686 >/dev/null; then
    die "i686 was accepted"
  fi

  log "self-test ok"
}

main() {
  PREFIX=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix)
        [ $# -ge 2 ] || die "--prefix requires a directory"
        PREFIX="$2"
        shift 2
        ;;
      --prefix=*)
        PREFIX="${1#--prefix=}"
        [ -n "$PREFIX" ] || die "--prefix requires a directory"
        shift
        ;;
      --self-test)
        self_test
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  local os arch dest
  os="$(detect_os)"
  arch="$(detect_arch)"
  dest="$(choose_prefix)"
  log "Detected ${os}/${arch}"
  log "Install directory: ${dest}"
  install_release "$os" "$arch" "$dest"
}

main "$@"
