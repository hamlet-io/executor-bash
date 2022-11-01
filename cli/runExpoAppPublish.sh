#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set "${GENERATION_DEBUG}"

trim() {
    local var="$1"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo "${var}"
}

function cleanup_bundler {

    # Make sure the metro bundler isn't left running
    # It will work the first time but as the workspace is
    # deleted each time, it will then be running in a deleted directory
    # and fail every time
    BUNDLER_PID=$(trim "$(lsof -i :8081 -t)")
    if [[ -n "${BUNDLER_PID}" ]]; then
        BUNDLER_PARENT=$(trim "$(ps -o ppid= "${BUNDLER_PID}")")
        echo "Bundler found, pid=${BUNDLER_PID}, ppid=${BUNDLER_PARENT}, cleaning up"
        if [[ -n "${BUNDLER_PID}" && (${BUNDLER_PID} != 1) ]]; then
            kill -9 "${BUNDLER_PID}" || return $?
        fi
        if [[ -n "${BUNDLER_PARENT}" && (${BUNDLER_PARENT} != 1) ]]; then
            kill -9 "${BUNDLER_PARENT}" || return $?
        fi
    fi
    return 0
}

function cleanup {
    # Make sure we always remove keychains that we create
    if [[ -f "${FASTLANE_KEYCHAIN_PATH}" ]]; then
        echo "Deleting keychain ${FASTLANE_KEYCHAIN_PATH}"
        security delete-keychain "${FASTLANE_KEYCHAIN_PATH}"
    fi

    if [[ -n "${OPS_PATH}" ]]; then
        for f in "${OPS_PATH}"/*.keychain; do
            echo "Deleting keychain ${f}"
            security delete-keychain "${f}"
        done
    fi

    # Make sure the bundler is shut down
    cleanup_bundler

    # normal context cleanup
    . "${GENERATION_BASE_DIR}/execution/cleanupContext.sh"

}
trap cleanup EXIT SIGHUP SIGINT SIGTERM

. "${GENERATION_BASE_DIR}/execution/common.sh"

#Defaults
DEFAULT_NODE_PACKAGE_MANAGER="auto"
DEFAULT_BUILD_LOGS="false"
DEFAULT_DEPLOYMENT_GROUP="application"

tmpdir="$(getTempDir "cote_inf_XXX")"

# Get the generation context so we can run template generation
. "${GENERATION_BASE_DIR}/execution/setContext.sh"
. "${GENERATION_BASE_DIR}/execution/setCredentials.sh"

function get_configfile_property() {
    local configfile="$1"
    shift
    local propertyName="$1"
    shift
    local kmsPrefix="$1"
    shift
    local awsRegion="${1}"
    shift

    # Sets a global env var based on the property name provided and a lookup of that property in the build config file
    # Also decrypts the value if it's encrypted by KMS
    propertyValue="$(jq -r --arg propertyName "${propertyName}" '.BuildConfig[$propertyName] | select (.!=null)' <"${configfile}")"

    if [[ "${propertyValue}" == ${kmsPrefix}* ]]; then
        echo "AWS KMS - Decrypting property ${propertyName}"
        propertyValue="$(decrypt_kms_string "${awsRegion}" "${propertyValue#"${kmsPrefix}"}" || return 128)"
    fi

    declare -gx "${propertyName}=${propertyValue}"
    return 0
}

function decrypt_kms_file() {
    local region="$1"
    shift
    local encrypted_file_path="$1"
    shift

    base64 --decode <"${encrypted_file_path}" >"${encrypted_file_path}.base64"
    BASE64_CLEARTEXT_VALUE="$(aws --region "${region}" kms decrypt --ciphertext-blob "fileb://${encrypted_file_path}.base64" --output text --query Plaintext)"
    echo "${BASE64_CLEARTEXT_VALUE}" | base64 --decode >"${encrypted_file_path%".kms"}"
    rm -rf "${encrypted_file_path}.base64"

    if [[ -e "${encrypted_file_path%".kms"}" ]]; then
        return 0
    else
        error "could not decrypt file ${encrypted_file_path}"
        return 128
    fi
}

function set_android_manifest_property() {
    local manifest_content="$1"
    shift
    local name="$1"
    shift
    local value="$1"
    shift

    # Upsert properties into the android manifest metadata
    # Manifest Url
    android_manifest_properties="$(echo "{}" | jq -c --arg name "${name}" --arg propValue "${value}" '{ "@android:name" : $name, "@android:value" : $propValue }')"

    # Set the Url if its not there
    # xq is an jq port for xml based files - https://pypi.org/project/yq/
    manifest_content="$(echo "${manifest_content}" | xq --xml-output \
        --arg propName "${name}" \
        --argjson manifest_props "${android_manifest_properties}" \
        'if ( .manifest.application["meta-data"] | map( select( .["@android:name"] == $propName )) | length ) == 0 then .manifest.application["meta-data"] |= . + [ $manifest_props ]  else . end')"

    # Update the Expo Update Url
    manifest_content="$(echo "${manifest_content}" | xq --xml-output \
        --arg propName "${name}" \
        --argjson manifest_props "${android_manifest_properties}" \
        'walk(if type == "object" and .["@android:name"] == $propName then . |= $manifest_props else . end )')"

    echo "${manifest_content}"
    return 0
}

function check_deps() {
    which -s jq || {
        fatal "Could not find jq on PATH - make sure that jq is installed"
        return 1
    }
    which -s yq || {
        fatal "Could not find yq on PATH - ensure https://pypi.org/project/yq/ is installed"
        return 1
    }
    which -s aws || {
        fatal "Could not find the aws cli on PATH - ensure that it is installed"
        return 1
    }
    which -s bundle || {
        fatal "Could not find the ruby gem bundle command on PATH - ensure that ruby is installed"
        return 1
    }
}

function setup_fastlane_plugins() {
    local work_dir="$1"
    shift

    cat <<EOF >"${work_dir}/Gemfile"
# Autogenerated by fastlane
source "https://rubygems.org"
gem 'fastlane'
gem 'cocoapods'
plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(plugins_path) if File.exist?(plugins_path)
EOF

    mkdir -p "${work_dir}/fastlane"
    cat <<EOF >"${work_dir}/fastlane/Pluginfile"
gem 'fastlane-plugin-firebase_app_distribution', '~> 0.3.4'
gem 'fastlane-plugin-badge', '~> 1.5'
EOF
    bundle install --quiet || return $?
    bundle exec fastlane install_plugins || return $?
}

function usage() {
    cat <<EOF

Run a task based build of an Expo app binary

Usage: $(basename "$0") -u DEPLOYMENT_UNIT -i INPUT_PAYLOAD -l INCLUDE_LOG_TAIL

where

    -h                              shows this text
(m) -u DEPLOYMENT_UNIT              is the mobile app deployment unit
(o) -g DEPLOYMENT_GROUP             is the group the deployment unit belongs to
(o) -n NODE_PACKAGE_MANAGER         Set the node package manager for app installation
(o) -l BUILD_LOGS                   show the build logs for binary builds
(o) -o BINARY_OUTPUT_DIR            The output directory for binaries

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:
NODE_PACKAGE_MANAGER = ${DEFAULT_NODE_PACKAGE_MANAGER}
BUILD_LOGS = ${DEFAULT_BUILD_LOGS}
DEPLOYMENT_GROUP = ${DEFAULT_DEPLOYMENT_GROUP}

EOF
    exit
}

function options() {

    # Parse options
    while getopts ":g:hln:o:u:" opt; do
        case $opt in
        g)
            DEPLOYMENT_GROUP="${OPTARG}"
            ;;
        h)
            usage
            ;;
        l)
            BUILD_LOGS="true"
            ;;
        n)
            NODE_PACKAGE_MANAGER="${OPTARG}"
            ;;
        o)
            BINARY_OUTPUT_DIR="${OPTARG}"
            ;;
        u)
            DEPLOYMENT_UNIT="${OPTARG}"
            ;;
        \?)
            fatalOption
            ;;
        :)
            fatalOptionArgument
            ;;
        esac
    done

    NODE_PACKAGE_MANAGER="${NODE_PACKAGE_MANAGER:-${DEFAULT_NODE_PACKAGE_MANAGER}}"
    BUILD_LOGS="${BUILD_LOGS:-${DEFAULT_BUILD_LOGS}}"
    DEPLOYMENT_GROUP="${DEPLOYMENT_GROUP:-${DEFAULT_DEPLOYMENT_GROUP}}"
}

function main() {

    options "$@" || return $?
    check_deps || return $?

    # Fastlane Standard config
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export FASTLANE_SKIP_UPDATE_CHECK="true"
    export FASTLANE_HIDE_CHANGELOG="true"
    export FASTLANE_HIDE_PLUGINS_TABLE="true"
    export FASTLANE_DISABLE_COLORS=1

    # Ensure mandatory arguments have been provided
    check_for_invalid_environment_variables "DEPLOYMENT_UNIT" || return $?

    # Make sure the previous bundler has been stopped
    cleanup_bundler || (
        fatal "Can't shut down previous instance of the bundler"
        return 1
    )

    # Set data dir for builds
    WORKSPACE_DIR="$(getTempDir "cote_expo_XXXXX")"

    # Generate a build blueprint so that we can find out the source S3 bucket
    info "Collecting build info"
    "${GENERATION_DIR}"/createTemplate.sh -e "buildblueprint" -p "aws" -l "${DEPLOYMENT_GROUP}" -u "${DEPLOYMENT_UNIT}" -o "${tmpdir}" >/dev/null
    BUILD_BLUEPRINT="${tmpdir}/buildblueprint-${DEPLOYMENT_GROUP}-${DEPLOYMENT_UNIT}-config.json"

    if [[ ! -f "${BUILD_BLUEPRINT}" || -z "$(cat "${BUILD_BLUEPRINT}")" ]]; then
        fatal "Could not generate blueprint for task details"
        return 255
    fi

    # Make sure we are in the build source directory
    BINARY_PATH="${BINARY_OUTPUT_DIR:-"${WORKSPACE_DIR}/binary"}"
    SRC_PATH="${WORKSPACE_DIR}/src"
    OPS_PATH="${WORKSPACE_DIR}/ops"

    if [[ -d "${SRC_PATH}" ]]; then
        rm -rf "${SRC_PATH}"
    fi

    mkdir -p "${BINARY_PATH}"
    mkdir -p "${SRC_PATH}"
    mkdir -p "${OPS_PATH}"

    placement_region="$(jq -r '.Occurrence.State.ResourceGroups.default.Placement.Region | select (.!=null)' <"${BUILD_BLUEPRINT}")"
    AWS_REGION="${AWS_REGION:-${placement_region}}"

    # Get config file
    CONFIG_BUCKET="$(jq -r '.Occurrence.State.Attributes.CONFIG_BUCKET' <"${BUILD_BLUEPRINT}")"
    CONFIG_KEY="$(jq -r '.Occurrence.State.Attributes.CONFIG_FILE' <"${BUILD_BLUEPRINT}")"
    CONFIG_FILE="${OPS_PATH}/config.json"

    info "Getting configuration file from s3://${CONFIG_BUCKET}/${CONFIG_KEY}"
    aws --region "${AWS_REGION}" s3 cp --only-show-errors "s3://${CONFIG_BUCKET}/${CONFIG_KEY}" "${CONFIG_FILE}" || return $?

    KMS_PREFIX="$(jq -r '.BuildConfig.KMS_PREFIX' <"${CONFIG_FILE}")"

    # Operations data - Credentials, config etc.
    get_configfile_property "${CONFIG_FILE}" "OPSDATA_BUCKET" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "SETTINGS_PREFIX" "${KMS_PREFIX}" "${AWS_REGION}"

    # The source of the prepared code repository zip
    get_configfile_property "${CONFIG_FILE}" "CODE_SRC_BUCKET" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "CODE_SRC_PREFIX" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "APPDATA_BUCKET" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "APPDATA_PREFIX" "${KMS_PREFIX}" "${AWS_REGION}"

    # Where the public artefacts will be published to
    get_configfile_property "${CONFIG_FILE}" "OTA_ARTEFACT_BUCKET" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "OTA_ARTEFACT_PREFIX" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "OTA_ARTEFACT_URL" "${KMS_PREFIX}" "${AWS_REGION}"
    PUBLIC_ASSETS_PATH="assets"

    get_configfile_property "${CONFIG_FILE}" "APP_BUILD_FORMATS" "${KMS_PREFIX}" "${AWS_REGION}"
    arrayFromList BUILD_FORMATS "${APP_BUILD_FORMATS}"

    get_configfile_property "${CONFIG_FILE}" "APP_REFERENCE" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "BUILD_REFERENCE" "${KMS_PREFIX}" "${AWS_REGION}"
    BUILD_NUMBER="$(date +"%Y%m%d.1%H%M%S")"
    get_configfile_property "${CONFIG_FILE}" "RELEASE_CHANNEL" "${KMS_PREFIX}" "${AWS_REGION}"

    get_configfile_property "${CONFIG_FILE}" "IOS_PROJECT_ROOT_DIR" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "ANDROID_PROJECT_ROOT_DIR" "${KMS_PREFIX}" "${AWS_REGION}"

    get_configfile_property "${CONFIG_FILE}" "IOS_DIST_BUNDLE_ID" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "IOS_DIST_DISPLAY_NAME" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "IOS_DIST_NON_EXEMPT_ENCRYPTION" "${KMS_PREFIX}" "${AWS_REGION}"

    get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_BUNDLE_ID" "${KMS_PREFIX}" "${AWS_REGION}"

    # Prepare the code build environment
    info "Getting source code from from s3://${CODE_SRC_BUCKET}/${CODE_SRC_PREFIX}/scripts.zip"
    aws --region "${AWS_REGION}" s3 cp --only-show-errors "s3://${CODE_SRC_BUCKET}/${CODE_SRC_PREFIX}/scripts.zip" "${tmpdir}/scripts.zip" || return $?

    unzip -q "${tmpdir}/scripts.zip" -d "${SRC_PATH}" || return $?

    cd "${SRC_PATH}" || {
        fatal "could not cd into ${SRC_PATH}"
        return $?
    }

    # Support the usual node package manager preferences
    if [[ "${NODE_PACKAGE_MANAGER}" == "auto" ]]; then
        if [[ -f "yarn.lock" ]]; then
            NODE_PACKAGE_MANAGER="yarn"
        elif [[ -f "package.lock" ]]; then
            NODE_PACKAGE_MANAGER="npm"
        else
            fatal "Could not find lock file for npm or yarn - specify package manager option"
            return 1
        fi
    fi

    case "${NODE_PACKAGE_MANAGER}" in
    "yarn")
        yarn install --production=false || return $?
        ;;

    "npm")
        npm ci || return $?
        ;;
    esac

    # Decrypt secrets from credentials store
    info "Getting settings files from s3://${OPSDATA_BUCKET}/${SETTINGS_PREFIX}"
    aws --region "${AWS_REGION}" s3 sync --only-show-errors "s3://${OPSDATA_BUCKET}/${SETTINGS_PREFIX}" "${OPS_PATH}" || return $?
    for i in "${OPS_PATH}"/*.kms; do decrypt_kms_file "${AWS_REGION}" "${i}"; done

    # Get the version of the expo SDK which is required
    EXPO_SDK_VERSION="$(jq -r '.expo.sdkVersion | select (.!=null)' <./app.json)"
    EXPO_PROJECT_SLUG="$(jq -r '.expo.slug' <./app.json)"

    get_configfile_property "${CONFIG_FILE}" "APP_VERSION_SOURCE" "${KMS_PREFIX}" "${AWS_REGION}"
    case "${APP_VERSION_SOURCE}" in
    "manifest")
        EXPO_APP_VERSION="$(jq -r '.expo.version' <./app.json)"
        ;;

    "cmdb")
        [[ -z "${APP_REFERENCE}" ]] && APP_REFERENCE="0.0.1"
        EXPO_APP_VERSION="${APP_REFERENCE#v}"
        ;;

    *)
        fatal "Invalid APP_VERSION_SOURCE - ${APP_VERSION_SOURCE}" && exit 255
        ;;
    esac
    EXPO_APP_VERSION="$(semver_clean ${EXPO_APP_VERSION})"

    arrayFromList EXPO_APP_VERSION_PARTS "$(semver_valid "${EXPO_APP_VERSION}")"
    EXPO_APP_MAJOR_VERSION="${EXPO_APP_VERSION_PARTS[0]}"

    ## defines a prefix for the OTA versions - there can be different rules which define the OTA_VERSION
    OTA_VERSION="${EXPO_APP_MAJOR_VERSION}"

    if [[ -n "${EXPO_SDK_VERSION}" ]]; then
        OTA_VERSION="${EXPO_SDK_VERSION}"
    fi

    arrayFromList EXPO_SDK_VERSION_PARTS "$(semver_valid "${EXPO_SDK_VERSION}")"
    EXPO_SDK_MAJOR_VERSION="${EXPO_SDK_VERSION_PARTS[0]}"

    # Update the app.json with build context information - Also ensure we always have a unique IOS build number
    # filter out the credentials used for the build process
    jq --slurpfile envConfig "${CONFIG_FILE}" \
        --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" \
        --arg BUILD_REFERENCE "${BUILD_REFERENCE}" \
        --arg BUILD_NUMBER "${BUILD_NUMBER}" \
        '.expo.releaseChannel=$RELEASE_CHANNEL | .expo.extra.BUILD_REFERENCE=$BUILD_REFERENCE | .expo.ios.buildNumber=$BUILD_NUMBER | .expo.extra=.expo.extra + $envConfig[]["AppConfig"]' <"./app.json" >"${tmpdir}/environment-app.json"
    mv "${tmpdir}/environment-app.json" "./app.json"

    # Optional app.json overrides
    if [[ -n "${IOS_DIST_BUNDLE_ID}" ]]; then
        jq --arg IOS_DIST_BUNDLE_ID "${IOS_DIST_BUNDLE_ID}" '.expo.ios.bundleIdentifier=$IOS_DIST_BUNDLE_ID' <"./app.json" >"${tmpdir}/ios-bundle-app.json"
        mv "${tmpdir}/ios-bundle-app.json" "./app.json"
    fi

    jq --arg IOS_NON_EXEMPT_ENCRYPTION "${IOS_DIST_NON_EXEMPT_ENCRYPTION}" '.expo.ios.config.usesNonExemptEncryption=($IOS_NON_EXEMPT_ENCRYPTION | test("true"))' <"./app.json" >"${tmpdir}/ios-encexempt-app.json"
    mv "${tmpdir}/ios-encexempt-app.json" "./app.json"

    if [[ -n "${ANDROID_DIST_BUNDLE_ID}" ]]; then
        jq --arg ANDROID_DIST_BUNDLE_ID "${ANDROID_DIST_BUNDLE_ID}" '.expo.android.package=$ANDROID_DIST_BUNDLE_ID' <"./app.json" >"${tmpdir}/android-bundle-app.json"
        mv "${tmpdir}/android-bundle-app.json" "./app.json"
    fi

    # Create base OTA
    info "Creating an OTA | App Version: ${EXPO_APP_MAJOR_VERSION} | OTA Version: ${OTA_VERSION} | Expo SDK Version: ${EXPO_SDK_MAJOR_VERSION}"
    EXPO_VERSION_PUBLIC_URL="${OTA_ARTEFACT_URL}/packages/${EXPO_APP_MAJOR_VERSION}/${OTA_VERSION}"

    if [[ "${EXPO_SDK_MAJOR_VERSION}" -ge "46" ]]; then
        expo_npx_base_args=()
        expo_url_args=()
    else

        EXPO_GLOBAL_CLI_VERSION="$(npm info expo-cli --json | jq -r '[.versions[] | select(startswith("5"))][-1]')"
        EXPO_PACKAGE="expo-cli@${EXPO_GLOBAL_CLI_VERSION}"

        npm_tool_cache="$(getTempDir "cote_npm_XXX")"
        expo_npx_base_args=("--quiet" "--cache" "${npm_tool_cache}" "--package" "${EXPO_PACKAGE}")
        expo_url_args=("--public-url" "${EXPO_VERSION_PUBLIC_URL}" "--asset-url" "${PUBLIC_ASSETS_PATH}")
    fi

    yes | npx "${expo_npx_base_args[@]}" expo export "${expo_url_args[@]}" --dump-sourcemap --dump-assetmap --output-dir "${SRC_PATH}/app/dist/build/${OTA_VERSION}" || return $?

    if [[ "${EXPO_SDK_MAJOR_VERSION}" -le "45" ]]; then

        IOS_INDEX_FILE="${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json"
        ANDROID_INDEX_FILE="${SRC_PATH}/app/dist/build/${OTA_VERSION}/android-index.json"

        [[ -f "${IOS_INDEX_FILE}" ]] || { fatal "Could not find generated ios ota config file"; return 1;}
        [[ -f "${ANDROID_INDEX_FILE}" ]] || { fatal "Could not find generated andorid ota config file"; return 1;}

        get_configfile_property "${CONFIG_FILE}" "EXPO_ID_OVERRIDE" "${KMS_PREFIX}" "${AWS_REGION}"
        if [[ -n "${EXPO_ID_OVERRIDE}" ]]; then

            jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' < "${IOS_INDEX_FILE}" >"${tmpdir}/ios-expo-override.json"
            mv "${tmpdir}/ios-expo-override.json" "${IOS_INDEX_FILE}"

            jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' < "${ANDROID_INDEX_FILE}" >"${tmpdir}/android-expo-override.json"
            mv "${tmpdir}/android-expo-override.json" "${ANDROID_INDEX_FILE}"

        fi

        info "Override revisionId to match the build reference ${BUILD_REFERENCE}"
        jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' <"${IOS_INDEX_FILE}" >"${tmpdir}/ios-expo-override.json"
        mv "${tmpdir}/ios-expo-override.json" "${IOS_INDEX_FILE}"

        jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' <"${ANDROID_INDEX_FILE}" >"${tmpdir}/android-expo-override.json"
        mv "${tmpdir}/android-expo-override.json" "${ANDROID_INDEX_FILE}"
    fi

    info "Copying OTA to CDN"
    aws --region "${AWS_REGION}" s3 sync --only-show-errors --delete "${SRC_PATH}/app/dist/build/${OTA_VERSION}" "s3://${OTA_ARTEFACT_BUCKET}/${OTA_ARTEFACT_PREFIX}/packages/${EXPO_APP_MAJOR_VERSION}/${OTA_VERSION}" || return $?
    aws --region "${AWS_REGION}" s3 sync --only-show-errors --delete "${SRC_PATH}/app/dist/build/${OTA_VERSION}" "s3://${OTA_ARTEFACT_BUCKET}/${OTA_ARTEFACT_PREFIX}/archive/${BUILD_REFERENCE}" || return $?

    if [[ ( "${BUILD_FORMATS[*]}" == *ios* && ! -d "${SRC_PATH}/${IOS_PROJECT_ROOT_DIR}" ) ||
            ("${BUILD_FORMATS[*]}" == *android* && ! -d "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}") ]]; then

        if [[ "${EXPO_SDK_MAJOR_VERSION}" -ge "46" ]]; then
            EXPO_PROJECT_SLUG="$(jq -r '.expo.name' <./app.json)"

            expo_prebuild_args=("--clean")
            case "${NODE_PACKAGE_MANAGER}" in
            "yarn")
                expo_prebuild_args=("${expo_prebuild_args[@]}" "--yarn")
                ;;

            "npm")
                expo_prebuild_args=("${expo_prebuild_args[@]}" "--npm")
                ;;
            esac
            export EXPO_NO_GIT_STATUS=1
            npx expo prebuild "${expo_prebuild_args[@]}" || return $?
        else
            fatal "Native folders could not be found for android or ios project dirs"
            return 1
        fi
    fi

    #-- Fastlane based processes --
    setup_fastlane_plugins "${SRC_PATH}" || return $?

    #--- Icon Badges --
    # Add a shield to the App icons with the environment for the app
    get_configfile_property "${CONFIG_FILE}" "ENVIRONMENT_BADGE_CONTENT" "${KMS_PREFIX}" "${AWS_REGION}"
    get_configfile_property "${CONFIG_FILE}" "ENVIRONMENT_BADGE_COLOR" "${KMS_PREFIX}" "${AWS_REGION}"

    if [[ -n "${ENVIRONMENT_BADGE_CONTENT}" ]]; then
        badge_args=("shield:${ENVIRONMENT_BADGE_CONTENT}-${ENVIRONMENT_BADGE_COLOR}" "shield_scale:0.5" "no_badge;true" "shield_gravity:South" "shield_parameters:style=flat")

        # iOS is the default pattern to match
        bundle exec fastlane run add_badge "${badge_args[@]}" "shield_geometry:+0+5%"
        # Android search path
        bundle exec fastlane run add_badge "${badge_args[@]}" "shield_geometry:+0+20%" "glob:/**/src/main/res/mipmap-*/ic_launcher*.png"
    fi

    #--- Run Builds --
    for build_format in "${BUILD_FORMATS[@]}"; do

        BINARY_FILE_PREFIX="${build_format}"

        if [[ "${EXPO_SDK_MAJOR_VERSION}" -ge "46" ]]; then
            EXPO_MANIFEST_URL="${EXPO_VERSION_PUBLIC_URL}/metadata.json"
        else
            EXPO_MANIFEST_URL="${EXPO_VERSION_PUBLIC_URL}/${build_format}-index.json"
        fi

        case "${build_format}" in
        "android")
            BINARY_FILE_EXTENSION="apk"

            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEYSTORE_FILENAME" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEYSTORE_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEY_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEY_ALIAS" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_PLAYSTORE_JSON_KEY" "${KMS_PREFIX}" "${AWS_REGION}"

            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_FIREBASE_APP_ID" "${KMS_PREFIX}" "${AWS_REGION}"

            get_configfile_property  "${CONFIG_FILE}" "ANDROID_DIST_FIREBASE_JSON_KEY_FILENAME" "${KMS_PREFIX}" "${AWS_REGION}"
            FIREBASE_JSON_KEY_FILE="${OPS_PATH}/${ANDROID_DIST_FIREBASE_JSON_KEY_FILENAME}"

            get_configfile_property  "${CONFIG_FILE}" "ANDROID_PLAYSTORE_JSON_KEY_FILENAME" "${KMS_PREFIX}" "${AWS_REGION}"
            ANDROID_PLAYSTORE_JSON_KEY_FILE="${OPS_PATH}/${ANDROID_DIST_FIREBASE_JSON_KEY_FILENAME}"

            export ANDROID_DIST_KEYSTORE_FILE="${OPS_PATH}/${ANDROID_DIST_KEYSTORE_FILENAME}"
            ;;

        "ios")

            [[ $OSTYPE != 'darwin'* ]] && {
                fatal "ios build format requires a macOS based host"
                return 1
            }

            BINARY_FILE_EXTENSION="ipa"

            # Get properties from retrieved config file and decrypt if required
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_APPLE_ID" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_APP_ID" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_EXPORT_METHOD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_TESTFLIGHT_USERNAME" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_TESTFLIGHT_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_P12_FILENAME" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_P12_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_CODESIGN_IDENTITY" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_PROVISIONING_PROFILE_FILENAME" "${KMS_PREFIX}" "${AWS_REGION}"

            export IOS_DIST_PROVISIONING_PROFILE_BASE="${IOS_DIST_PROVISIONING_PROFILE_FILENAME%.*}"
            export IOS_DIST_PROVISIONING_PROFILE_EXTENSION="${IOS_DIST_PROVISIONING_PROFILE_FILENAME#*.}"
            export IOS_DIST_PROVISIONING_PROFILE="${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_FILENAME}"
            export IOS_DIST_P12_FILE="${OPS_PATH}/${IOS_DIST_P12_FILENAME}"
            ;;
        "*")
            echo "Unkown build format" && return 128
            ;;
        esac

        info "Building App Binary for ${build_format}"

        EXPO_BINARY_FILE_NAME="${BINARY_FILE_PREFIX}-${EXPO_APP_VERSION}-${BUILD_NUMBER}.${BINARY_FILE_EXTENSION}"
        EXPO_BINARY_FILE_PATH="${BINARY_PATH}/${EXPO_BINARY_FILE_NAME}"

        if [[ "${build_format}" == "ios" ]]; then
            FASTLANE_KEYCHAIN_PATH="${OPS_PATH}/${BUILD_NUMBER}.keychain"
            FASTLANE_KEYCHAIN_NAME="${BUILD_NUMBER}"
            FASTLANE_IOS_PROJECT_FILE="${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}.xcodeproj"
            FASTLANE_IOS_WORKSPACE_FILE="${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}.xcworkspace"
            FASTLANE_IOS_PODFILE="${IOS_PROJECT_ROOT_DIR}/Podfile"

            # Update App details
            # Pre SDK37, Expokit maintained an Info.plist in Supporting
            INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Supporting/Info.plist"
            [[ ! -e "${IOS_PROJECT_ROOT_DIR}/${INFO_PLIST_PATH}" ]] && INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Info.plist"
            bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${INFO_PLIST_PATH}" key:CFBundleVersion value:"${BUILD_NUMBER}" || return $?
            bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${INFO_PLIST_PATH}" key:CFBundleShortVersionString value:"${EXPO_APP_VERSION}" || return $?

            if [[ "${IOS_DIST_NON_EXEMPT_ENCRYPTION}" == "false" ]]; then
                IOS_USES_NON_EXEMPT_ENCRYPTION="NO"
            else
                IOS_USES_NON_EXEMPT_ENCRYPTION="YES"
            fi
            bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${INFO_PLIST_PATH}" key:ITSAppUsesNonExemptEncryption value:"${IOS_USES_NON_EXEMPT_ENCRYPTION}" || return $?

            if [[ -n "${IOS_DIST_BUNDLE_ID}" ]]; then
                pushd ios || {
                    fatal "could not change to ios dir"
                    return $?
                }
                bundle exec fastlane run update_app_identifier app_identifier:"${IOS_DIST_BUNDLE_ID}" xcodeproj:"${EXPO_PROJECT_SLUG}.xcodeproj" plist_path:"${INFO_PLIST_PATH}" || return $?
                popd || return $?
            fi

            if [[ -n "${IOS_DIST_DISPLAY_NAME}" ]]; then
                pushd ios || {
                    fatal "could not change to ios dir"
                    return $?
                }
                bundle exec fastlane run update_info_plist display_name:"${IOS_DIST_DISPLAY_NAME}" xcodeproj:"${EXPO_PROJECT_SLUG}.xcodeproj" plist_path:"${INFO_PLIST_PATH}" || return $?
                popd || return $?
            fi

            if [[ -e "${SRC_PATH}/${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" ]]; then
                # Bare workflow support (SDK 37+)
                # SDK Version
                if [[ -n "${EXPO_SDK_VERSION}" ]]; then
                    bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesSDKVersion value:"${EXPO_SDK_VERSION}" || return $?
                fi

                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesURL value:"${EXPO_MANIFEST_URL}" || return $?
                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesReleaseChannel value:"${RELEASE_CHANNEL}" || return $?
                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesCheckOnLaunch value:"ALWAYS" || return $?
                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesLaunchWaitMs value:"10000" || return $?

            else
                # Legacy Expokit support
                # Update Expo Details and seed with latest expo bundles
                BINARY_BUNDLE_FILE="${SRC_PATH}/${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/shell-app-manifest.json"
                cp "${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json" "${BINARY_BUNDLE_FILE}"

                # Get the bundle file name from the manifest
                BUNDLE_URL="$(jq -r '.bundleUrl' <"${BINARY_BUNDLE_FILE}")"
                BUNDLE_FILE_NAME="$(basename "${BUNDLE_URL}")"

                cp "${SRC_PATH}/app/dist/build/${OTA_VERSION}/bundles/${BUNDLE_FILE_NAME}" "${SRC_PATH}/${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/shell-app.bundle"

                jq --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" --arg MANIFEST_URL "${EXPO_MANIFEST_URL}" '.manifestUrl=$MANIFEST_URL | .releaseChannel=$RELEASE_CHANNEL' <"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json" >"${tmpdir}/EXShell.json"
                mv "${tmpdir}/EXShell.json" "${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json"

                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:manifestUrl value:"${EXPO_MANIFEST_URL}" || return $?
                bundle exec fastlane run set_info_plist_value path:"${IOS_PROJECT_ROOT_DIR}/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:releaseChannel value:"${RELEASE_CHANNEL}" || return $?
            fi

            # Keychain setup - Create a temporary keychain
            bundle exec fastlane run create_keychain path:"${FASTLANE_KEYCHAIN_PATH}" password:"${FASTLANE_KEYCHAIN_NAME}" add_to_search_list:"true" unlock:"true" timeout:3600 || return $?

            # Codesigning setup
            bundle exec fastlane run import_certificate certificate_path:"${OPS_PATH}/${IOS_DIST_P12_FILENAME}" certificate_password:"${IOS_DIST_P12_PASSWORD}" keychain_path:"${FASTLANE_KEYCHAIN_PATH}" keychain_password:"${FASTLANE_KEYCHAIN_NAME}" log_output:"true" || return $?
            CODESIGN_IDENTITY="$(security find-certificate -c "${IOS_DIST_CODESIGN_IDENTITY}" -p "${FASTLANE_KEYCHAIN_PATH}" | openssl x509 -noout -subject -nameopt multiline | grep commonName | sed -n 's/ *commonName *= //p')"
            if [[ -z "${CODESIGN_IDENTITY}" ]]; then
                fatal "Could not find code signing identity matching type: ${IOS_DIST_CODESIGN_IDENTITY} - To get the identity download the distribution certificate and get the commonName. The IOS_DIST_CODESIGN_IDENTITY is the bit before the : ( will be Apple Distribution or iPhone Distribution"
                return 255
            fi

            # Load the app provisioning profile
            bundle exec fastlane run install_provisioning_profile path:"${IOS_DIST_PROVISIONING_PROFILE}" || return $?
            bundle exec fastlane run update_project_provisioning xcodeproj:"${FASTLANE_IOS_PROJECT_FILE}" profile:"${IOS_DIST_PROVISIONING_PROFILE}" code_signing_identity:"${IOS_DIST_CODESIGN_IDENTITY}" || return $?

            # Load extension profiles
            # Extension target name is assumed to be the string appended to "ios_profile" in the profile name
            # ios_profile_xxx.mobileprovision -> target is xxx
            for PROFILE in "${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}"*"${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"; do
                TARGET="${PROFILE%"${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"}"
                TARGET="${TARGET#"${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}"}"
                # Ignore the app provisioning profile
                [[ -z "${TARGET}" ]] && continue
                # Update the extension target
                TARGET="${TARGET#_}"
                echo "Updating target ${TARGET}"
                bundle exec fastlane run install_provisioning_profile path:"${PROFILE}" || return $?
                bundle exec fastlane run update_project_provisioning xcodeproj:"${FASTLANE_IOS_PROJECT_FILE}" profile:"${PROFILE}" target_filter:".*${TARGET}.*" code_signing_identity:"${IOS_DIST_CODESIGN_IDENTITY}" || return $?
                # Update the plist file as well if present
                TARGET_PLIST_PATH="ios/${TARGET}/Info.plist"
                if [[ -f "${TARGET_PLIST_PATH}" ]]; then
                    bundle exec fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleVersion value:"${BUILD_NUMBER}" || return $?
                    bundle exec fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleShortVersionString value:"${EXPO_APP_VERSION}" || return $?
                    if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
                        bundle exec fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleIdentifier value:"${IOS_DIST_BUNDLE_ID}.${TARGET}" || return $?
                    fi
                fi
            done

            bundle exec fastlane run update_code_signing_settings use_automatic_signing:false path:"${FASTLANE_IOS_PROJECT_FILE}" team_id:"${IOS_DIST_APPLE_ID}" code_sign_identity:"${IOS_DIST_CODESIGN_IDENTITY}" || return $?

            if [[ "${BUILD_LOGS}" == "true" ]]; then
                FASTLANE_IOS_SILENT="false"
            else
                FASTLANE_IOS_SILENT="true"
            fi

            # Build App
            bundle exec fastlane run cocoapods silent:"${FASTLANE_IOS_SILENT}" podfile:"${FASTLANE_IOS_PODFILE}" try_repo_update_on_error:"true" || return $?
            bundle exec fastlane run build_ios_app suppress_xcode_output:"${FASTLANE_IOS_SILENT}" silent:"${FASTLANE_IOS_SILENT}" workspace:"${FASTLANE_IOS_WORKSPACE_FILE}" output_directory:"${BINARY_PATH}" output_name:"${EXPO_BINARY_FILE_NAME}" export_method:"${IOS_DIST_EXPORT_METHOD}" codesigning_identity:"${CODESIGN_IDENTITY}" include_symbols:"true" || return $?
        fi

        if [[ "${build_format}" == "android" ]]; then

            # Bundle Overrides
            export ANDROID_DIST_BUNDLE_ID

            # Handle Google Id formatting rules ( https://developer.android.com/studio/publish/versioning.html )
            ANDROID_VERSION_CODE="$(echo "${BUILD_NUMBER//".1"/}" | cut -c 3- | rev | cut -c 3- | rev | cut -c -9)"
            export ANDROID_VERSION_CODE

            ANDROID_VERSION_NAME="${EXPO_APP_VERSION}"
            export ANDROID_VERSION_NAME

            # Create google_services account file
            if [[ -f "${OPS_PATH}/google-services.json" ]]; then
                info "Updating google services ${OPS_PATH}/google-services.json -> ${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/google-services.json"
                cp "${OPS_PATH}/google-services.json" "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/google-services.json"
            fi

            if [[ -e "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/src/main/AndroidManifest.xml" ]]; then

                # Update Expo Details
                manifest_content="$(cat "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/src/main/AndroidManifest.xml")"
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATE_URL" "${EXPO_MANIFEST_URL}")"
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_SDK_VERSION" "${EXPO_SDK_VERSION}")"
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATES_CHECK_ON_LAUNCH" "ALWAYS")"
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATES_LAUNCH_WAIT_MS" "10000")"

                if [[ -n "${manifest_content}" ]]; then
                    echo "${manifest_content}" >"${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/src/main/AndroidManifest.xml"
                else
                    error "Couldn't update manifest details for expo Updates"
                    exit 128
                fi

                gradle_args=("--console=plain")
                if [[ "${BUILD_LOGS}" == "false" ]]; then
                    gradle_args=("${gradle_args[@]}" "--quiet")
                fi

                # Run the react build
                cd "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}" || {
                    fatal "Could not change to android src dir"
                    return $?
                }
                ./gradlew "${gradle_args[@]}" -I "${GENERATION_BASE_DIR}/execution/expoAndroidSigning.gradle" assembleRelease || return $?
                cd "${SRC_PATH}" || {
                    fatal "Could not change to src dir"
                    return $?
                }

                if [[ -f "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/build/outputs/apk/release/app-release.apk" ]]; then
                    cp "${SRC_PATH}/${ANDROID_PROJECT_ROOT_DIR}/app/build/outputs/apk/release/app-release.apk" "${EXPO_BINARY_FILE_PATH}"
                else
                    error "Could not find android build file"
                    return 128
                fi
            fi
        fi

        if [[ -f "${EXPO_BINARY_FILE_PATH}" ]]; then
            info "Copying app binary to s3://${APPDATA_BUCKET}/${APPDATA_PREFIX}/"
            aws --region "${AWS_REGION}" s3 sync --only-show-errors --exclude "*" --include "${BINARY_FILE_PREFIX}*" "${BINARY_PATH}" "s3://${APPDATA_BUCKET}/${APPDATA_PREFIX}/" || return $?

            case "${build_format}" in
            "ios")
                if [[ "${IOS_DIST_EXPORT_METHOD}" == "app-store" ]]; then
                    if [[ -n "${IOS_DIST_APP_ID}" ]]; then

                        info "Submitting IOS binary to testflight"
                        export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="${IOS_TESTFLIGHT_PASSWORD}"
                        # see https://github.com/fastlane/fastlane/issues/20756#issuecomment-1286277976
                        export ITMSTRANSPORTER_FORCE_ITMS_PACKAGE_UPLOAD=true
                        # Handle removal of Transporter from xcode/Developer tools
                        if [[ -d "/Applications/Transporter.app/Contents/itms" ]]; then
                            export FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT=1
                            export FASTLANE_ITUNES_TRANSPORTER_PATH=/Applications/Transporter.app/Contents/itms
                        fi
                        bundle exec fastlane run upload_to_testflight skip_waiting_for_build_processing:true apple_id:"${IOS_DIST_APP_ID}" ipa:"${EXPO_BINARY_FILE_PATH}" username:"${IOS_TESTFLIGHT_USERNAME}" || return $?
                    fi
                fi
                ;;

            "android")
                if [[ -f "${ANDROID_PLAYSTORE_JSON_KEY_FILE}" ]]; then
                    info "Submitting android build to play store"
                    bundle exec fastlane run upload_to_play_store apk:"${EXPO_BINARY_FILE_PATH}" track:"beta" json_key:"${ANDROID_PLAYSTORE_JSON_KEY_FILE}"
                fi

                if [[ -f "${FIREBASE_JSON_KEY_FILE}" ]]; then
                    info "Submitting android build to firebase"
                    bundle exec fastlane run firebase_app_distribution app:"${ANDROID_DIST_FIREBASE_APP_ID}" service_credentials_file:"${FIREBASE_JSON_KEY_FILE}" apk_path:"${EXPO_BINARY_FILE_PATH}"
                fi
                ;;
            esac
        fi

    done

    info "App Publish completed for ${DEPLOYMENT_GROUP}/${DEPLOYMENT_UNIT}"
    # All good
    return 0
}

main "$@" || exit $?
