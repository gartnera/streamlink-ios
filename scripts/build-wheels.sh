#!/usr/bin/env bash
#
# Cross-compile the two C-extension wheels Streamlink needs, for iOS:
#   * pycryptodome  (self-contained C)
#   * lxml          (needs libxml2 + libxslt, which we cross-build statically)
#
# Produces, for BOTH the device (iphoneos) and simulator (iphonesimulator)
# arm64 slices, wheels in vendor/wheels/ plus a manifest.txt. These are then
# hosted (GitHub Release / S3) and consumed by scripts/bootstrap.sh, so app
# builders never need this toolchain.
#
# Run this OUTSIDE any command sandbox (autotools ./configure mutates PATH):
#   ./scripts/build-wheels.sh
#
# Requirements: macOS + Xcode, uv, curl. It uses the compiler wrappers and the
# cross-compilation harness shipped inside Python-Apple-support's XCFramework.
#
# Pinned versions (override via env):
PY_SERIES="${PY_SERIES:-3.14}"
PAS_TAG="${PAS_TAG:-3.14-b11}"
LXML_VERSION="${LXML_VERSION:-6.1.3}"
PYCRYPTODOME_VERSION="${PYCRYPTODOME_VERSION:-3.23.0}"
LIBXML2_VERSION="${LIBXML2_VERSION:-2.13.8}"
LIBXSLT_VERSION="${LIBXSLT_VERSION:-1.1.43}"

set -euo pipefail
ROOT="$(pwd)"
[ -f "$ROOT/project.yml" ] || { echo "run from the repository root" >&2; exit 1; }

WORK="$ROOT/.build-tmp/wheels"
OUT="$ROOT/vendor/wheels"
SRC="$WORK/src"
XCF="$ROOT/Python.xcframework"
UV="${UV:-uv}"

mkdir -p "$WORK" "$OUT" "$SRC"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Prerequisites: XCFramework + source tarballs
# ---------------------------------------------------------------------------
fetch_xcframework() {
  [ -d "$XCF/build" ] && return
  log "Fetching Python-Apple-support ${PAS_TAG}"
  local url="https://github.com/beeware/Python-Apple-support/releases/download/${PAS_TAG}/Python-${PY_SERIES}-iOS-support.${PAS_TAG#*-}.tar.gz"
  curl -sL "$url" -o "$WORK/pas.tar.gz"
  rm -rf "$WORK/pas" && mkdir -p "$WORK/pas"
  $UV run --python "$PY_SERIES" python - "$WORK/pas.tar.gz" "$WORK/pas" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1]) as t: t.extractall(sys.argv[2], filter="data")
PY
  rm -rf "$XCF" && cp -R "$WORK/pas/Python.xcframework" "$XCF"
}

fetch_sources() {
  local xml2_major="${LIBXML2_VERSION%.*}" xslt_major="${LIBXSLT_VERSION%.*}"
  local xml2="libxml2-${LIBXML2_VERSION}.tar.xz"
  local xslt="libxslt-${LIBXSLT_VERSION}.tar.xz"
  [ -f "$SRC/$xml2" ] || curl -sL "https://download.gnome.org/sources/libxml2/${xml2_major}/${xml2}" -o "$SRC/$xml2"
  [ -f "$SRC/$xslt" ] || curl -sL "https://download.gnome.org/sources/libxslt/${xslt_major}/${xslt}" -o "$SRC/$xslt"
  $UV run --python "$PY_SERIES" python - "$SRC/$xml2" "$SRC/$xslt" "$SRC" <<'PY'
import sys, tarfile
for f in sys.argv[1:3]:
    with tarfile.open(f) as t: t.extractall(sys.argv[3], filter="data")
PY
}

# ---------------------------------------------------------------------------
# Per-slice build
#   $1 = xcframework slice dir name
#   $2 = compiler wrapper prefix (e.g. arm64-apple-ios / arm64-apple-ios-simulator)
#   $3 = platform-config dir name (arm64-iphoneos / arm64-iphonesimulator)
#   $4 = wheel platform suffix (iphoneos / iphonesimulator)
#   $5 = xcrun sdk name (iphoneos / iphonesimulator)
# ---------------------------------------------------------------------------
build_slice() {
  local slice_name="$1" wrap="$2" pcfg_name="$3" wheel_slice="$4" sdk="$5"
  local slice="$XCF/$slice_name"
  local bin="$slice/bin"
  local pcfg="$slice/platform-config/$pcfg_name"
  local prefix="$WORK/deps/$wheel_slice"
  local venv="$WORK/venv/$wheel_slice"

  log "=== Building slice: $wheel_slice ==="
  export PATH="$bin:$prefix/bin:$PATH"
  export CC="$wrap-clang"
  export CXX="$wrap-clang++"
  export AR="$wrap-ar"
  export RANLIB; RANLIB="$(xcrun --sdk "$sdk" --find ranlib)"
  export CFLAGS="-O2 -fPIC"

  # --- libxml2 (static) ---
  mkdir -p "$prefix"
  if [ -f "$prefix/lib/libxml2.a" ] && [ -f "$prefix/lib/libxslt.a" ]; then
    log "libxml2/libxslt already built for $wheel_slice (skipping; rm -rf .build-tmp to force)"
  else
  rm -rf "$prefix"; mkdir -p "$prefix"
  log "libxml2 ${LIBXML2_VERSION}"
  ( cd "$SRC/libxml2-${LIBXML2_VERSION}"
    make distclean >/dev/null 2>&1 || true
    ./configure --host=aarch64-apple-darwin --build="$(uname -m)-apple-darwin" \
      --prefix="$prefix" --enable-static --disable-shared \
      --without-python --without-lzma --without-zlib --without-modules --without-debug \
      >"$WORK/libxml2-${wheel_slice}.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" >>"$WORK/libxml2-${wheel_slice}.log" 2>&1
    make install >>"$WORK/libxml2-${wheel_slice}.log" 2>&1 )

  # --- libxslt (static, against our libxml2) ---
  log "libxslt ${LIBXSLT_VERSION}"
  ( cd "$SRC/libxslt-${LIBXSLT_VERSION}"
    make distclean >/dev/null 2>&1 || true
    ./configure --host=aarch64-apple-darwin --build="$(uname -m)-apple-darwin" \
      --prefix="$prefix" --enable-static --disable-shared \
      --without-python --without-crypto --without-debug \
      --with-libxml-prefix="$prefix" \
      >"$WORK/libxslt-${wheel_slice}.log" 2>&1
    make -j"$(sysctl -n hw.ncpu)" >>"$WORK/libxslt-${wheel_slice}.log" 2>&1
    make install >>"$WORK/libxslt-${wheel_slice}.log" 2>&1 )
  fi

  # libxml2 links against the system iconv (present in the iOS SDK); make sure
  # the extension link picks it up (xml2-config doesn't emit -liconv).
  # distutils appends $LDFLAGS to the linker command.
  export LDFLAGS="-liconv"

  # --- cross venv (macOS python that reports as iOS) ---
  log "cross venv"
  rm -rf "$venv"
  $UV venv --python "$PY_SERIES" --seed "$venv" >/dev/null 2>&1
  "$venv/bin/python" -m pip -q install --upgrade "setuptools>=77" wheel Cython
  $UV run --python "$PY_SERIES" python "$pcfg/make_cross_venv.py" "$venv" "$pcfg"

  # --- pycryptodome wheel ---
  log "pycryptodome wheel"
  "$venv/bin/python" -m pip wheel --no-build-isolation --no-deps -w "$OUT" \
    "pycryptodome==${PYCRYPTODOME_VERSION}"

  # --- lxml wheel (links our static libxml2/libxslt) ---
  log "lxml wheel"
  "$venv/bin/python" -m pip wheel --no-build-isolation --no-deps -w "$OUT" \
    --config-settings="--global-option=--with-xml2-config=$prefix/bin/xml2-config" \
    --config-settings="--global-option=--with-xslt-config=$prefix/bin/xslt-config" \
    "lxml==${LXML_VERSION}"
}

write_manifest() {
  log "Writing manifest"
  ( cd "$OUT" && ls -1 *.whl | sort > manifest.txt )
  ( cd "$OUT" && shasum -a 256 *.whl > SHA256SUMS.txt )
  log "Wheels in $OUT:"; ( cd "$OUT" && ls -1 *.whl )
}

main() {
  fetch_xcframework
  fetch_sources
  build_slice "ios-arm64"                  "arm64-apple-ios"           "arm64-iphoneos"        "iphoneos"         "iphoneos"
  build_slice "ios-arm64_x86_64-simulator" "arm64-apple-ios-simulator" "arm64-iphonesimulator" "iphonesimulator"  "iphonesimulator"
  write_manifest
  log "Done. Host these wheels or keep them in vendor/wheels/ for 'make bootstrap'."
}

main "$@"
