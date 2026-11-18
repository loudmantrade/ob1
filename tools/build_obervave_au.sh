#!/usr/bin/env bash
# Native OberVave AUv2. NO_INSTALL=1 builds/tests without installing.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
build="${BUILD_DIR:-$root/target/obervave-au}"
sdk="${AUDIOUNIT_SDK:-}"
cmake -S native/OberVaveAU -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="${ARCH:-$(uname -m)}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DAUDIOUNIT_SDK="$sdk"
cmake --build "$build"
codesign --force --sign "${SIGN_IDENTITY:--}" "$build/OberVave.component"
ctest --test-dir "$build" --output-on-failure
if [ -n "${NO_INSTALL:-}" ]; then exit 0; fi
destination="$HOME/Library/Audio/Plug-Ins/Components/OberVave.component"
mkdir -p "$(dirname "$destination")"
ditto "$build/OberVave.component" "$destination"
touch "$destination"
auval -v aumu Obv1 Obvv
