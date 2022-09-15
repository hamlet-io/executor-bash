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
        echo "Bundler found, pid=${BUNDLER_PID}, ppid=${BUNDLER_PARENT} ..."
        if [[ -n "${BUNDLER_PID}" && (${BUNDLER_PID} != 1) ]]; then
            echo "Killing bundler, pid=${BUNDLER_PID} ..."
            kill -9 "${BUNDLER_PID}" || return $?
        fi
        if [[ -n "${BUNDLER_PARENT}" && (${BUNDLER_PARENT} != 1) ]]; then
            echo "Killing bundler parent, pid=${BUNDLER_PARENT} ..."
            kill -9 "${BUNDLER_PARENT}" || return $?
        fi
    fi
    return 0
}

function cleanup {
    # Make sure we always remove keychains that we create
    if [[ -f "${FASTLANE_KEYCHAIN_PATH}" ]]; then
        echo "Deleting keychain ${FASTLANE_KEYCHAIN_PATH} ..."
        security delete-keychain "${FASTLANE_KEYCHAIN_PATH}"
    fi

    if [[ -n "${OPS_PATH}" ]]; then
        for f in "${OPS_PATH}"/*.keychain; do
            echo "Deleting keychain ${f} ..."
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
DEFAULT_ENVIRONMENT_BADGE="false"

DEFAULT_RUN_SETUP="false"
DEFAULT_FORCE_BINARY_BUILD="false"
DEFAULT_SUBMIT_BINARY="false"

DEFAULT_NODE_PACKAGE_MANAGER="yarn"

DEFAULT_APP_VERSION_SOURCE="manifest"

DEFAULT_BUILD_LOGS="false"
DEFAULT_KMS_PREFIX="base64:"

DEFAULT_DEPLOYMENT_GROUP="application"

DEFAULT_IOS_DIST_CODESIGN_IDENTITY="iPhone Distribution"
DEFAULT_IOS_DIST_NON_EXEMPT_ENCRYPTION="false"

tmpdir="$(getTempDir "cote_inf_XXX")"
npm_tool_cache="$(getTempDir "cote_npm_XXX")"

npx_base_args=("--quiet" "--cache" "${npm_tool_cache}")

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
        echo "AWS KMS - Decrypting property ${propertyName}..."
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

function env_setup() {

    # Homebrew install
    brew upgrade || return $?
    brew install \
        jq \
        yarn \
        python || return $?

    brew cask upgrade || return $?
    brew cask install fastlane android-studio || return $?
    brew link --overwrite fastlane

    # Install android sdk components
    # - Download the command line tools so that we can then install the appropriate tools in a shared location
    export ANDROID_HOME=$HOME/Library/Android/sdk
    rm -rf /usr/local/share/android-commandlinetools
    mkdir -p /usr/local/share/android-commandlinetools
    curl -o /usr/local/share/android-commandlinetools/commandlinetools-mac-6609375_latest.zip --url https://dl.google.com/android/repository/commandlinetools-mac-6609375_latest.zip
    unzip /usr/local/share/android-commandlinetools/commandlinetools-mac-6609375_latest.zip -d /usr/local/share/android-commandlinetools/

    # - Accept Licenses
    yes | /usr/local/share/android-commandlinetools/tools/bin/sdkmanager --sdk_root="${ANDROID_HOME}" --licenses

    # - Install required packages
    /usr/local/share/android-commandlinetools/tools/bin/sdkmanager --sdk_root="${ANDROID_HOME}" 'cmdline-tools;latest' 'platforms;android-30' 'platforms;android-10' 'build-tools;30.0.2'

    # Make sure we have required software installed
    pip3 install \
        awscli \
        yq || return $?
}

function setup_fastlane_plugins() {
    local work_dir="$1"; shift

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

function update_podfile_signing() {
    local pod_file="$1"; shift

    if grep "\s*post_install do |installer|$" ; then
        sed '/\s*post_install do |installer|$/a \
            installer.pods_project.targets.each do |target|\
                target.build_configurations.each do |config|\
                    config.build_settings['"'"'EXPANDED_CODE_SIGN_IDENTITY'"'"'] = ""\
                    config.build_settings['"'"'CODE_SIGNING_REQUIRED'"'"'] = "NO"\
                    config.build_settings['"'"'CODE_SIGNING_ALLOWED'"'"'] = "NO"\
                end\
            end\
        ' "${pod_file}"
    else
        cat <<EOF  >> "${pod_file}"
post_install do |installer|
    installer.pods_project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['EXPANDED_CODE_SIGN_IDENTITY'] = ""
            config.build_settings['CODE_SIGNING_REQUIRED'] = "NO"
            config.build_settings['CODE_SIGNING_ALLOWED'] = "NO"
        end
    end
end
EOF

    fi
}


function usage() {
    cat <<EOF

Run a task based build of an Expo app binary

Usage: $(basename "$0") -u DEPLOYMENT_UNIT -i INPUT_PAYLOAD -l INCLUDE_LOG_TAIL

where

    -h                              shows this text
(m) -u DEPLOYMENT_UNIT              is the mobile app deployment unit
(o) -g DEPLOYMENT_GROUP             is the group the deployment unit belongs to
(o) -s RUN_SETUP                    run setup installation to prepare
(o) -f FORCE_BINARY_BUILD           force the build of binary images
(o) -n NODE_PACKAGE_MANAGER         Set the node package manager for app installation
(o) -m SUBMIT_BINARY                submit the binary for testing
(o) -v APP_VERSION_SOURCE           sets what to use for the app version ( cmdb | manifest)
(o) -l BUILD_LOGS                   show the build logs for binary builds
(o) -e ENVIRONMENT_BADGE            add a badge to the app icons with the environment
(o) -d ENVIRONMENT_BADGE_CONTENT    override the environment content with your own
(o) -o BINARY_OUTPUT_DIR            The output directory for binaries

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:
BUILD_FORMATS = ${DEFAULT_BUILD_FORMATS}
RUN_SETUP = ${DEFAULT_RUN_SETUP}
SUBMIT_BINARY = ${DEFAULT_SUBMIT_BINARY}
NODE_PACKAGE_MANAGER = ${DEFAULT_NODE_PACKAGE_MANAGER}
APP_VERSION_SOURCE = ${DEFAULT_APP_VERSION_SOURCE}
BUILD_LOGS = ${DEFAULT_BUILD_LOGS}
DEPLOYMENT_GROUP = ${DEFAULT_DEPLOYMENT_GROUP}

NOTES:
RELEASE_CHANNEL default is environment

OUTPUTS:
  context.properties
    - EXPO_OTA_URL - The base URL of the OTA producde from this task
    - EXPO_ARCHIVE_S3_URL - Path to the built OTA based on build rerference
    - BUILD_REFERENCE - The build reference for the current job
    - DEPLOYMENT_UNIT - The deployment unit the publish was run for
    - DEPLOYMENT_GROUP - The deployment group the deployment unit belongs to

EOF
    exit
}

function options() {

    # Parse options
    while getopts ":b:d:efg:hk:lmn:o:st:u:v:" opt; do
        case $opt in
        b)
            echo "-b has been deprecated and can be removed"
            ;;
        t)
            echo "-t has been deprecated and can be removed"
            ;;
        d)
            ENVIRONMENT_BADGE_CONTENT="${OPTARG}"
            ;;
        e)
            ENVIRONMENT_BADGE="true"
            ;;
        f)
            FORCE_BINARY_BUILD="true"
            ;;
        g)
            DEPLOYMENT_GROUP="${OPTARG}"
            ;;
        h)
            usage
            ;;
        k)
            KMS_PREFIX="${OPTARG}"
            ;;
        l)
            BUILD_LOGS="true"
            ;;
        m)
            SUBMIT_BINARY="true"
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
        s)
            RUN_SETUP="true"
            ;;
        v)
            APP_VERSION_SOURCE="${OPTARG}"
            ;;
        \?)
            fatalOption
            ;;
        :)
            fatalOptionArgument
            ;;
        esac
    done

    #Defaults
    if [[ -z "${EXPO_VERSION}" ]]; then
        EXPO_VERSION="$(npm info expo-cli --json | jq -r ".version")"
    fi
    EXPO_PACKAGE="expo-cli@${EXPO_VERSION}"

    RUN_SETUP="${RUN_SETUP:-DEFAULT_RUN_SETUP}"
    FORCE_BINARY_BUILD="${FORCE_BINARY_BUILD:-$DEFAULT_FORCE_BINARY_BUILD}"
    SUBMIT_BINARY="${SUBMIT_BINARY:-DEFAULT_SUBMIT_BINARY}"
    NODE_PACKAGE_MANAGER="${NODE_PACKAGE_MANAGER:-${DEFAULT_NODE_PACKAGE_MANAGER}}"
    APP_VERSION_SOURCE="${APP_VERSION_SOURCE:-${DEFAULT_APP_VERSION_SOURCE}}"
    BUILD_LOGS="${BUILD_LOGS:-${DEFAULT_BUILD_LOGS}}"
    KMS_PREFIX="${KMS_PREFIX:-${DEFAULT_KMS_PREFIX}}"
    DEPLOYMENT_GROUP="${DEPLOYMENT_GROUP:-${DEFAULT_DEPLOYMENT_GROUP}}"
    ENVIRONMENT_BADGE="${ENVIRONMENT_BADGE:-${DEFAULT_ENVIRONMENT_BADGE}}"

}

function main() {

    options "$@" || return $?

    if [[ "${RUN_SETUP}" == "true" ]]; then
        env_setup || return $?
    fi

    # Fastlane Standard config
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export FASTLANE_SKIP_UPDATE_CHECK="true"
    export FASTLANE_HIDE_CHANGELOG="true"
    export FASTLANE_HIDE_PLUGINS_TABLE="true"
    export FASTLANE_DISABLE_COLORS=1

    # Add android SDK tools to path
    export ANDROID_HOME=$HOME/Library/Android/sdk
    export PATH=$PATH:$ANDROID_HOME/emulator
    export PATH=$PATH:$ANDROID_HOME/tools
    export PATH=$PATH:$ANDROID_HOME/tools/bin
    export PATH=$PATH:$ANDROID_HOME/platform-tools

    # Ensure mandatory arguments have been provided
    check_for_invalid_environment_variables "DEPLOYMENT_UNIT" || return $?

    # Make sure the previous bundler has been stopped
    cleanup_bundler || (
        fatal "Can't shut down previous instance of the bundler"
        return 1
    )

    # Set data dir for builds
    WORKSPACE_DIR="${AUTOMATION_DATA_DIR:-$(getTempDir "cote_expo_XXXXX")}"

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
    mkdir -p "${REPORTS_PATH}"

    # Get config file
    CONFIG_BUCKET="$(jq -r '.Occurrence.State.Attributes.CONFIG_BUCKET' <"${BUILD_BLUEPRINT}")"
    CONFIG_KEY="$(jq -r '.Occurrence.State.Attributes.CONFIG_FILE' <"${BUILD_BLUEPRINT}")"
    CONFIG_FILE="${OPS_PATH}/config.json"

    ENVIRONMENT="$(jq -r '.Occurrence.Core.Environment.Name' <"${BUILD_BLUEPRINT}")"

    # Handle local region config
    placement_region="$(jq -r '.Occurrence.State.ResourceGroups.default.Placement.Region | select (.!=null)' <"${BUILD_BLUEPRINT}")"
    AWS_REGION="${AWS_REGION:-${placement_region}}"

    info "Getting configuration file from s3://${CONFIG_BUCKET}/${CONFIG_KEY}"
    aws --region "${AWS_REGION}" s3 cp --only-show-errors "s3://${CONFIG_BUCKET}/${CONFIG_KEY}" "${CONFIG_FILE}" || return $?

    # Operations data - Credentials, config etc.
    OPSDATA_BUCKET="$(jq -r '.BuildConfig.OPSDATA_BUCKET' <"${CONFIG_FILE}")"
    CREDENTIALS_PREFIX="$(jq -r '.BuildConfig.CREDENTIALS_PREFIX' <"${CONFIG_FILE}")"

    # The source of the prepared code repository zip
    SRC_BUCKET="$(jq -r '.BuildConfig.CODE_SRC_BUCKET' <"${CONFIG_FILE}")"
    SRC_PREFIX="$(jq -r '.BuildConfig.CODE_SRC_PREFIX' <"${CONFIG_FILE}")"

    APPDATA_BUCKET="$(jq -r '.BuildConfig.APPDATA_BUCKET' <"${CONFIG_FILE}")"
    EXPO_APPDATA_PREFIX="$(jq -r '.BuildConfig.APPDATA_PREFIX' <"${CONFIG_FILE}")"

    # Where the public artefacts will be published to
    PUBLIC_BUCKET="$(jq -r '.BuildConfig.OTA_ARTEFACT_BUCKET' <"${CONFIG_FILE}")"
    PUBLIC_PREFIX="$(jq -r '.BuildConfig.OTA_ARTEFACT_PREFIX' <"${CONFIG_FILE}")"
    PUBLIC_URL="$(jq -r '.BuildConfig.OTA_ARTEFACT_URL' <"${CONFIG_FILE}")"
    PUBLIC_ASSETS_PATH="assets"

    BUILD_FORMAT_LIST="$(jq -r '.BuildConfig.APP_BUILD_FORMATS' <"${CONFIG_FILE}")"
    arrayFromList BUILD_FORMATS "${BUILD_FORMAT_LIST}"

    BUILD_REFERENCE="$(jq -r '.BuildConfig.BUILD_REFERENCE' <"${CONFIG_FILE}")"
    BUILD_NUMBER="$(date +"%Y%m%d.1%H%M%S")"
    RELEASE_CHANNEL="$(jq -r '.BuildConfig.RELEASE_CHANNEL' <"${CONFIG_FILE}")"

    # Prepare the code build environment
    info "Getting source code from from s3://${SRC_BUCKET}/${SRC_PREFIX}/scripts.zip"
    aws --region "${AWS_REGION}" s3 cp --only-show-errors "s3://${SRC_BUCKET}/${SRC_PREFIX}/scripts.zip" "${tmpdir}/scripts.zip" || return $?

    unzip -q "${tmpdir}/scripts.zip" -d "${SRC_PATH}" || return $?

    cd "${SRC_PATH}" || { fatal "could not cd into ${SRC_PATH}"; return $?; }

    setup_fastlane_plugins "${SRC_PATH}" || return $?

    # Support the usual node package manager preferences
    case "${NODE_PACKAGE_MANAGER}" in
    "yarn")
        yarn install --production=false
        ;;

    "npm")
        npm ci
        ;;
    esac

    # Decrypt secrets from credentials store
    info "Getting credentials from s3://${OPSDATA_BUCKET}/${CREDENTIALS_PREFIX}"
    aws --region "${AWS_REGION}" s3 sync --only-show-errors "s3://${OPSDATA_BUCKET}/${CREDENTIALS_PREFIX}" "${OPS_PATH}" || return $?
    for i in "${OPS_PATH}"/*.kms; do decrypt_kms_file "${AWS_REGION}" "${i}"; done

    # Get the version of the expo SDK which is required
    EXPO_SDK_VERSION="$(jq -r '.expo.sdkVersion | select (.!=null)' <./app.json)"
    EXPO_PROJECT_SLUG="$(jq -r '.expo.slug' <./app.json)"

    case "${APP_VERSION_SOURCE}" in
    "manifest")
        EXPO_APP_VERSION="$(jq -r '.expo.version' <./app.json)"
        ;;

    "cmdb")
        EXPO_APP_VERSION="$(jq -r '.BuildConfig.APP_REFERENCE |  select (.!=null)' <"${CONFIG_FILE}")"
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

    # Define an archive based on build references to allow for source map replays and troubleshooting
    EXPO_ARCHIVE_S3_URL="s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/archive/${BUILD_REFERENCE}/"

    # Make details available for downstream jobs
    save_context_property "EXPO_ARCHIVE_S3_URL" "${EXPO_ARCHIVE_S3_URL}"
    save_context_property "BUILD_REFERENCE" "${BUILD_REFERENCE}"
    save_context_property "DEPLOYMENT_UNIT" "${DEPLOYMENT_UNIT}"
    save_context_property "DEPLOYMENT_GROUP" "${DEPLOYMENT_GROUP}"

    # Update the app.json with build context information - Also ensure we always have a unique IOS build number
    # filter out the credentials used for the build process
    jq --slurpfile envConfig "${CONFIG_FILE}" \
        --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" \
        --arg BUILD_REFERENCE "${BUILD_REFERENCE}" \
        --arg BUILD_NUMBER "${BUILD_NUMBER}" \
        '.expo.releaseChannel=$RELEASE_CHANNEL | .expo.extra.BUILD_REFERENCE=$BUILD_REFERENCE | .expo.ios.buildNumber=$BUILD_NUMBER | .expo.extra=.expo.extra + $envConfig[]["AppConfig"]' <"./app.json" >"${tmpdir}/environment-app.json"
    mv "${tmpdir}/environment-app.json" "./app.json"

    # Optional app.json overrides
    IOS_DIST_BUNDLE_ID="$(jq -r '.BuildConfig.IOS_DIST_BUNDLE_ID' <"${CONFIG_FILE}")"
    if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
        jq --arg IOS_DIST_BUNDLE_ID "${IOS_DIST_BUNDLE_ID}" '.expo.ios.bundleIdentifier=$IOS_DIST_BUNDLE_ID' <"./app.json" >"${tmpdir}/ios-bundle-app.json"
        mv "${tmpdir}/ios-bundle-app.json" "./app.json"
    fi

    # Override support for the display name used on the app
    get_configfile_property "${CONFIG_FILE}" "IOS_DIST_DISPLAY_NAME" "${KMS_PREFIX}" "${AWS_REGION}"

    # IOS Non Exempt Encryption
    get_configfile_property "${CONFIG_FILE}" "IOS_DIST_NON_EXEMPT_ENCRYPTION" "${KMS_PREFIX}" "${AWS_REGION}"
    IOS_DIST_NON_EXEMPT_ENCRYPTION="${IOS_DIST_NON_EXEMPT_ENCRYPTION:-${DEFAULT_IOS_DIST_NON_EXEMPT_ENCRYPTION}}"

    jq --arg IOS_NON_EXEMPT_ENCRYPTION "${IOS_DIST_NON_EXEMPT_ENCRYPTION}" '.expo.ios.config.usesNonExemptEncryption=($IOS_NON_EXEMPT_ENCRYPTION | test("true"))' <"./app.json" >"${tmpdir}/ios-encexempt-app.json"
    mv "${tmpdir}/ios-encexempt-app.json" "./app.json"

    ANDROID_DIST_BUNDLE_ID="$(jq -r '.BuildConfig.ANDROID_DIST_BUNDLE_ID' <"${CONFIG_FILE}")"
    if [[ "${ANDROID_DIST_BUNDLE_ID}" != "null" && -n "${ANDROID_DIST_BUNDLE_ID}" ]]; then
        jq --arg ANDROID_DIST_BUNDLE_ID "${ANDROID_DIST_BUNDLE_ID}" '.expo.android.package=$ANDROID_DIST_BUNDLE_ID' <"./app.json" >"${tmpdir}/android-bundle-app.json"
        mv "${tmpdir}/android-bundle-app.json" "./app.json"
    fi

    # Create base OTA
    info "Creating an OTA | App Version: ${EXPO_APP_MAJOR_VERSION} | OTA Version: ${OTA_VERSION} | expo-cli Version: ${EXPO_VERSION} | Expo SDK Version: ${EXPO_SDK_MAJOR_VERSION}"
    EXPO_VERSION_PUBLIC_URL="${PUBLIC_URL}/packages/${EXPO_APP_MAJOR_VERSION}/${OTA_VERSION}"

    if [[ "${EXPO_SDK_MAJOR_VERSION}" -gt "45" ]]; then
        expo_npx_base_args=()
        expo_url_args=()
    else
        expo_npx_base_args=("${npx_base_args[@]}" "--package" "${EXPO_PACKAGE}")
        expo_url_args=("--public-url" "${EXPO_VERSION_PUBLIC_URL}" "--asset-url" "${PUBLIC_ASSETS_PATH}")
    fi

    yes | npx "${expo_npx_base_args[@]}" expo export "${expo_url_args[@]}" --dump-sourcemap --dump-assetmap --output-dir "${SRC_PATH}/app/dist/build/${OTA_VERSION}" || return $?

    if [[ "${EXPO_SDK_MAJOR_VERSION}" -lt "45" ]]; then

        EXPO_ID_OVERRIDE="$(jq -r '.BuildConfig.EXPO_ID_OVERRIDE' <"${CONFIG_FILE}")"
        if [[ "${EXPO_ID_OVERRIDE}" != "null" && -n "${EXPO_ID_OVERRIDE}" ]]; then

            jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' <"${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json" >"${tmpdir}/ios-expo-override.json"
            mv "${tmpdir}/ios-expo-override.json" "${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json"

            jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' <"${SRC_PATH}/app/dist/build/${OTA_VERSION}/android-index.json" >"${tmpdir}/android-expo-override.json"
            mv "${tmpdir}/android-expo-override.json" "${SRC_PATH}/app/dist/build/${OTA_VERSION}/android-index.json"

        fi

        if [[ -n "${BUILD_REFERENCE}" ]]; then
            info "Override revisionId to match the build reference ${BUILD_REFERENCE}"
            jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' <"${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json" >"${tmpdir}/ios-expo-override.json"
            mv "${tmpdir}/ios-expo-override.json" "${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json"

            jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' <"${SRC_PATH}/app/dist/build/${OTA_VERSION}/android-index.json" >"${tmpdir}/android-expo-override.json"
            mv "${tmpdir}/android-expo-override.json" "${SRC_PATH}/app/dist/build/${OTA_VERSION}/android-index.json"
        fi
    fi

    info "Copying OTA to CDN"
    aws --region "${AWS_REGION}" s3 sync --only-show-errors --delete "${SRC_PATH}/app/dist/build/${OTA_VERSION}" "s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/packages/${EXPO_APP_MAJOR_VERSION}/${OTA_VERSION}" || return $?

    info "Creating archive copy based on build reference ${BUILD_REFERENCE}"
    aws --region "${AWS_REGION}" s3 sync --only-show-errors --delete "${SRC_PATH}/app/dist/build/${OTA_VERSION}" "${EXPO_ARCHIVE_S3_URL}" || return $?

    # Support using prebuild service or require that ejected directorries exist
    if [[ ! -d "${SRC_PATH}/ios" && ! -d "${SRC_PATH}/android" ]]; then
        if [[ "${EXPO_SDK_MAJOR_VERSION}" -gt "45" ]]; then
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
            npx expo prebuild "${expo_prebuild_args[@]}" || return $?
        else
            fatal "Native folders could not be found for mobile builds ensure android and ios dirs exist"
            return 1
        fi
    fi

    # Add a shield to the App icons with the environment for the app
    if [[ "${ENVIRONMENT_BADGE}" == "true" ]]; then
        BADGE_CONTENT="${ENVIRONMENT_BADGE_CONTENT:-${ENVIRONMENT}}"
        badge_args=("shield:${BADGE_CONTENT}-blue" "shield_scale:0.5" "no_badge;true" "shield_gravity:South" "shield_parameters:style=flat")

        # iOS is the default pattern to match
        bundle exec fastlane run add_badge "${badge_args[@]}" "shield_geometry:+0+5%"
        # Android search path
        bundle exec fastlane run add_badge "${badge_args[@]}" "shield_geometry:+0+20%" "glob:/**/src/main/res/mipmap-*/ic_launcher*.png"
    fi

    for build_format in "${BUILD_FORMATS[@]}"; do

        BINARY_FILE_PREFIX="${build_format}"

        if [[ "${EXPO_SDK_MAJOR_VERSION}" -gt "45" ]]; then
            EXPO_MANIFEST_URL="${EXPO_VERSION_PUBLIC_URL}/metadata.json"
        else
            EXPO_MANIFEST_URL="${EXPO_VERSION_PUBLIC_URL}/${build_format}-index.json"
        fi

        case "${build_format}" in
        "android")
            BINARY_FILE_EXTENSION="apk"

            export ANDROID_DIST_KEYSTORE_FILE="${OPS_PATH}/android_keystore.jks"

            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEYSTORE_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEY_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_KEY_ALIAS" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "ANDROID_PLAYSTORE_JSON_KEY" "${KMS_PREFIX}" "${AWS_REGION}"

            get_configfile_property "${CONFIG_FILE}" "ANDROID_DIST_FIREBASE_APP_ID" "${KMS_PREFIX}" "${AWS_REGION}"
            FIREBASE_JSON_KEY_FILE="${OPS_PATH}/firebase_json_key.json"
            ;;

        "ios")
            BINARY_FILE_EXTENSION="ipa"

            export IOS_DIST_PROVISIONING_PROFILE_BASE="ios_profile"
            export IOS_DIST_PROVISIONING_PROFILE_EXTENSION=".mobileprovision"
            export IOS_DIST_PROVISIONING_PROFILE="${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"
            export IOS_DIST_P12_FILE="${OPS_PATH}/ios_distribution.p12"

            # Get properties from retrieved config file and decrypt if required
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_APPLE_ID" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_APP_ID" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_EXPORT_METHOD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_TESTFLIGHT_USERNAME" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_TESTFLIGHT_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_P12_PASSWORD" "${KMS_PREFIX}" "${AWS_REGION}"
            get_configfile_property "${CONFIG_FILE}" "IOS_DIST_CODESIGN_IDENTITY" "${KMS_PREFIX}" "${AWS_REGION}"

            # Setting Defaults
            IOS_DIST_CODESIGN_IDENTITY="${IOS_DIST_CODESIGN_IDENTITY:-${DEFAULT_IOS_DIST_CODESIGN_IDENTITY}}"
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
            FASTLANE_IOS_PROJECT_FILE="ios/${EXPO_PROJECT_SLUG}.xcodeproj"
            FASTLANE_IOS_WORKSPACE_FILE="ios/${EXPO_PROJECT_SLUG}.xcworkspace"
            FASTLANE_IOS_PODFILE="ios/Podfile"

            # Update App details
            # Pre SDK37, Expokit maintained an Info.plist in Supporting
            INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Supporting/Info.plist"
            [[ ! -e "ios/${INFO_PLIST_PATH}" ]] && INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Info.plist"
            bundle exec fastlane run set_info_plist_value path:"ios/${INFO_PLIST_PATH}" key:CFBundleVersion value:"${BUILD_NUMBER}" || return $?
            bundle exec fastlane run set_info_plist_value path:"ios/${INFO_PLIST_PATH}" key:CFBundleShortVersionString value:"${EXPO_APP_VERSION}" || return $?

            if [[ "${IOS_DIST_NON_EXEMPT_ENCRYPTION}" == "false" ]]; then
                IOS_USES_NON_EXEMPT_ENCRYPTION="NO"
            else
                IOS_USES_NON_EXEMPT_ENCRYPTION="YES"
            fi
            bundle exec fastlane run set_info_plist_value path:"ios/${INFO_PLIST_PATH}" key:ITSAppUsesNonExemptEncryption value:"${IOS_USES_NON_EXEMPT_ENCRYPTION}" || return $?

            if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
                pushd ios || { fatal "could not change to ios dir"; return $?; }
                bundle exec fastlane run update_app_identifier app_identifier:"${IOS_DIST_BUNDLE_ID}" xcodeproj:"${EXPO_PROJECT_SLUG}.xcodeproj" plist_path:"${INFO_PLIST_PATH}" || return $?
                popd || return $?
            fi

            if [[ "${IOS_DIST_DISPLAY_NAME}" != "null" && -n "${IOS_DIST_DISPLAY_NAME}" ]]; then
                pushd ios || { fatal "could not change to ios dir"; return $?; }
                bundle exec fastlane run update_info_plist display_name:"${IOS_DIST_DISPLAY_NAME}" xcodeproj:"${EXPO_PROJECT_SLUG}.xcodeproj" plist_path:"${INFO_PLIST_PATH}" || return $?
                popd || return $?
            fi

            if [[ -e "${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" ]]; then
                # Bare workflow support (SDK 37+)

                # Updates URL
                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesURL value:"${EXPO_MANIFEST_URL}" || return $?

                # SDK Version
                if [[ -n "${EXPO_SDK_VERSION}" ]]; then
                    bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesSDKVersion value:"${EXPO_SDK_VERSION}" || return $?
                fi

                # Release channel
                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesReleaseChannel value:"${RELEASE_CHANNEL}" || return $?

                # Check for updates
                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesCheckOnLaunch value:"ALWAYS" || return $?

                # Wait up to 10s for updates to download
                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesLaunchWaitMs value:"10000" || return $?

            else
                # Legacy Expokit support
                # Update Expo Details and seed with latest expo bundles
                BINARY_BUNDLE_FILE="${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/shell-app-manifest.json"
                cp "${SRC_PATH}/app/dist/build/${OTA_VERSION}/ios-index.json" "${BINARY_BUNDLE_FILE}"

                # Get the bundle file name from the manifest
                BUNDLE_URL="$(jq -r '.bundleUrl' <"${BINARY_BUNDLE_FILE}")"
                BUNDLE_FILE_NAME="$(basename "${BUNDLE_URL}")"

                cp "${SRC_PATH}/app/dist/build/${OTA_VERSION}/bundles/${BUNDLE_FILE_NAME}" "${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/shell-app.bundle"

                jq --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" --arg MANIFEST_URL "${EXPO_MANIFEST_URL}" '.manifestUrl=$MANIFEST_URL | .releaseChannel=$RELEASE_CHANNEL' <"ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json" >"${tmpdir}/EXShell.json"
                mv "${tmpdir}/EXShell.json" "ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json"

                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:manifestUrl value:"${EXPO_MANIFEST_URL}" || return $?
                bundle exec fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:releaseChannel value:"${RELEASE_CHANNEL}" || return $?
            fi

            # Keychain setup - Create a temporary keychain
            bundle exec fastlane run create_keychain path:"${FASTLANE_KEYCHAIN_PATH}" password:"${FASTLANE_KEYCHAIN_NAME}" add_to_search_list:"true" unlock:"true" timeout:3600 || return $?

            # Codesigning setup
            bundle exec fastlane run import_certificate certificate_path:"${OPS_PATH}/ios_distribution.p12" certificate_password:"${IOS_DIST_P12_PASSWORD}" keychain_path:"${FASTLANE_KEYCHAIN_PATH}" keychain_password:"${FASTLANE_KEYCHAIN_NAME}" log_output:"true" || return $?
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
            for PROFILE in "${OPS_PATH}"/"${IOS_DIST_PROVISIONING_PROFILE_BASE}"*"${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"; do
                TARGET="${PROFILE%"${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"}"
                TARGET="${TARGET#"${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}"}"
                # Ignore the app provisioning profile
                [[ -z "${TARGET}" ]] && continue
                # Update the extension target
                TARGET="${TARGET#_}"
                echo "Updating target ${TARGET} ..."
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

            update_podfile_signing "${FASTLANE_IOS_PODFILE}"

            if [[ "${BUILD_LOGS}" == "true" ]]; then
                FASTLANE_IOS_SILENT="false"
            else
                FASTLANE_IOS_SILENT="true"
            fi

            # Build App
            bundle exec fastlane run cocoapods silent:"${FASTLANE_IOS_SILENT}" podfile:"${FASTLANE_IOS_PODFILE}" try_repo_update_on_error:"true" || return $?
            bundle exec fastlane run build_ios_app suppress_xcode_output:"${FASTLANE_IOS_SILENT}" silent:"${FASTLANE_IOS_SILENT}" workspace:"${FASTLANE_IOS_WORKSPACE_FILE}" output_directory:"${BINARY_PATH}" output_name:"${EXPO_BINARY_FILE_NAME}" export_method:"${IOS_DIST_EXPORT_METHOD}" codesigning_identity:"${CODESIGN_IDENTITY}" include_symbols:"true" include_bitcode:"true" || return $?
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
                info "Updating google services ${OPS_PATH}/google-services.json -> ${SRC_PATH}/android/app/google-services.json"
                cp "${OPS_PATH}/google-services.json" "${SRC_PATH}/android/app/google-services.json"
            fi

            if [[ -e "${SRC_PATH}/android/app/src/main/AndroidManifest.xml" ]]; then

                # Update Expo Details
                manifest_content="$(cat "${SRC_PATH}/android/app/src/main/AndroidManifest.xml")"

                # Update Url
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATE_URL" "${EXPO_MANIFEST_URL}")"

                # Sdk Version
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_SDK_VERSION" "${EXPO_SDK_VERSION}")"

                # Check for updates
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATES_CHECK_ON_LAUNCH" "ALWAYS")"

                # Check for updates
                manifest_content="$(set_android_manifest_property "${manifest_content}" "expo.modules.updates.EXPO_UPDATES_LAUNCH_WAIT_MS" "10000")"

                if [[ -n "${manifest_content}" ]]; then
                    echo "${manifest_content}" >"${SRC_PATH}/android/app/src/main/AndroidManifest.xml"
                else
                    error "Couldn't update manifest details for expo Updates"
                    exit 128
                fi

                gradle_args="--console=plain"
                if [[ "${BUILD_LOGS}" == "false" ]]; then
                    gradle_args="${gradle_args} --quiet"
                fi

                # Run the react build
                cd "${SRC_PATH}/android" || { fatal "Could not change to android src dir"; return $?; }
                ./gradlew "${gradle_args}" -I "${GENERATION_BASE_DIR}/execution/expoAndroidSigning.gradle" assembleRelease || return $?
                cd "${SRC_PATH}" || { fatal "Could not change to src dir"; return $?; }

                if [[ -f "${SRC_PATH}/android/app/build/outputs/apk/release/app-release.apk" ]]; then
                    cp "${SRC_PATH}/android/app/build/outputs/apk/release/app-release.apk" "${EXPO_BINARY_FILE_PATH}"
                else
                    error "Could not find android build file"
                    return 128
                fi
            fi
        fi

        if [[ -f "${EXPO_BINARY_FILE_PATH}" ]]; then
            aws --region "${AWS_REGION}" s3 sync --only-show-errors --exclude "*" --include "${BINARY_FILE_PREFIX}*" "${BINARY_PATH}" "s3://${APPDATA_BUCKET}/${EXPO_APPDATA_PREFIX}/" || return $?

            if [[ "${SUBMIT_BINARY}" == "true" ]]; then
                case "${build_format}" in
                "ios")

                    # Ensure mandatory arguments have been provided
                    if [[ -z "${IOS_TESTFLIGHT_USERNAME}" || -z "${IOS_TESTFLIGHT_PASSWORD}" || -z "${IOS_DIST_APP_ID}" ]]; then
                        warning "IOS - TestFlight details not found please provide IOS_TESTFLIGHT_USERNAME, IOS_TESTFLIGHT_PASSWORD and IOS_DIST_APP_ID - Skipping push"
                        continue
                    fi

                    info "Submitting IOS binary to testflight"
                    export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="${IOS_TESTFLIGHT_PASSWORD}"
                    bundle exec fastlane run upload_to_testflight skip_waiting_for_build_processing:true apple_id:"${IOS_DIST_APP_ID}" ipa:"${EXPO_BINARY_FILE_PATH}" username:"${IOS_TESTFLIGHT_USERNAME}" || return $?
                    ;;

                "android")
                    if [[ -n "${ANDROID_PLAYSTORE_JSON_KEY}" ]]; then
                        info "Submitting android build to play store"
                        bundle exec fastlane run upload_to_play_store apk:"${EXPO_BINARY_FILE_PATH}" track:"beta" json_key_data:"${ANDROID_PLAYSTORE_JSON_KEY}"
                    fi

                    if [[ -f "${FIREBASE_JSON_KEY_FILE}" ]]; then
                        info "Submitting android build to firebase"
                        bundle exec fastlane run firebase_app_distribution app:"${ANDROID_DIST_FIREBASE_APP_ID}" service_credentials_file:"${FIREBASE_JSON_KEY_FILE}" apk_path:"${EXPO_BINARY_FILE_PATH}"
                    fi
                    ;;
                esac
            fi
        fi

    done

    save_context_property EXPO_OTA_URL "${EXPO_VERSION_PUBLIC_URL}"

    # All good
    return 0
}

main "$@" || exit $?
