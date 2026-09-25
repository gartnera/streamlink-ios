#!/usr/bin/env bash
#
# Assemble the on-device Python runtime for the Streamlink iOS app:
#   1. Download the Python-Apple-support XCFramework -> ./Python.xcframework
#   2. Build ./app_packages  (pure-Python: streamlink + its pure deps)
#   3. Populate ./native/<slice>  (compiled lxml + pycryptodome, per platform)
#
# Everything here is reproducible and needs no iOS toolchain (the compiled
# wheels are produced separately by scripts/build-wheels.sh and hosted).
#
# Env overrides:
#   PY_SERIES     Python minor series           (default: 3.14)
#   PAS_TAG       Python-Apple-support release   (default: 3.14-b11)
#   WHEELS_URL    base URL for prebuilt iOS wheels (default: GitHub Release)
set -euo pipefail

# Run from the repository root (the Makefile and docs invoke it that way).
ROOT="$(pwd)"
if [ ! -f "$ROOT/project.yml" ]; then
  echo "error: run this from the repository root (project.yml not found)" >&2
  exit 1
fi

PY_SERIES="${PY_SERIES:-3.14}"
PAS_TAG="${PAS_TAG:-3.14-b11}"
PAS_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PAS_TAG}/Python-${PY_SERIES}-iOS-support.${PAS_TAG#*-}.tar.gz"
WHEELS_URL="${WHEELS_URL:-https://github.com/gartnera/streamlink-ios/releases/download/wheels-${PY_SERIES}}"

UV="${UV:-uv}"
PY="${UV} run --python ${PY_SERIES} python"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

extract_targz() {  # $1=tarball $2=dest  (tar -x is often sandbox-blocked; use Python)
  local tarball="$1" dest="$2"
  mkdir -p "$dest"
  $PY - "$tarball" "$dest" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    t.extractall(sys.argv[2], filter="data")
PY
}

extract_zip() {  # $1=zip/whl $2=dest  (unzip extraction is often sandbox-blocked)
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  $PY - "$zip" "$dest" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
}

# ---------------------------------------------------------------------------
# 1. Python XCFramework
# ---------------------------------------------------------------------------
fetch_xcframework() {
  if [ -d "Python.xcframework" ] && [ -f "Python.xcframework/build/utils.sh" ]; then
    log "Python.xcframework already present; skipping download"
    return
  fi
  log "Downloading Python-Apple-support ${PAS_TAG}"
  mkdir -p .build-tmp
  curl -sL "$PAS_URL" -o .build-tmp/pas.tar.gz
  log "Extracting XCFramework"
  rm -rf .build-tmp/pas && extract_targz .build-tmp/pas.tar.gz .build-tmp/pas
  rm -rf Python.xcframework
  cp -R .build-tmp/pas/Python.xcframework Python.xcframework
  log "Python.xcframework ready"
}

# ---------------------------------------------------------------------------
# 2. Pure-Python packages (streamlink + deps, minus the compiled ones)
# ---------------------------------------------------------------------------
build_app_packages() {
  log "Installing streamlink into app_packages (pure-Python subset)"
  rm -rf app_packages && mkdir -p app_packages
  $UV pip install --python "$PY_SERIES" --target app_packages streamlink

  log "Stripping compiled/host-only artifacts (provided per-platform via native/)"
  # The compiled deps come from our iOS wheels; drop the host copies.
  rm -rf app_packages/lxml app_packages/lxml-*.dist-info \
         app_packages/Crypto app_packages/pycryptodome-*.dist-info
  # Remove any stray macOS binaries; pure-Python fallbacks remain.
  find app_packages -name '*.so' -type f -exec rm -f {} + || true
  find app_packages -name '__pycache__' -type d -prune -exec rm -rf {} + || true
  log "app_packages assembled ($(du -sh app_packages | cut -f1))"
}

# ---------------------------------------------------------------------------
# 3. Compiled iOS wheels (lxml, pycryptodome) -> native/<slice>
# ---------------------------------------------------------------------------
populate_native() {
  local slice src
  for slice in iphoneos iphonesimulator; do
    rm -rf "native/$slice" && mkdir -p "native/$slice"
  done

  for pkg in lxml pycryptodome; do
    for slice in iphoneos iphonesimulator; do
      local whl
      whl="$(ls vendor/wheels/${pkg}-*_${slice}.whl 2>/dev/null | head -1 || true)"
      if [ -z "$whl" ]; then
        log "Fetching ${pkg} ${slice} wheel from ${WHEELS_URL}"
        mkdir -p vendor/wheels
        # Wheel filenames are pinned by scripts/build-wheels.sh manifest.
        if ! _download_wheel "$pkg" "$slice"; then
          log "warning: no ${pkg} wheel for ${slice}; run 'make wheels' first"
          continue
        fi
        whl="$(ls vendor/wheels/${pkg}-*_${slice}.whl 2>/dev/null | head -1 || true)"
      fi
      [ -n "$whl" ] || continue
      log "Unpacking $(basename "$whl") -> native/$slice"
      extract_zip "$whl" "native/$slice"
      # Drop wheel metadata; only the importable package is needed at runtime.
      rm -rf "native/$slice"/*.dist-info
    done
  done
}

_download_wheel() {  # $1=pkg $2=slice ; reads vendor/wheels/manifest.txt if present
  local pkg="$1" slice="$2" name
  if [ -f vendor/wheels/manifest.txt ]; then
    name="$(grep -E "^${pkg}-.*_${slice}\.whl$" vendor/wheels/manifest.txt | head -1 || true)"
    [ -n "$name" ] || return 1
    curl -fsSL "${WHEELS_URL}/${name}" -o "vendor/wheels/${name}"
    return 0
  fi
  return 1
}

main() {
  fetch_xcframework
  build_app_packages
  populate_native
  log "Bootstrap complete."
}

main "$@"
