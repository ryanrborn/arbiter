#!/usr/bin/env bash
# Build the Erlang/OTP that the published release bundles as its ERTS, with
# OpenSSL linked in *statically*.
#
# Why this exists (bd-c6h5dr / #1977): the release is built inside
# `redhat/ubi8` so it runs on glibc 2.28 (RHEL 8) and everything newer. Until
# v0.1.69 the job installed OTP from the rabbitmq `erlang` el8 RPM, whose
# `crypto` NIF is dynamically linked against the build image's OpenSSL 1.1
# (`libcrypto.so.1.1`). Hosts that only carry OpenSSL 3 — Fedora >= 36,
# Ubuntu >= 22.04, Debian >= 12, RHEL 9 — cannot load that NIF, so `kernel`
# died in `on_load` before any Arbiter code ran.
#
# Building OTP here with `--disable-dynamic-ssl-lib` against a static,
# upstream OpenSSL 3 (an LTS line) gives a `crypto` NIF with no host libcrypto
# dependency at all, which is the usual way portable Erlang releases are made.
# The glibc baseline is unchanged: everything is still compiled against ubi8's
# glibc 2.28. The same RPM also linked `beam.smp` against `libz.so.1` and
# `epmd` against `libsystemd.so.0`; this build uses OTP's bundled zlib and
# leaves systemd support off, so neither dependency ships any more.
#
# `scripts/check-release-shared-libs.sh` is what enforces the outcome on the
# packaged tarball; this script runs the same check against the OTP it
# installs, so a regression fails here, closest to its cause.
set -euo pipefail

# Keep OTP_VERSION in step with the OTP line used in CI (.github/workflows/ci.yml).
OTP_VERSION="28.5.0.2"
OTP_SHA256="70d000de601c1cf695b551bab5209226555363ad3cb810639810a3fc6c5306eb"

# 3.5 is an OpenSSL LTS line (supported to 2030-04). Bump within it for
# security fixes; the checksum is the upstream `.sha256` for the tarball.
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"

usage() {
  cat <<'USAGE'
Usage: scripts/build-release-otp.sh [--prefix DIR] [--src-cache DIR]

  --prefix DIR     Where to install OTP (default: /opt/otp). OpenSSL is
                   installed alongside it under DIR/openssl, for linking only;
                   nothing in the resulting OTP loads it at runtime.
  --src-cache DIR  Directory to look in for (and save) the downloaded
                   otp_src_*.tar.gz / openssl-*.tar.gz. Checksums are verified
                   either way.
  --print-versions Print "OTP_VERSION=... OPENSSL_VERSION=..." and exit — used
                   as the CI cache key.

Needs a C/C++ toolchain, make, perl (with IPC::Cmd), ncurses-devel and curl.
On success `DIR/bin/erl` is a working OTP whose crypto NIF needs no
libcrypto from the host.
USAGE
}

PREFIX="/opt/otp"
SRC_CACHE=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --print-versions)
      echo "OTP_VERSION=${OTP_VERSION} OPENSSL_VERSION=${OPENSSL_VERSION}"
      exit 0
      ;;
    --prefix)
      PREFIX="${2:?--prefix needs a directory}"
      shift 2
      ;;
    --src-cache)
      SRC_CACHE="${2:?--src-cache needs a directory}"
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
SSL_PREFIX="$PREFIX/openssl"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/build-release-otp.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

# fetch <url> <sha256> -> path of a verified tarball
fetch() {
  local url="$1" sha="$2" name
  name=$(basename "$url")
  local dest="${SRC_CACHE:-$WORK_DIR}/$name"

  if [ -n "$SRC_CACHE" ]; then mkdir -p "$SRC_CACHE"; fi
  if [ ! -f "$dest" ]; then
    echo "Downloading $url" >&2
    curl -fsSL --retry 3 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi

  if ! echo "$sha  $dest" | sha256sum -c --quiet - >&2; then
    echo "error: checksum mismatch for $name (expected $sha)" >&2
    exit 1
  fi
  printf '%s\n' "$dest"
}

ssl_tarball=$(fetch \
  "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
  "$OPENSSL_SHA256")
otp_tarball=$(fetch \
  "https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz" \
  "$OTP_SHA256")

echo "==> OpenSSL ${OPENSSL_VERSION} (static) -> ${SSL_PREFIX}"
tar -xzf "$ssl_tarball" -C "$WORK_DIR"
(
  cd "$WORK_DIR/openssl-${OPENSSL_VERSION}"
  # no-shared: only libcrypto.a/libssl.a, so nothing can link it dynamically.
  # -fPIC:     the archive gets linked into the crypto NIF, a shared object.
  # no-module: build the legacy provider into libcrypto instead of as a
  #            loadable .so that would not exist on the target host.
  # --libdir=lib: OpenSSL 3 defaults to lib64 on x86_64, which OTP's
  #            configure does not look in.
  # --openssldir: deliberately NOT the distro's /etc/pki/tls or /usr/lib/ssl.
  #            This upstream libcrypto would otherwise read the host's
  #            (distro-patched) openssl.cnf at init; a missing default config
  #            file is ignored, so point it somewhere hosts don't populate.
  #            Erlang's ssl verifies peers via public_key:cacerts_get/0, not
  #            through this directory.
  ./Configure linux-x86_64 \
    --prefix="$SSL_PREFIX" \
    --libdir=lib \
    --openssldir=/usr/local/ssl \
    no-shared no-module no-tests no-docs \
    -fPIC
  make -j"$JOBS"
  make install_sw
)

echo "==> Erlang/OTP ${OTP_VERSION} -> ${PREFIX}"
tar -xzf "$otp_tarball" -C "$WORK_DIR"
(
  cd "$WORK_DIR/otp_src_${OTP_VERSION}"
  # --disable-dynamic-ssl-lib: link libcrypto.a into the crypto NIF.
  # --enable-builtin-zlib:     don't make beam.smp NEED the host's libz.so.1.
  ./configure \
    --prefix="$PREFIX" \
    --with-ssl="$SSL_PREFIX" \
    --disable-dynamic-ssl-lib \
    --enable-builtin-zlib \
    --without-javac \
    --without-wx \
    --without-odbc
  make -j"$JOBS"
  make install
)

echo "==> Verifying ${PREFIX}"
"$PREFIX/bin/erl" -noshell -eval '
  ok = crypto:start(),
  [{_, _, Lib}] = crypto:info_lib(),
  io:format("crypto OK, linked against ~s~n", [Lib]),
  halt().'

# The same NEEDED-allowlist check the release tarball goes through.
bash "$SCRIPT_DIR/check-release-shared-libs.sh" "$PREFIX/lib/erlang"
