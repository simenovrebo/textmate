#!/bin/sh
# Build the Cap’n Proto submodule as universal (arm64 + x86_64) static libraries plus the capnp compiler.
#
# Usage: build.sh <install prefix> <minimum macOS version>
#
# Called by ./configure. Nothing is rebuilt if the submodule, this script, and the arguments are unchanged.
set -e

prefix=$1
min_os=$2
src=$(cd "$(dirname "$0")" && pwd)/vendor

[ -n "$prefix" ] && [ -n "$min_os" ] || { echo >&2 "usage: $0 <install prefix> <minimum macOS version>"; exit 2; }
[ -f "$src/c++/CMakeLists.txt" ] || { echo >&2 "*** Cap’n Proto source missing, run: git submodule update --init vendor/capnp/vendor"; exit 1; }
command -v cmake >/dev/null || { echo >&2 "*** dependency missing: ‘cmake’."; exit 1; }

stamp="$(git -C "$src" rev-parse HEAD) $(shasum < "$0" | cut -d' ' -f1) ${min_os}"
if [ -f "$prefix/.stamp" ] && [ "$(cat "$prefix/.stamp")" = "$stamp" ]; then
	exit 0
fi

echo >&2 "Building Cap’n Proto $(git -C "$src" describe --tags 2>/dev/null)…"
rm -rf "$prefix" "$prefix.build"
cmake -S "$src" -B "$prefix.build" -G Ninja \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$min_os" \
	-DCMAKE_INSTALL_PREFIX="$prefix" \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DBUILD_SHARED_LIBS=OFF \
	-DBUILD_TESTING=OFF \
	-DWITH_OPENSSL=OFF \
	-DWITH_ZLIB=OFF >/dev/null
ninja -C "$prefix.build" install >/dev/null
rm -rf "$prefix.build"

echo "$stamp" > "$prefix/.stamp"
