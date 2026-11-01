#!/bin/bash
# Prints a directory holding an empty `libdispatch.a`, for the Apple TV build's link step.
#
# The `dispatch` crate (0.2.0, a dependency of objc2-foundation's `dispatch` feature) asks the linker for
# `-ldispatch` on every platform except macOS and iOS, which it special-cases to libSystem. On Apple platforms
# libdispatch is part of libSystem, so every symbol the crate declares resolves from the library the linker
# always links; but tvOS isn't in the crate's list, so rustc passes `-ldispatch` and the SDK has no such file:
#   ld: library 'dispatch' not found
# An empty archive of that name satisfies the flag and changes nothing else. iOS never needs this.
#
# Usage: dir=$(bash tools/ci/tvos-link-stub.sh [directory])
#   export CARGO_TARGET_AARCH64_APPLE_TVOS_RUSTFLAGS="-L native=$dir"
set -euo pipefail
dir="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/horizon-tvos-link}"
mkdir -p "$dir"
if [ ! -f "$dir/libdispatch.a" ]; then
  printf 'void horizon_tvos_libdispatch_stub(void) {}\n' > "$dir/stub.c"
  xcrun --sdk appletvos clang -arch arm64 -target arm64-apple-tvos17.0 -c "$dir/stub.c" -o "$dir/stub.o" >&2
  xcrun ar rcs "$dir/libdispatch.a" "$dir/stub.o" >&2
fi
echo "$dir"
