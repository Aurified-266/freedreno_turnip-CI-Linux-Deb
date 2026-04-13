#!/bin/bash -e

# A bash script for Linux designed to build Magisk Mesa Turnip drivers on Debian-based systems.
# Based on work by ilhan-athn7 and K11MCH1.
# Optimized for Mesa 26.0.4 (Stable) with Android NDK r27c.

# Define variables
green='\033[0;32m'
red='\033[0;31m'
yellow='\033[1;33m'
nocolor='\033[0m'
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r27c"
ndk_base="$workdir/$ndkver"
sdkver="34"

# === STABLE RELEASE BUILD ===
# Uncomment the line for the version you want to build.
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/mesa-26.0.4/mesa-mesa-26.0.4.zip"
# mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip" # Dev branch

clear

run_all(){
    check_deps
    prepare_workdir
    build_lib_for_android
    port_lib_for_magisk
}

check_deps(){
    echo "Checking system for required Dependencies ..."
    deps_missing=0
    
    bin_deps="meson ninja patchelf unzip curl flex bison zip glslang glslangValidator python3"
    pkg_deps="python3-dev python3-pip ninja-build python3-yaml libarchive-dev libconfig-dev libncurses-dev libconfig-doc libconfig11 libxml2 libelf-dev cmake g++ libzstd-dev"
    
    for dep in $bin_deps; do
        if command -v "$dep" >/dev/null 2>&1; then
            echo -e "$green ✓ $dep found $nocolor"
        else
            echo -e "$red ✗ $dep not found $nocolor"
            deps_missing=1
        fi
    done

    for pkg in $pkg_deps; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            echo -e "$green ✓ $pkg installed $nocolor"
        else
            echo -e "$red ✗ $pkg not installed $nocolor"
            deps_missing=1
        fi
    done

    if [ "$deps_missing" -eq 1 ]; then
        echo -e "\n$red Missing dependencies detected! $nocolor"
        echo "Install them with:"
        echo "  sudo apt update && sudo apt install ${bin_deps// / } ${pkg_deps// / }"
        exit 1
    fi

    echo -e "\nInstalling Python dependencies for Mesa..."
    pip3 install pyyaml mako --break-system-packages 2>/dev/null || pip install pyyaml mako
    echo -e "$green All dependencies satisfied! $nocolor\n"
}

prepare_workdir(){
    echo "Preparing work directory ..."
    rm -rf "$workdir"
    mkdir -p "$workdir" && cd "$workdir"

    echo "Downloading Android NDK ($ndkver)..."
    ndk_url="https://dl.google.com/android/repository/${ndkver}-linux.zip"
    if ! curl -L "$ndk_url" --output "${ndkver}.zip" --fail; then
        echo -e "$red Failed to download NDK. Trying alternative version... $nocolor"
        ndkver="android-ndk-r26d"
        ndk_url="https://dl.google.com/android/repository/${ndkver}-linux.zip"
        curl -L "$ndk_url" --output "${ndkver}.zip" --fail || {
            echo -e "$red Could not download NDK. Please download manually. $nocolor"
            exit 1
        }
    fi
    
    echo "Extracting NDK..."
    unzip -q "${ndkver}.zip"
    
    echo "Downloading Mesa source..."
    curl -L "$mesasrc" --output mesa-source.zip --fail
    echo "Extracting Mesa source..."
    unzip -q mesa-source.zip
    
    # Auto-detect the extracted directory name
    MESASRC_DIR=$(ls -d mesa-* 2>/dev/null | head -1)
    if [ -z "$MESASRC_DIR" ]; then
        echo -e "$red Failed to find extracted Mesa source directory! $nocolor"
        ls -la
        exit 1
    fi
    
    echo "Found Mesa source directory: $MESASRC_DIR"
    cd "$MESASRC_DIR"
}

build_lib_for_android(){
    # Set up NDK paths dynamically
    NDK_TOOLCHAIN="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64"
    
    echo "Creating cross-compilation configuration files..."
    
    cat >"android-aarch64.txt" <<EOF
[binaries]
c = ['$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang']
cpp = ['$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
ar = '$NDK_TOOLCHAIN/bin/llvm-ar'
strip = '$NDK_TOOLCHAIN/bin/llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = 'pkg-config'
python = '/usr/bin/python3'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-DANDROID']
cpp_args = ['-DANDROID']
EOF

    cat >"native.txt" <<EOF
[build_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[binaries]
c = 'gcc'
cpp = 'g++'
ar = 'ar'
strip = 'strip'
python = '/usr/bin/python3'
EOF

    # Ensure 'python' command is available
    if ! command -v python >/dev/null 2>&1; then
        echo "Creating 'python' symlink to python3..."
        if sudo ln -sf $(which python3) /usr/local/bin/python 2>/dev/null; then
            echo "Created /usr/local/bin/python -> python3"
        else
            mkdir -p "$workdir/bin"
            ln -sf $(which python3) "$workdir/bin/python"
            export PATH="$workdir/bin:$PATH"
            echo "Created $workdir/bin/python -> python3"
        fi
    fi

    # Create zlib stubs to satisfy linker without real libz
    echo "Creating zlib stubs..."
    mkdir -p "$workdir/stub_libs"
    
    cat > "$workdir/stub_libs/zlib_stubs.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
typedef void* gzFile;
gzFile gzopen(const char *path, const char *mode) { return NULL; }
int gzclose(gzFile file) { return 0; }
int gzwrite(gzFile file, const void *buf, unsigned len) { return 0; }
const char* gzerror(gzFile file, int *errnum) { return NULL; }
int gzflush(gzFile file, int flush) { return 0; }
int gzread(gzFile file, void *buf, unsigned len) { return 0; }
EOF

    "$NDK_TOOLCHAIN/bin/aarch64-linux-android${sdkver}-clang" -c -o "$workdir/stub_libs/zlib_stubs.o" "$workdir/stub_libs/zlib_stubs.c"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to compile zlib stubs!"
        exit 1
    fi
    ar rcs "$workdir/stub_libs/libz_stub.a" "$workdir/stub_libs/zlib_stubs.o"
    echo "Zlib stubs created."

    # Patch perfcntrs to avoid "Unknown variable" error
    # We are already inside $MESASRC_DIR, so use relative path
    if [ -f "src/freedreno/perfcntrs/meson.build" ]; then
        sed -i '40s/^/# PATCHED: /' "src/freedreno/perfcntrs/meson.build"
    fi

    echo "Configuring Meson build (disabling shader cache & zlib)..."
    if ! meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --wipe \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version="$sdkver" \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=false \
        -Dstrip=true \
        -Degl=disabled \
        -Dzstd=disabled \
        -Dspirv-tools=disabled \
        -Dzlib=disabled \
        -Dshader-cache=disabled \
        -Dc_link_args="-L$workdir/stub_libs -lz_stub -ldl" \
        >"$workdir/meson_config.log" 2>&1; then
        
        echo -e "$red Meson configuration failed! $nocolor"
        tail -50 "$workdir/meson_config.log"
        exit 1
    fi

    echo "Patching build.ninja to remove host libraries and inject stubs..."
    if [ -f "build-android-aarch64/build.ninja" ]; then
        # Remove host libelf and libz paths
        sed -i 's| /usr/lib/x86_64-linux-gnu/libelf.so||g' build-android-aarch64/build.ninja
        sed -i 's| /usr/lib/x86_64-linux-gnu/libz.so||g' build-android-aarch64/build.ninja
        
        # Inject our stub library right before --end-group
        STUB_LIB_PATH="$workdir/stub_libs/libz_stub.a"
        sed -i "s| -Wl,--end-group| ${STUB_LIB_PATH} -Wl,--end-group|" build-android-aarch64/build.ninja
        
        if grep -q "${STUB_LIB_PATH}" build-android-aarch64/build.ninja; then
            echo "Successfully injected zlib stubs."
        else
            echo "WARNING: Stub injection might have failed. Check build.ninja."
        fi
    else
        echo "ERROR: build.ninja not found!"
        exit 1
    fi

    # Create dummy files for test tools to satisfy dependencies if they were built
    mkdir -p build-android-aarch64/src/freedreno/ir3/
    mkdir -p build-android-aarch64/src/freedreno/fdl/
    touch build-android-aarch64/src/freedreno/ir3/ir3_disasm
    touch build-android-aarch64/src/freedreno/ir3/ir3_delay_test
    touch build-android-aarch64/src/freedreno/fdl/fd5_layout
    touch build-android-aarch64/src/freedreno/fdl/fd6_layout

    echo "Building with Ninja..."
    if ! ninja -C build-android-aarch64 >"$workdir/ninja_build.log" 2>&1; then
        echo -e "$red Build failed! $nocolor"
        tail -50 "$workdir/ninja_build.log"
        exit 1
    fi

    if [ ! -f "build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so" ]; then
        echo -e "$red Output library not found! $nocolor"
        exit 1
    fi
    
    echo -e "$green Build completed successfully! $nocolor"
}

port_lib_for_magisk(){
    echo "Preparing Magisk module..."
    
    cp "build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so" "$workdir/vulkan.turnip.so"
    
    cd "$workdir"
    patchelf --set-soname vulkan.turnip.so vulkan.turnip.so
    
    magiskdir="$workdir/turnip_module"
    p1="system/vendor/lib64/hw"
    mkdir -p "$magiskdir/$p1"
    
    meta="META-INF/com/google/android"
    mkdir -p "$magiskdir/$meta"
    
    # FIXED: Hardcode version or detect from source directory
    cd "$workdir/mesa-mesa-26.0.4"  # Ensure we're in the Mesa source dir
    version=$(grep -oP '^\d+\.\d+\.\d+' VERSION 2>/dev/null || echo "26.0.4")
    version_code=$(echo "$version" | tr -cd '0-9')
    cd "$magiskdir"  # Return to Magisk dir
    
    cat >"$magiskdir/module.prop" <<EOF
id=turnip
name=Turnip Vulkan Driver
version=$version
versionCode=$version_code
author=Aurified.Dev
description=Turnip is an open-source Vulkan driver for Adreno GPUs based on Mesa $version. Debug and GPU Cache Disabled.
minApi=29
EOF

    cat >"$magiskdir/$meta/updater-script" <<EOF
#MAGISK
EOF

    cat >"$magiskdir/module.prop" <<EOF
id=turnip
name=Turnip Vulkan Driver
version=$version
versionCode=$version_code
author=Aurified.Dev
description=Turnip is an open-source Vulkan driver for Adreno GPUs based on Mesa. Debug and GPU Cache Disabled.
EOF

    cat >"$magiskdir/system.prop" <<EOF
debug.hwui.renderer=skiagl
ro.hardware.vulkan=turnip
EOF

    cat >"$magiskdir/customize.sh" <<EOF
#!/system/bin/sh
MODPATH=\$1
set_perm_recursive \$MODPATH/system 0 0 0755 0644
set_perm \$MODPATH/system/vendor/lib64/hw/vulkan.turnip.so 0 0 0644
EOF

    cp "$workdir/vulkan.turnip.so" "$magiskdir/$p1/"
    
    cd "$magiskdir"
    if ! zip -r "$workdir/turnip_module.zip" ./* >/dev/null 2>&1; then
        echo -e "$red Failed to create Magisk module ZIP! $nocolor"
        exit 1
    fi
    
    echo -e "$green Magisk module created: $workdir/turnip_module.zip $nocolor"
    echo "Install via Magisk Manager or recovery."
}

run_all
