#!/usr/bin/env bash

## This script adapts the upstream CI workflow for GitHub Actions runners.
## It delegates to the upstream scripts (get_sources.sh, prebuild.sh, build.sh)
## and handles GitHub Actions-specific signing and artifact collection.
##
## The upstream CI pipeline expects per-arch jobs to only build GeckoView AARs
## (IRONFOX_CI=1 skips Fenix for non-bundle builds), with a final "bundle" job
## assembling them into APKs.  GitHub Actions builds each arch independently and
## needs a complete APK per job, so we:
##   1. Source env with IRONFOX_CI=1 to pick up CI-specific config (keystore
##      paths, SB key, etc.—including any docker-build.yml sed patches).
##   2. Switch to IRONFOX_CI=0 before calling build scripts so the upstream
##      code performs a full build (including Fenix APK assembly).
##   3. Handle signing here, since upstream sign.sh has a naming mismatch
##      for non-bundle single-arch builds.

set -eu
set -o pipefail
set -o xtrace

cd "$(dirname "$0")/.."

source "$(dirname "$0")/utilities.sh"

BUILD_VARIANT="${1:-${VARIANT:-arm64}}"

case "${BUILD_VARIANT}" in
arm|arm64|x86_64|bundle)
    ;;
*)
    echo_red_text "Unknown build variant: '${BUILD_VARIANT}'." >&2
    exit 1
    ;;
esac

export CI_PIPELINE_CREATED_AT="${CI_PIPELINE_CREATED_AT:-$(date -Iseconds)}"
export IF_BUILD_DATE="${CI_PIPELINE_CREATED_AT}"

if [[ -n "${IRONFOX_RELEASE:-}" ]] && [[ "${IRONFOX_RELEASE}" == "1" ]]; then
    echo_green_text "Preparing to build IronFox (Release)..."
else
    export IRONFOX_RELEASE=1
    echo_green_text "Preparing to build IronFox (Release)..."
fi

export IRONFOX_CI=1
bash -x "$(dirname "$0")/env.sh"
source "$(dirname "$0")/env.sh"

export IRONFOX_CI=0

export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Xmx4g -XX:MaxMetaspaceSize=2g"
export _JAVA_OPTIONS="${_JAVA_OPTIONS:-} -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${IRONFOX_ARTIFACTS}/heapdump.hprof"
export ORG_GRADLE_PROJECT_android_r8_maxMemory=4g
export ORG_GRADLE_PROJECT_android_enableR8FullMode=false
export ORG_GRADLE_PROJECT_android_enableDexingArtifactTransform=false
export ORG_GRADLE_PROJECT_android_enableD8MainDexList=false

export IF_BUILD_DATE="${IF_BUILD_DATE:-$(date -Iseconds)}"
export MOZ_BUILD_DATE="${MOZ_BUILD_DATE:-$(date "+%Y%m%d%H%M%S")}"

mkdir -vp "${IRONFOX_APK_ARTIFACTS}"
mkdir -vp "${IRONFOX_APKS_ARTIFACTS}"
mkdir -vp "${IRONFOX_AAR_ARTIFACTS}"

bash -x "${IRONFOX_SCRIPTS}/get_sources.sh"

if [[ -f "${IRONFOX_SCRIPTS}/mocha-patch.sh" ]]; then
    source "${IRONFOX_SCRIPTS}/mocha-patch.sh"
fi

bash -x "${IRONFOX_SCRIPTS}/prebuild.sh"

bash -x "${IRONFOX_SCRIPTS}/build.sh" "${BUILD_VARIANT}"

source "${IRONFOX_VERSIONS}"

echo_green_text "=== Collecting artifacts ==="

if [[ "${BUILD_VARIANT}" != "bundle" ]]; then
    case "${BUILD_VARIANT}" in
        arm64)  ABI="arm64-v8a" ;;
        arm)    ABI="armeabi-v7a" ;;
        x86_64) ABI="x86_64" ;;
    esac

    APK_OUT="${IRONFOX_APK_ARTIFACTS}/IronFox-v${IRONFOX_VERSION}-${ABI}.apk"
    APK_UNSIGNED="${IRONFOX_OUTPUTS_APK}/ironfox-${IRONFOX_CHANNEL}-${ABI}.apk"
    APK_SIGNED="${IRONFOX_OUTPUTS_APK}/ironfox-${IRONFOX_CHANNEL}-${ABI}-signed.apk"

    if [[ -f "${APK_SIGNED}" ]]; then
        cp -v "${APK_SIGNED}" "${APK_OUT}"
    elif [[ -f "${APK_UNSIGNED}" ]]; then
        if [[ "${IRONFOX_SIGN:-0}" == "1" ]] && [[ -f "${IRONFOX_KEYSTORE}" ]]; then
            echo_green_text "Signing APK (${ABI})..."
            "${IRONFOX_ANDROID_SDK}/build-tools/${ANDROID_BUILDTOOLS_VERSION}/apksigner" sign \
                --ks="${IRONFOX_KEYSTORE}" \
                --ks-pass="file:/${IRONFOX_KEYSTORE_PASS_FILE}" \
                --ks-key-alias="${IRONFOX_KEYSTORE_KEY_ALIAS}" \
                --key-pass="file:/${IRONFOX_KEYSTORE_KEY_PASS_FILE}" \
                --out="${APK_OUT}" \
                "${APK_UNSIGNED}"
            echo_green_text "Signed APK: ${APK_OUT}"
        else
            cp -v "${APK_UNSIGNED}" "${APK_OUT}"
        fi
    else
        echo_red_text "Warning: Expected APK not found at ${APK_UNSIGNED}, searching for alternatives..."
        APK_IN=$(find "${IRONFOX_OUTPUTS_APK}" "${IRONFOX_GECKO}/obj" -name "*.apk" \( -name "*${ABI}*" -o -name "*${BUILD_VARIANT}*" \) 2>/dev/null | head -n1 || true)
        if [[ -n "$APK_IN" ]]; then
            echo_green_text "Found APK at: ${APK_IN}"
            cp -v "${APK_IN}" "${APK_OUT}"
        else
            echo_red_text "Error: No APK file found!"
            find "${IRONFOX_OUTPUTS_APK}" -name "*.apk" -ls 2>/dev/null || true
            find "${IRONFOX_GECKO}/obj" -name "*.apk" -ls 2>/dev/null || true
            exit 1
        fi
    fi
else
    echo_green_text "Collecting bundle artifacts..."
    find "${IRONFOX_OUTPUTS_APK}" -name "*.apk" -exec cp -v {} "${IRONFOX_APK_ARTIFACTS}/" \; 2>/dev/null || true
    find "${IRONFOX_OUTPUTS_APKS}" -name "*.apks" -exec cp -v {} "${IRONFOX_APKS_ARTIFACTS}/" \; 2>/dev/null || true
fi

echo_green_text "Build complete! Artifacts directory: ${IRONFOX_ARTIFACTS}"
find "${IRONFOX_ARTIFACTS}" -type f -ls 2>/dev/null || true
