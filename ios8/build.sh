#!/usr/bin/env bash
#
# Builds Moonlight for iOS 8 (armv7 + arm64) on Linux and packages it as an
# unsigned .ipa.
#
# Modern Xcode can no longer target iOS 8 or produce 32-bit ARM code, so this
# build uses:
#   - clang from a regular LLVM install (it still has the ARM/AArch64 Mach-O backends)
#   - the iOS 14.5 SDK (the last SDK whose .tbd stubs still contain armv7)
#   - Apple's ld64 built from cctools-port (lld can't link armv7 Mach-O)
#
# Usage:
#   ios8/build.sh [step...]
#
# Steps (default: all):
#   sdk        download the iOS 14.5 SDK
#   toolchain  build ld64 (cctools-port + apple-libtapi) and ldid
#   deps       build Opus and OpenSSL for each architecture
#   app        compile and link the Moonlight executable
#   ipa        assemble Moonlight.app and Moonlight-iOS8.ipa
#   all        everything above
#
# Environment overrides:
#   BUILD_DIR   work directory          (default: ios8/build)
#   IOS_SDK     path to an iPhoneOS SDK (default: $BUILD_DIR/sdks/iPhoneOS14.5.sdk)
#   LD64        path to an ld64 binary  (default: $BUILD_DIR/toolchain/bin/arm-apple-darwin11-ld)
#   LDID        path to ldid            (default: $BUILD_DIR/toolchain/bin/ldid)
#   ARCHS       architectures           (default: "armv7 arm64")
#   BUNDLE_ID   bundle identifier       (default: com.moonlight-stream.Moonlight)
#   CC          C compiler              (default: clang)
#   JOBS        parallel jobs           (default: nproc)
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS8="$ROOT/ios8"
BUILD_DIR="${BUILD_DIR:-$IOS8/build}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"

IOS_SDK="${IOS_SDK:-$BUILD_DIR/sdks/iPhoneOS14.5.sdk}"
LD64="${LD64:-$BUILD_DIR/toolchain/bin/arm-apple-darwin11-ld}"
LDID="${LDID:-$BUILD_DIR/toolchain/bin/ldid}"
ARCHS="${ARCHS:-armv7 arm64}"
# Different from the App Store app, so it can be installed next to Moonlight 2.x
BUNDLE_ID="${BUNDLE_ID:-com.moonlight-stream.Moonlight.ios8}"
CC="${CC:-clang}"
JOBS="${JOBS:-$(nproc)}"
MIN_IOS=8.0

# Pinned dependency versions
. "$IOS8/versions.sh"

# Find LLVM tools (llvm-ar, llvm-lipo, ...) even when they only exist with a version suffix
find_tool() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"
        return
    fi
    local candidate
    for candidate in $(compgen -c "$name-" | grep -E "^$name-[0-9]+$" | sort -t- -k3 -n -r); do
        command -v "$candidate"
        return
    done
    for candidate in /usr/lib/llvm-*/bin/"$name"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo "error: $name not found (install LLVM)" >&2
    exit 1
}

log() {
    echo "==> $*"
}

# Shallow-clone a repository at a given commit or tag
fetch_git() {
    local repo="$1" rev="$2" dest="$3"
    if [ -d "$dest/.git" ]; then
        return
    fi
    log "Fetching $repo ($rev)"
    git init -q "$dest"
    git -C "$dest" remote add origin "$repo"
    git -C "$dest" fetch -q --depth 1 origin "$rev"
    git -C "$dest" checkout -q FETCH_HEAD
}

triple() {
    echo "$1-apple-ios$MIN_IOS"
}

# ---------------------------------------------------------------------------
# sdk
# ---------------------------------------------------------------------------
step_sdk() {
    if [ -d "$IOS_SDK/System" ]; then
        log "Using SDK at $IOS_SDK"
        return
    fi
    local dest="$BUILD_DIR/sdks"
    log "Fetching iPhoneOS14.5.sdk from theos/sdks"
    if [ ! -d "$dest/.git" ]; then
        git init -q "$dest"
        git -C "$dest" remote add origin "$THEOS_SDKS_REPO"
        git -C "$dest" config core.sparseCheckout true
        # The full iOS 14.5 SDK to build against, plus the iOS 9.3 SDK's .tbd
        # stubs to check that the app doesn't import symbols newer than iOS 9.
        printf '%s\n' "/iPhoneOS14.5.sdk/" "/iPhoneOS9.3.sdk/**/*.tbd" > "$dest/.git/info/sparse-checkout"
    fi
    git -C "$dest" fetch -q --depth 1 --filter=blob:none origin "$THEOS_SDKS_COMMIT"
    git -C "$dest" checkout -q FETCH_HEAD
    IOS_SDK="$dest/iPhoneOS14.5.sdk"
}

# ---------------------------------------------------------------------------
# toolchain: ld64 from cctools-port
# ---------------------------------------------------------------------------
build_ldid() {
    if [ -x "$LDID" ]; then
        log "Using ldid at $LDID"
        return
    fi
    local src="$BUILD_DIR/src/ldid"
    fetch_git "$LDID_REPO" "$LDID_COMMIT" "$src"
    log "Building ldid"
    make -C "$src" -j"$JOBS" VERSION="procursus-${LDID_COMMIT:0:7}"
    mkdir -p "$(dirname "$LDID")"
    cp "$src/ldid" "$LDID"
}

step_toolchain() {
    # ldid adds the (ad-hoc) code signature that iOS requires even with AppSync
    build_ldid
    if [ -x "$LD64" ]; then
        log "Using ld64 at $LD64"
        return
    fi
    local src="$BUILD_DIR/src" prefix="$BUILD_DIR/toolchain"
    mkdir -p "$src"
    fetch_git "$LIBDISPATCH_REPO" "$LIBDISPATCH_COMMIT" "$src/apple-libdispatch"
    fetch_git "$LIBTAPI_REPO" "$LIBTAPI_COMMIT" "$src/apple-libtapi"
    fetch_git "$CCTOOLS_REPO" "$CCTOOLS_COMMIT" "$src/cctools-port"

    log "Building libdispatch"
    cmake -S "$src/apple-libdispatch" -B "$src/apple-libdispatch/build" \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
    cmake --build "$src/apple-libdispatch/build" -j "$JOBS"
    cmake --install "$src/apple-libdispatch/build"

    log "Building libtapi"
    (cd "$src/apple-libtapi" && CC=clang CXX=clang++ INSTALLPREFIX="$prefix" JOBS="$JOBS" ./build.sh && ./install.sh)

    log "Building cctools (ld64)"
    (cd "$src/cctools-port/cctools" &&
        ./configure --prefix="$prefix" --target=arm-apple-darwin11 \
                    --with-libtapi="$prefix" --with-libdispatch="$prefix" --with-libblocksruntime="$prefix" \
                    CC=clang CXX=clang++ &&
        make -j"$JOBS" &&
        make install)
}

# ---------------------------------------------------------------------------
# deps: Opus and OpenSSL
# ---------------------------------------------------------------------------
compile_opus() {
    local arch="$1" src="$2" obj="$3" opus="$BUILD_DIR/src/opus"
    "$CC" -target "$(triple "$arch")" -isysroot "$IOS_SDK" -Os -DNDEBUG \
        -DOPUS_BUILD -DUSE_ALLOCA -DHAVE_LRINT -DHAVE_LRINTF \
        -I"$opus/include" -I"$opus/celt" -I"$opus/silk" -I"$opus/silk/float" -I"$opus" \
        -c "$src" -o "$obj"
}
export -f compile_opus

build_opus() {
    local arch="$1" src="$BUILD_DIR/src/opus" out="$BUILD_DIR/deps/$arch/opus"
    if [ -f "$out/lib/libopus.a" ]; then
        return
    fi
    log "Building Opus ($arch)"
    local obj="$BUILD_DIR/obj/$arch/opus"
    mkdir -p "$obj" "$out/lib" "$out/include"
    local sources
    sources=$(make -s -f "$IOS8/tools/opus-sources.mk" OPUS_DIR="$src" print)
    local objs=() f
    for f in $sources; do
        objs+=("$obj/$(echo "$f" | tr '/' '_').o")
    done
    for f in $sources; do
        printf '%s\0%s\0%s\0' "$arch" "$src/$f" "$obj/$(echo "$f" | tr '/' '_').o"
    done | xargs -0 -n 3 -P "$JOBS" bash -c 'compile_opus "$@"' _
    rm -f "$out/lib/libopus.a"
    "$AR" rcs "$out/lib/libopus.a" "${objs[@]}"
    cp "$src"/include/*.h "$out/include/"
}

build_openssl() {
    local arch="$1" out="$BUILD_DIR/deps/$arch/openssl"
    if [ -f "$out/lib/libcrypto.a" ]; then
        return
    fi
    log "Building OpenSSL ($arch)"
    # OpenSSL builds in-tree, so use a separate copy per architecture
    local src="$BUILD_DIR/obj/$arch/openssl-src"
    rm -rf "$src"
    mkdir -p "$(dirname "$src")"
    cp -a "$BUILD_DIR/src/openssl" "$src"

    local target asm
    case "$arch" in
        arm64) target=ios64-cross; asm="" ;;          # ARMv8 crypto extensions
        armv7) target=ios-cross;   asm="no-asm" ;;    # no AES acceleration anyway
    esac

    # The ios*-cross targets look for the SDK in $CROSS_TOP/SDKs/$CROSS_SDK
    local cross_top="$BUILD_DIR/obj/$arch/cross"
    mkdir -p "$cross_top/SDKs"
    ln -sfn "$IOS_SDK" "$cross_top/SDKs/$(basename "$IOS_SDK")"

    (cd "$src" &&
        CROSS_TOP="$cross_top" CROSS_SDK="$(basename "$IOS_SDK")" \
        ./Configure "$target" $asm \
            no-shared no-dso no-engine no-async no-tests no-apps no-docs no-ui-console \
            no-quic no-comp no-ssl3 no-weak-ssl-ciphers \
            --prefix="$out" --libdir=lib \
            CC="$CC -target $(triple "$arch")" AR="$AR" RANLIB="$RANLIB" \
            CFLAGS="-Os -mios-version-min=$MIN_IOS -Wunguarded-availability" &&
        CROSS_TOP="$cross_top" CROSS_SDK="$(basename "$IOS_SDK")" make -j"$JOBS" build_libs > build.log 2>&1 ||
            { tail -50 build.log; exit 1; }
        # Anything newer than iOS 8 that OpenSSL calls would crash the app at launch
        if grep -E "is only available on iOS (9|[1-9][0-9])" build.log; then
            echo "error: OpenSSL uses APIs newer than iOS $MIN_IOS" >&2
            exit 1
        fi
        CROSS_TOP="$cross_top" CROSS_SDK="$(basename "$IOS_SDK")" make install_dev > /dev/null)
}

step_deps() {
    mkdir -p "$BUILD_DIR/src"
    fetch_git "$OPUS_REPO" "$OPUS_TAG" "$BUILD_DIR/src/opus"
    fetch_git "$OPENSSL_REPO" "$OPENSSL_TAG" "$BUILD_DIR/src/openssl"
    export IOS_SDK BUILD_DIR CC MIN_IOS
    local arch
    for arch in $ARCHS; do
        build_opus "$arch"
        build_openssl "$arch"
    done
}

# ---------------------------------------------------------------------------
# app
# ---------------------------------------------------------------------------
COMMON_C="$ROOT/moonlight-common/moonlight-common-c"

app_sources() {
    find "$ROOT/Limelight" -name '*.m' -o -name '*.c' | sort
    ls "$COMMON_C"/src/*.c
    for f in callbacks compress host list packet peer protocol unix; do
        echo "$COMMON_C/enet/$f.c"
    done
    echo "$COMMON_C/nanors/rs.c"
    echo "$COMMON_C/nanors/deps/obl/oblas_lite.c"
    echo "$COMMON_C/nanors/deps/obl/oblas_common.c"
    echo "$IOS8/compat/compiler-rt-shims.c"
}

compile_one() {
    local arch="$1" src="$2" obj="$3"
    local deps="$BUILD_DIR/deps/$arch"
    local flags=(-target "$(triple "$arch")" -isysroot "$IOS_SDK" -Os -g -DNDEBUG
                 -fno-common -fstack-protector-strong
                 -Wall -Wno-unused-function -Wno-deprecated-declarations
                 -Werror=unguarded-availability -Werror=unguarded-availability-new
                 -Werror=implicit-function-declaration -Werror=objc-method-access
                 -I"$deps/opus/include" -I"$deps/openssl/include")
    case "$src" in
        "$COMMON_C"/*)
            flags+=(-std=gnu11 -D__APPLE_USE_RFC_3542 -DHAS_SOCKLEN_T=1
                    -include "$IOS8/compat/moonlight-common-ios8.h"
                    -I"$COMMON_C/src" -I"$COMMON_C/enet/include"
                    -I"$COMMON_C/nanors" -I"$COMMON_C/nanors/deps/obl")
            ;;
        *.m)
            flags+=(-fobjc-arc -include "$ROOT/Limelight/Limelight-Prefix.pch" $APP_INCLUDES)
            ;;
        *.c)
            flags+=($APP_INCLUDES)
            ;;
    esac
    "$CC" "${flags[@]}" -c "$src" -o "$obj"
}
export -f compile_one triple

step_app() {
    APP_INCLUDES="-I$COMMON_C/src"
    local d
    for d in $(find "$ROOT/Limelight" \( -name '*.xcassets' -o -name '*.xcdatamodeld' -o -name '*.lproj' \) -prune -o -type d -print); do
        APP_INCLUDES="$APP_INCLUDES -I$d"
    done
    export APP_INCLUDES IOS_SDK BUILD_DIR CC MIN_IOS COMMON_C ROOT IOS8

    local arch slices=()
    for arch in $ARCHS; do
        log "Compiling Moonlight ($arch)"
        local obj="$BUILD_DIR/obj/$arch/app"
        mkdir -p "$obj"
        local objs=() f
        while read -r f; do
            objs+=("$obj/$(echo "${f#$ROOT/}" | tr '/ ' '__').o")
        done < <(app_sources)
        while read -r f; do
            printf '%s\0%s\0%s\0' "$arch" "$f" "$obj/$(echo "${f#$ROOT/}" | tr '/ ' '__').o"
        done < <(app_sources) | xargs -0 -n 3 -P "$JOBS" bash -c 'compile_one "$@"' _

        log "Linking Moonlight ($arch)"
        local deps="$BUILD_DIR/deps/$arch"
        local ldflag="--ld-path=$LD64"
        case "$(basename "$LD64")" in
            # ld64.lld can't link armv7, but works for quick arm64-only test builds
            *lld*) ldflag="-fuse-ld=lld" ;;
        esac
        "$CC" -target "$(triple "$arch")" -isysroot "$IOS_SDK" "$ldflag" \
            -Wl,-dead_strip \
            "${objs[@]}" \
            "$deps/opus/lib/libopus.a" "$deps/openssl/lib/libssl.a" "$deps/openssl/lib/libcrypto.a" \
            -lxml2 -lz \
            -framework UIKit -framework Foundation -framework CoreFoundation -framework CoreGraphics \
            -framework QuartzCore -framework CoreData -framework CoreMedia -framework CoreVideo \
            -framework VideoToolbox -framework AVFoundation -framework AudioToolbox \
            -framework GameController -framework CoreMotion -framework Security \
            -framework SystemConfiguration -framework CFNetwork -framework ImageIO \
            -o "$BUILD_DIR/obj/$arch/Moonlight"
        slices+=("$BUILD_DIR/obj/$arch/Moonlight")

        # Make sure dyld on iOS 8 will be able to bind every non-weak import
        python3 -I "$IOS8/tools/check_symbols.py" "$NM" "$BUILD_DIR/sdks/iPhoneOS9.3.sdk" \
            "$BUILD_DIR/obj/$arch/Moonlight"
    done

    log "Creating universal binary"
    "$LIPO" -create "${slices[@]}" -output "$BUILD_DIR/Moonlight"
}

# ---------------------------------------------------------------------------
# ipa
# ---------------------------------------------------------------------------
step_ipa() {
    local app="$BUILD_DIR/Payload/Moonlight.app"
    rm -rf "$BUILD_DIR/Payload"
    mkdir -p "$app"

    log "Assembling Moonlight.app"
    cp "$BUILD_DIR/Moonlight" "$app/Moonlight"
    "$STRIP" -S "$app/Moonlight" 2>/dev/null || true

    # iOS refuses to install an executable without a code signature, even on a
    # jailbroken device with AppSync. Add an ad-hoc one (like `ldid -S`);
    # sideloading tools replace it with a real signature anyway.
    if [ ! -x "$LDID" ]; then
        echo "error: ldid not found at $LDID (run: ios8/build.sh toolchain)" >&2
        exit 1
    fi
    log "Signing (ad-hoc)"
    "$LDID" -S "$app/Moonlight"
    local slices
    slices=$("$LIPO" -archs "$app/Moonlight" | wc -w)
    if [ "$("$OTOOL" -l "$app/Moonlight" | grep -c LC_CODE_SIGNATURE)" -ne "$slices" ]; then
        echo "error: not every architecture of Moonlight is signed" >&2
        exit 1
    fi

    local version build
    version=$(grep -m1 'MARKETING_VERSION = ' "$ROOT/Moonlight.xcodeproj/project.pbxproj" | sed 's/.*= \(.*\);/\1/')
    build=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)
    sed -e "s/@BUNDLE_ID@/$BUNDLE_ID/" -e "s/@VERSION@/$version/" -e "s/@BUILD_NUMBER@/$build/" \
        "$IOS8/Info.plist" > "$app/Info.plist"
    printf 'APPL????' > "$app/PkgInfo"

    python3 -I "$IOS8/tools/flatten_assets.py" "$ROOT/Limelight/Images.xcassets" "$app"
    cp "$IOS8"/Resources/*.png "$app/"
    cp -R "$ROOT/Limelight/en.lproj" "$app/"

    log "Creating Moonlight-iOS8.ipa"
    rm -f "$BUILD_DIR/Moonlight-iOS8.ipa"
    (cd "$BUILD_DIR" && zip -qr -X Moonlight-iOS8.ipa Payload)
    log "Done: $BUILD_DIR/Moonlight-iOS8.ipa"
}

# ---------------------------------------------------------------------------

AR="$(find_tool llvm-ar)"
RANLIB="$(find_tool llvm-ranlib)"
LIPO="$(find_tool llvm-lipo)"
NM="$(find_tool llvm-nm)"
STRIP="$(find_tool llvm-strip)"
OTOOL="$(find_tool llvm-otool)"
export AR RANLIB

steps=("$@")
if [ ${#steps[@]} -eq 0 ] || [ "${steps[0]}" = all ]; then
    steps=(sdk toolchain deps app ipa)
fi

for step in "${steps[@]}"; do
    case "$step" in
        sdk|toolchain|deps|app|ipa) ;;
        *) echo "unknown step: $step" >&2; exit 1 ;;
    esac
done

# Steps that need the SDK must know where it is
case " ${steps[*]} " in
    *" sdk "*) ;;
    *) [ -d "$IOS_SDK/System" ] || step_sdk ;;
esac

for step in "${steps[@]}"; do
    "step_$step"
done
