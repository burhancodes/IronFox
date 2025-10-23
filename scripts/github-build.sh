#!/usr/bin/env bash

set -euo pipefail

VARIANT_ARG="${1:-${VARIANT:-arm64}}"
TARGET_KIND="${2:-apk}"

cd "$(dirname "$0")/.."

mkdir -p artifacts

# If ANDROID_NDK isn't provided by the environment, pick the latest installed
if [[ -z "${ANDROID_NDK:-}" && -n "${ANDROID_HOME:-}" ]]; then
  ANDROID_NDK=$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -n1 || true)
  export ANDROID_NDK
fi

# Keep overall memory use under runner limits. Favor GC over OOM killer.
# Apply to all JVM processes launched by Gradle (Kotlin, R8, D8, etc.).
# Conservative memory limits for GitHub Actions runners (7GB total, ~5GB usable)
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Xmx4g -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/app/artifacts/heapdump.hprof"

# Enable Gradle build cache with conservative resource limits for GitHub runners
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.caching=true -Dfile.encoding=UTF-8 -Dorg.gradle.jvmargs=-Xmx4g -Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false -Dorg.gradle.daemon=false"

# R8-specific memory optimizations for GitHub runner constraints
export ORG_GRADLE_PROJECT_android_r8_maxMemory=4g
export ORG_GRADLE_PROJECT_android_enableR8FullMode=false
export ORG_GRADLE_PROJECT_android_enableDexingArtifactTransform=false
export ORG_GRADLE_PROJECT_android_enableD8MainDexList=false

# Setup environment and sources
echo "=== Setting up build environment ==="
./scripts/get_sources.sh

source scripts/mocha-patch.sh
# Target release
if [[ -z "${IRONFOX_RELEASE+x}" ]]; then
  export IRONFOX_RELEASE=1
fi
source scripts/env_local.sh
source scripts/versions.sh

if [[ -z "${mozilla_release:-}" ]]; then
    echo "Error: mozilla_release variable not set. Environment setup may have failed."
    exit 1
fi

if [[ -z "${IRONFOX_VERSION:-}" ]]; then
    echo "Warning: IRONFOX_VERSION not set, using fallback"
    IRONFOX_VERSION="$(date +%Y%m%d-%H%M%S)"
fi

# Prebuild
echo "=== Running prebuild ==="
./scripts/prebuild.sh "$VARIANT_ARG"

# Build
echo "=== Building APK ==="
./scripts/build.sh "$TARGET_KIND"

# Post-build
if [[ "$TARGET_KIND" == "apk" ]]; then

    # Find the built APK
    APK_PATTERN="$mozilla_release/obj/gradle/build/mobile/android/fenix/app/outputs/apk/fenix/release/*.apk"
    APK_FILES=$(find "$mozilla_release/obj/gradle/build/mobile/android/fenix/app/outputs/" -name "*.apk" 2>/dev/null || true)

    if [[ -n "$APK_FILES" ]]; then
        for APK_IN in $APK_FILES; do
            # Extract architecture
            if [[ "$APK_IN" =~ arm64-v8a ]]; then
                BUILD_ABI="arm64-v8a"
            elif [[ "$APK_IN" =~ armeabi-v7a ]]; then
                BUILD_ABI="armeabi-v7a"
            elif [[ "$APK_IN" =~ x86_64 ]]; then
                BUILD_ABI="x86_64"
            else
                # Fallback
                case "$VARIANT_ARG" in
                    arm) BUILD_ABI="armeabi-v7a" ;;
                    arm64) BUILD_ABI="arm64-v8a" ;;
                    x86_64) BUILD_ABI="x86_64" ;;
                    *) BUILD_ABI="$VARIANT_ARG" ;;
                esac
            fi
            # Generate output filename
            VERSION="${IRONFOX_VERSION:-$(date +%Y%m%d-%H%M%S)}"
            APK_OUT="$APK_ARTIFACTS/IronFox-v${VERSION}-${BUILD_ABI}.apk"
            # Sign APK
            if [[ -n "${KEYSTORE:-}" && -f "${KEYSTORE}" ]]; then
                # Check if apksigner exists
                APKSIGNER="$ANDROID_HOME/build-tools/35.0.0/apksigner"
                if [[ ! -f "$APKSIGNER" ]]; then
                    echo "Warning: apksigner not found at $APKSIGNER, trying to find it..."
                    APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name "apksigner" | head -n1)
                    if [[ -z "$APKSIGNER" ]]; then
                        echo "Error: apksigner not found, cannot sign APK"
                        cp -v "$APK_IN" "$APK_OUT"
                        echo "Unsigned APK copied to: $APK_OUT"
                        continue
                    fi
                fi
                # Sign the APK
                "$APKSIGNER" sign \
                  --ks="$KEYSTORE" \
                  --ks-pass="pass:$KEYSTORE_PASS" \
                  --ks-key-alias="$KEYSTORE_KEY_ALIAS" \
                  --key-pass="pass:$KEYSTORE_KEY_PASS" \
                  --out="$APK_OUT" \
                  "$APK_IN"
                # Verify the APK was signed successfully
                if [[ -f "$APK_OUT" ]]; then
                    # Verify signature
                    "$APKSIGNER" verify "$APK_OUT" || echo "Warning: APK signature verification failed"
                else
                    echo "Error: Failed to create signed APK, falling back to unsigned"
                    cp -v "$APK_IN" "$APK_OUT"
                fi
            else
                cp -v "$APK_IN" "$APK_OUT"
            fi
        done
    else
        echo "Warning: No APK files found at $APK_PATTERN"

        find "$mozilla_release" -name "*.apk" -ls 2>/dev/null || true
    fi
fi
