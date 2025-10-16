#!/usr/bin/env bash

## This script is adapted from ci-build.sh for GitHub Actions runners
## It mimics the GitLab CI workflow as closely as possible

set -eu
set -o pipefail
set -o xtrace

echo_red_text() {
	echo -e "\033[31m$1\033[0m"
}

echo_green_text() {
	echo -e "\033[32m$1\033[0m"
}

cd "$(dirname "$0")/.."

BUILD_VARIANT="${1:-${VARIANT:-arm64}}"
TARGET_KIND="${2:-apk}"

case "${BUILD_VARIANT}" in
arm)
    BUILD_TYPE='apk'
    ;;
x86_64)
    BUILD_TYPE='apk'
    ;;
arm64)
    BUILD_TYPE='apk'
    ;;
bundle)
    BUILD_TYPE='bundle'
    ;;
*)
    echo_red_text "Unknown build variant: '${BUILD_VARIANT}'." >&2
    exit 1
    ;;
esac

if [[ "$TARGET_KIND" == "bundle" ]]; then
    BUILD_TYPE='bundle'
fi

if [[ -n "${IRONFOX_RELEASE:-}" ]] && [[ "${IRONFOX_RELEASE}" == "1" ]]; then
    echo_green_text "Preparing to build IronFox (Release)..."
else
    export IRONFOX_RELEASE=1
    echo_green_text "Preparing to build IronFox (Release)..."
fi

bash -x $(dirname $0)/env.sh
source $(dirname $0)/env.sh

export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Xmx4g -XX:MaxMetaspaceSize=1g"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${ARTIFACTS}/heapdump.hprof"
export ORG_GRADLE_PROJECT_android_r8_maxMemory=4g
export ORG_GRADLE_PROJECT_android_enableR8FullMode=false
export ORG_GRADLE_PROJECT_android_enableDexingArtifactTransform=false
export ORG_GRADLE_PROJECT_android_enableD8MainDexList=false

mkdir -vp "${APK_ARTIFACTS}"
mkdir -vp "${APKS_ARTIFACTS}"
mkdir -vp "${AAR_ARTIFACTS}"

bash -x "${IRONFOX_SCRIPTS}/get_sources.sh"

if [[ -f "${IRONFOX_SCRIPTS}/mocha-patch.sh" ]]; then
    source "${IRONFOX_SCRIPTS}/mocha-patch.sh"
fi

ensure_gecko_source_metadata() {
    local repo_path="${IRONFOX_GECKO:-}"

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
            "${IRONFOX_SED}" -i "s|^export MOZ_SOURCE_REPO=.*|export MOZ_SOURCE_REPO='$repo_url'|" "$mozconfig"
        fi
        if [[ -n "$commit" ]]; then
            "${IRONFOX_SED}" -i "s|^export MOZ_SOURCE_CHANGESET=.*|export MOZ_SOURCE_CHANGESET='$commit'|" "$mozconfig"
        fi
    fi
}

ensure_gecko_source_metadata

bash -x "${IRONFOX_SCRIPTS}/prebuild.sh" "${BUILD_VARIANT}"

ensure_gecko_source_metadata

if [[ "${BUILD_TYPE}" == 'bundle' ]]; then
    export MOZ_ANDROID_FAT_AAR_ARCHITECTURES='arm64-v8a,armeabi-v7a,x86_64'
    export MOZ_ANDROID_FAT_AAR_ARM64_V8A="${IRONFOX_GECKOVIEW_AAR_ARM64_ARTIFACT}"
    export MOZ_ANDROID_FAT_AAR_ARMEABI_V7A="${IRONFOX_GECKOVIEW_AAR_ARM_ARTIFACT}"
    export MOZ_ANDROID_FAT_AAR_X86_64="${IRONFOX_GECKOVIEW_AAR_X86_64_ARTIFACT}"
fi

export MOZ_BUILD_DATE="${MOZ_BUILD_DATE:-$(date "+%Y%m%d%H%M%S")}"
export IF_BUILD_DATE="${IF_BUILD_DATE:-$(date -Iseconds)}"

bash -x "${IRONFOX_SCRIPTS}/build.sh" "${BUILD_TYPE}"

source "${IRONFOX_VERSIONS}"

source "${IRONFOX_ENV_TARGET}"

if [[ "${BUILD_TYPE}" == "apk" ]]; then
    echo_green_text "=== Processing APK artifacts ==="

    pushd "${IRONFOX_GECKO}"

    MOZ_AUTOMATION=1 ./mach android archive-geckoview

    if [[ "${BUILD_VARIANT}" == 'arm' ]]; then
        cp -vf "${IRONFOX_GECKOVIEW_AAR_ARM}" "${IRONFOX_GECKOVIEW_AAR_ARM_ARTIFACT}"
    elif [[ "${BUILD_VARIANT}" == 'arm64' ]]; then
        cp -vf "${IRONFOX_GECKOVIEW_AAR_ARM64}" "${IRONFOX_GECKOVIEW_AAR_ARM64_ARTIFACT}"
    elif [[ "${BUILD_VARIANT}" == 'x86_64' ]]; then
        cp -vf "${IRONFOX_GECKOVIEW_AAR_X86_64}" "${IRONFOX_GECKOVIEW_AAR_X86_64_ARTIFACT}"
    fi

    popd

    APK_IN="${IRONFOX_OUTPUTS}/ironfox-${IRONFOX_CHANNEL}-${BUILD_VARIANT}-unsigned.apk"
    APK_OUT="${APK_ARTIFACTS}/IronFox-v${IRONFOX_VERSION}-${IRONFOX_TARGET_ABI}.apk"

    if [[ ! -f "$APK_IN" ]]; then
        echo_red_text "Warning: Expected APK not found at $APK_IN, searching for alternatives..."
        APK_IN=$(find "${IRONFOX_GECKO}/obj" -name "*.apk" -path "*/fenix/*" -name "*unsigned*" 2>/dev/null | head -n1)
        if [[ -z "$APK_IN" ]]; then
            echo_red_text "Error: No APK file found!"
            find "${IRONFOX_GECKO}/obj" -name "*.apk" -ls 2>/dev/null || true
            exit 1
        fi
        echo_green_text "Found APK at: $APK_IN"
    fi

    if [[ -n "${KEYSTORE:-}" && -f "${KEYSTORE}" ]]; then
        echo_green_text "Signing APK with keystore..."
        "${IRONFOX_ANDROID_SDK}/build-tools/${ANDROID_BUILDTOOLS_VERSION}/apksigner" sign \
          --ks="${KEYSTORE}" \
          --ks-pass="pass:${KEYSTORE_PASS}" \
          --ks-key-alias="${KEYSTORE_KEY_ALIAS}" \
          --key-pass="pass:${KEYSTORE_KEY_PASS}" \
          --out="${APK_OUT}" \
          "${APK_IN}"
        echo_green_text "APK signed successfully: ${APK_OUT}"
    else
        echo_red_text "No keystore provided, copying unsigned APK..."
        cp -v "${APK_IN}" "${APK_OUT}"
    fi
fi

if [[ "${BUILD_TYPE}" == "bundle" ]]; then
    echo_green_text "=== Processing Bundle artifacts ==="

    AAB_IN="$(ls "${IRONFOX_GECKO}"/obj/ironfox-${IRONFOX_CHANNEL}-${BUILD_VARIANT}/gradle/build/mobile/android/fenix/app/outputs/bundle/fenixRelease/*.aab)"
    APKS_OUT="${APKS_ARTIFACTS}/IronFox-v${IRONFOX_VERSION}.apks"

    if [[ -f "${IRONFOX_BUNDLETOOL}" ]] && [[ -n "${KEYSTORE:-}" ]]; then
        "${IRONFOX_BUNDLETOOL}" build-apks \
            --bundle="${AAB_IN}" \
            --output="${APKS_OUT}" \
            --ks="${KEYSTORE}" \
            --ks-pass="pass:${KEYSTORE_PASS}" \
            --ks-key-alias="${KEYSTORE_KEY_ALIAS}" \
            --key-pass="pass:${KEYSTORE_KEY_PASS}"
        echo_green_text "Bundle signed successfully: ${APKS_OUT}"
    else
        echo_red_text "Warning: Cannot create signed APK set - bundletool or keystore not available"
        echo "AAB file location: ${AAB_IN}"
    fi
fi

echo_green_text "Artifacts directory: ${ARTIFACTS}"
