#!/usr/bin/env bash

## This script is adapted from ci-build.sh for GitHub Actions runners
## It mimics the GitLab CI workflow as closely as possible

set -eu
set -o pipefail
set -o xtrace

cd "$(dirname "$0")/.."

# Load version information first
source "$(realpath $(dirname "$0"))/versions.sh"

# Determine build variant and type from arguments
VARIANT_ARG="${1:-${VARIANT:-arm64}}"
TARGET_KIND="${2:-apk}"

case "${VARIANT_ARG}" in
arm)
    BUILD_TYPE='apk'
    BUILD_ABI='armeabi-v7a'
    ;;
x86_64)
    BUILD_TYPE='apk'
    BUILD_ABI='x86_64'
    ;;
arm64)
    BUILD_TYPE='apk'
    BUILD_ABI='arm64-v8a'
    ;;
bundle)
    BUILD_TYPE='bundle'
    ;;
*)
    echo "Unknown build variant: '${VARIANT_ARG}'." >&2
    exit 1
    ;;
esac

# Override if TARGET_KIND is explicitly set to bundle
if [[ "$TARGET_KIND" == "bundle" ]]; then
    BUILD_TYPE='bundle'
fi

mkdir -p artifacts

ensure_gecko_source_metadata() {
    local repo_path="${mozilla_release:-}" sed_bin="${SED:-sed}"

    if [[ -z "$repo_path" || ! -d "$repo_path/.git" ]]; then
        return
    fi

    local repo_url commit
    repo_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
    commit=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)

    if [[ -n "$repo_url" ]]; then
        export MOZ_SOURCE_REPO="$repo_url"
    fi

    if [[ -n "$commit" ]]; then
        export MOZ_SOURCE_CHANGESET="$commit"
    fi

    local mozconfig="$repo_path/mozconfig"
    if [[ -f "$mozconfig" ]]; then
        if [[ -n "$repo_url" ]]; then
            "$sed_bin" -i "s|^export MOZ_SOURCE_REPO=.*|export MOZ_SOURCE_REPO='$repo_url'|" "$mozconfig"
        fi
        if [[ -n "$commit" ]]; then
            "$sed_bin" -i "s|^export MOZ_SOURCE_CHANGESET=.*|export MOZ_SOURCE_CHANGESET='$commit'|" "$mozconfig"
        fi
    fi
}

# Setup environment variables similar to env_docker.sh
export ANDROID_SDK_ROOT="${ANDROID_HOME:-/root/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"

# If ANDROID_NDK isn't provided by the environment, pick the latest installed
if [[ -z "${ANDROID_NDK:-}" && -n "${ANDROID_HOME:-}" ]]; then
  ANDROID_NDK=$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | sort -V | tail -n1 || true)
  export ANDROID_NDK
fi

# Keep overall memory use under runner limits. Favor GC over OOM killer.
# Apply to all JVM processes launched by Gradle (Kotlin, R8, D8, etc.).
# Conservative memory limits for GitHub Actions runners (7GB total, ~5GB usable)
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Xmx4g -XX:MaxMetaspaceSize=1g -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:G1HeapRegionSize=16m"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$PWD/artifacts/heapdump.hprof"

# Enable Gradle build cache with conservative resource limits for GitHub runners
export GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.caching=true -Dfile.encoding=UTF-8 -Dorg.gradle.jvmargs=-Xmx4g -Dorg.gradle.workers.max=1 -Dorg.gradle.parallel=false -Dorg.gradle.daemon=false"

# R8-specific memory optimizations for GitHub runner constraints
export ORG_GRADLE_PROJECT_android_r8_maxMemory=4g
export ORG_GRADLE_PROJECT_android_enableR8FullMode=false
export ORG_GRADLE_PROJECT_android_enableDexingArtifactTransform=false
export ORG_GRADLE_PROJECT_android_enableD8MainDexList=false

# Check if building release
if [[ -n "${IRONFOX_RELEASE:-}" ]] && [[ "${IRONFOX_RELEASE}" == "1" ]]; then
    echo "Preparing to build IronFox (Release)..."
else
    export IRONFOX_RELEASE=1
    echo "Preparing to build IronFox (Release)..."
fi

if [[ -f "scripts/setup-android-sdk.sh" ]]; then
    source "scripts/setup-android-sdk.sh"
fi

bash -x ./scripts/get_sources.sh
source "scripts/env_local.sh"
ensure_gecko_source_metadata

# Apply mocha patch
if [[ -f "scripts/mocha-patch.sh" ]]; then
    source scripts/mocha-patch.sh
fi

if [[ -z "${mozilla_release:-}" ]]; then
    echo "Error: mozilla_release variable not set. Environment setup may have failed."
    exit 1
fi

if [[ -z "${IRONFOX_VERSION:-}" ]]; then
    echo "Warning: IRONFOX_VERSION not set, using fallback"
    export IRONFOX_VERSION="${FIREFOX_VERSION:-$(date +%Y%m%d-%H%M%S)}"
fi

bash -x ./scripts/prebuild.sh "$VARIANT_ARG"
ensure_gecko_source_metadata

if [[ "$BUILD_TYPE" == "bundle" ]]; then
    export MOZ_ANDROID_FAT_AAR_ARM64_V8A="$AAR_ARTIFACTS/geckoview-arm64-v8a.zip"
    export MOZ_ANDROID_FAT_AAR_ARMEABI_V7A="$AAR_ARTIFACTS/geckoview-armeabi-v7a.zip"
    export MOZ_ANDROID_FAT_AAR_X86_64="$AAR_ARTIFACTS/geckoview-x86_64.zip"
    export MOZ_ANDROID_FAT_AAR_ARCHITECTURES="armeabi-v7a,arm64-v8a,x86_64"
fi

export MOZ_BUILD_DATE="${MOZ_BUILD_DATE:-$(date "+%Y%m%d%H%M%S")}"
export IF_BUILD_DATE="${IF_BUILD_DATE:-$(date -Iseconds)}"

# Build
bash -x scripts/build.sh "$BUILD_TYPE"

# Post-build processing
if [[ "$BUILD_TYPE" == "apk" ]]; then
    echo "=== Processing APK artifacts ==="
    
    pushd "$mozilla_release/obj/gradle"
    mkdir -vp geckoview-aar
    mv maven geckoview-aar/geckoview
    popd
    pushd "$mozilla_release/obj/gradle/geckoview-aar"
    zip -r -FS "$AAR_ARTIFACTS/geckoview-$BUILD_ABI.zip" *
    popd
    
    # Sign APK
    APK_IN="$mozilla_release/obj/gradle/build/mobile/android/fenix/app/outputs/apk/fenix/release/app-fenix-$BUILD_ABI-release-unsigned.apk"
    APK_OUT="$APK_ARTIFACTS/IronFox-v${IRONFOX_VERSION}-${BUILD_ABI}.apk"
    
    if [[ ! -f "$APK_IN" ]]; then
        echo "Warning: Expected APK not found at $APK_IN, searching for alternatives..."
        APK_IN=$(find "$mozilla_release/obj/gradle/build/mobile/android/fenix/app/outputs/apk" -name "*.apk" | head -n1)
        if [[ -z "$APK_IN" ]]; then
            echo "Error: No APK file found!"
            find "$mozilla_release/obj/gradle/build" -name "*.apk" -ls 2>/dev/null || true
            exit 1
        fi
        echo "Found APK at: $APK_IN"
    fi
    
    # Sign APK if keystore is available
    if [[ -n "${KEYSTORE:-}" && -f "${KEYSTORE}" ]]; then
        echo "Signing APK with keystore..."
        if [[ -n "${BUILDTOOLS_VERSION:-}" ]]; then
            APKSIGNER="$ANDROID_HOME/build-tools/$BUILDTOOLS_VERSION/apksigner"
        else
            APKSIGNER=$(find "$ANDROID_HOME/build-tools" -name "apksigner" 2>/dev/null | sort -V | tail -n1)
        fi
        
        if [[ -z "$APKSIGNER" || ! -f "$APKSIGNER" ]]; then
            echo "Error: apksigner not found, cannot sign APK"
            cp -v "$APK_IN" "$APK_OUT"
        else
            "$APKSIGNER" sign \
              --ks="$KEYSTORE" \
              --ks-pass="pass:$KEYSTORE_PASS" \
              --ks-key-alias="$KEYSTORE_KEY_ALIAS" \
              --key-pass="pass:$KEYSTORE_KEY_PASS" \
              --out="$APK_OUT" \
              "$APK_IN"
            echo "APK signed successfully: $APK_OUT"
        fi
    else
        echo "No keystore provided, copying unsigned APK..."
        cp -v "$APK_IN" "$APK_OUT"
    fi
fi

if [[ "$BUILD_TYPE" == "bundle" ]]; then
    echo "=== Processing Bundle artifacts ==="
    # Build signed APK set
    AAB_IN=$(ls "$mozilla_release"/obj/gradle/build/mobile/android/fenix/app/outputs/bundle/fenixRelease/*.aab)
    APKS_OUT="$APKS_ARTIFACTS/IronFox-v${IRONFOX_VERSION}.apks"
    
    if [[ -f "$bundletool" ]] && [[ -n "${KEYSTORE:-}" ]]; then
        "$bundletool" build-apks \
            --bundle="$AAB_IN" \
            --output="$APKS_OUT" \
            --ks="$KEYSTORE" \
            --ks-pass="pass:$KEYSTORE_PASS" \
            --ks-key-alias="$KEYSTORE_KEY_ALIAS" \
            --key-pass="pass:$KEYSTORE_KEY_PASS"
    else
        echo "Warning: Cannot create signed APK set - bundletool or keystore not available"
        echo "AAB file location: $AAB_IN"
    fi
fi

echo "Artifacts directory: $ARTIFACTS"
