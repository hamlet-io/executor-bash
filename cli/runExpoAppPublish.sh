#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}

trim() {
    local var="$1"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    echo $var
}

function cleanup_bundler {

    # Make sure the metro bundler isn't left running
    # It will work the first time but as the workspace is
    # deleted each time, it will then be running in a deleted directory
    # and fail every time
    BUNDLER_PID=$(trim $(lsof -i :8081 -t))
    if [[ -n "${BUNDLER_PID}" ]]; then
        BUNDLER_PARENT=$(trim $(ps -o ppid= ${BUNDLER_PID}))
        echo "Bundler found, pid=${BUNDLER_PID}, ppid=${BUNDLER_PARENT} ..."
        if [[ -n "${BUNDLER_PID}" && (${BUNDLER_PID} != 1) ]]; then
            echo "Killing bundler, pid=${BUNDLER_PID} ..."
            kill -9 "${BUNDLER_PID}" || return $?
        fi
        if [[ -n "${BUNDLER_PARENT}"  && (${BUNDLER_PARENT} != 1) ]]; then
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
    	for f in ${OPS_PATH}/*.keychain; do
        	echo "Deleting keychain ${f} ..."
	        security delete-keychain "${f}"
        done
    fi

    # Make sure the bundler is shut down
    cleanup_bundler

    # normal context cleanup
    . ${GENERATION_BASE_DIR}/execution/cleanupContext.sh

}
trap cleanup EXIT SIGHUP SIGINT SIGTERM

. "${GENERATION_BASE_DIR}/execution/common.sh"

#Defaults
DEFAULT_EXPO_VERSION="3.20.1"
DEFAULT_TURTLE_VERSION="0.14.11"
DEFAULT_BINARY_EXPIRATION="1210000"

DEFAULT_RUN_SETUP="false"
DEFAULT_FORCE_BINARY_BUILD="false"
DEFAULT_SUBMIT_BINARY="false"
DEFAULT_DISABLE_OTA="false"

DEFAULT_QR_BUILD_FORMATS="ios,android"
DEFAULT_BINARY_BUILD_PROCESS="turtle"

DEFAULT_NODE_PACKAGE_MANAGER="yarn"

DEFAULT_APP_VERSION_SOURCE="manifest"

export FASTLANE_SKIP_UPDATE_CHECK="true"
export FASTLANE_HIDE_CHANGELOG="true"

tmpdir="$(getTempDir "cote_inf_XXX")"

# Get the generation context so we can run template generation
. "${GENERATION_BASE_DIR}/execution/setContext.sh"

function decrypt_kms_file() {
    local region="$1"; shift
    local encrypted_file_path="$1"; shift

    base64 --decode < "${encrypted_file_path}" > "${encrypted_file_path}.base64"
    BASE64_CLEARTEXT_VALUE="$(aws --region ${region} kms decrypt --ciphertext-blob "${encrypted_file_path}.base64"  --output text --query Plaintext)"
    echo "${BASE64_CLEARTEXT_VALUE}" | base64 --decode > "${encrypted_file_path%".kms"}"
    rm -rf "${encrypted_file_path}.base64"

    if [[ -e "${encrypted_file_path%".kms"}" ]]; then
        return 0
    else
        error "could not decrypt file ${encrypted_file_path}"
        return 128
    fi
}

function env_setup() {

    # hombrew install
    brew upgrade || return $?
    brew install \
        jq \
        yarn \
        python || return $?

    brew cask upgrade || return $?
    brew cask install \
        fastlane || return $?

    # Make sure we have required software installed
    pip3 install \
        qrcode[pil] \
        awscli || return $?

    # yarn install
    yarn global add \
        expo-cli@"${EXPO_VERSION}" \
        turtle-cli@"${DEFAULT_TURTLE_VERSION}" || return $?
}

function usage() {
    cat <<EOF

Run a task based build of an Expo app binary

Usage: $(basename $0) -u DEPLOYMENT_UNIT -i INPUT_PAYLOAD -l INCLUDE_LOG_TAIL

where

    -h                        shows this text
(m) -u DEPLOYMENT_UNIT        is the mobile app deployment unit
(o) -s RUN_SETUP              run setup installation to prepare
(o) -t BINARY_EXPIRATION      how long presigned urls are active for once created ( seconds )
(o) -f FORCE_BINARY_BUILD     force the build of binary images
(o) -n NODE_PACKAGE_MANAGER   Set the node package manager for app installation
(o) -m SUBMIT_BINARY          submit the binary for testing
(o) -o DISABLE_OTA            don't publish the OTA to the CDN
(o) -b BINARY_BUILD_PROCESS   sets the build process to create the binary
(0) -q QR_BUILD_FORMATS       specify the formats you would like to generate QR urls for
(o) -v APP_VERSION_SOURCE     sets what to use for the app version ( cmdb | manifest)

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:
BINARY_EXPIRATION = ${DEFAULT_BINARY_EXPIRATION}
BUILD_FORMATS = ${DEFAULT_BUILD_FORMATS}
BINARY_EXPIRATION = ${DEFAULT_BINARY_EXPIRATION}
RUN_SETUP = ${DEFAULT_RUN_SETUP}
SUBMIT_BINARY = ${DEFAULT_SUBMIT_BINARY}
DISABLE_OTA  = ${DEPLOY_OTA}
QR_BUILD_FORMATS = ${DEFAULT_QR_BUILD_FORMATS}
BINARY_BUILD_PROCESS = ${DEFAULT_BINARY_BUILD_PROCESS}
NODE_PACKAGE_MANAGER = ${DEFAULT_NODE_PACKAGE_MANAGER}
APP_VERSION_SOURCE = ${DEFAULT_APP_VERSION_SOURCE}

NOTES:
RELEASE_CHANNEL default is environment

EOF
    exit
}

function options() {

    # Parse options
    while getopts ":bfhmsq:t:u:v:" opt; do
        case $opt in
            b)
                BINARY_BUILD_PROCESS="${OPTARG}"
                ;;
            f)
                FORCE_BINARY_BUILD="true"
                ;;
            h)
                usage
                ;;
            m)
                SUBMIT_BINARY="true"
                ;;
            n)
                NODE_PACKAGE_MANAGER="${OPTARG}"
                ;;
            o)
                DISABLE_OTA="true"
                ;;
            u)
                DEPLOYMENT_UNIT="${OPTARG}"
                ;;
            q)
                QR_BUILD_FORMATS="${OPTARG}"
                ;;
            s)
                RUN_SETUP="true"
                ;;
            t)
                BINARY_EXPIRATION="${OPTARG}"
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
    RUN_SETUP="${RUN_SETUP:-DEFAULT_RUN_SETUP}"
    EXPO_VERSION="${EXPO_VERSION:-$DEFAULT_EXPO_VERSION}"
    BINARY_EXPIRATION="${BINARY_EXPIRATION:-$DEFAULT_BINARY_EXPIRATION}"
    FORCE_BINARY_BUILD="${FORCE_BINARY_BUILD:-$DEFAULT_FORCE_BINARY_BUILD}"
    SUBMIT_BINARY="${SUBMIT_BINARY:-DEFAULT_SUBMIT_BINARY}"
    QR_BUILD_FORMATS="${QR_BUILD_FORMATS:-$DEFAULT_QR_BUILD_FORMATS}"
    BINARY_BUILD_PROCESS="${BINARY_BUILD_PROCESS:-$DEFAULT_BINARY_BUILD_PROCESS}"
    DISABLE_OTA="${DISABLE_OTA:-${DEFAULT_DISABLE_OTA}}"
    NODE_PACKAGE_MANAGER="${NODE_PACKAGE_MANAGER:-${DEFAULT_NODE_PACKAGE_MANAGER}}"
    APP_VERSION_SOURCE="${APP_VERSION_SOURCE:-${DEFAULT_APP_VERSION_SOURCE}}"
}


function main() {

  options "$@" || return $?

  if [[ "${RUN_SETUP}" == "true" ]]; then
    env_setup || return $?
  fi

   # make sure fastlane is on path
   export PATH="$HOME/.fastlane/bin:$PATH"

  # Ensure mandatory arguments have been provided
  [[ -z "${DEPLOYMENT_UNIT}" ]] && fatalMandatory && return 1

  # Make sure the previous bundler has been stopped
  cleanup_bundler ||
  { fatal "Can't shut down previous instance of the bundler"; return 1; }

  # Create build blueprint
  info "Generating build blueprint..."
  "${GENERATION_DIR}/createBuildblueprint.sh" -u "${DEPLOYMENT_UNIT}" -o "${AUTOMATION_DATA_DIR}" >/dev/null || return $?

  BUILD_BLUEPRINT="${AUTOMATION_DATA_DIR}/build_blueprint-${DEPLOYMENT_UNIT}-config.json"

  # Make sure we are in the build source directory
  BINARY_PATH="${AUTOMATION_DATA_DIR}/binary"
  SRC_PATH="${AUTOMATION_DATA_DIR}/src"
  OPS_PATH="${AUTOMATION_DATA_DIR}/ops"
  REPORTS_PATH="${AUTOMATION_DATA_DIR}/reports"

  mkdir -p "${BINARY_PATH}"
  mkdir -p "${SRC_PATH}"
  mkdir -p "${OPS_PATH}"
  mkdir -p "${REPORTS_PATH}"

  # get config file
  CONFIG_BUCKET="$( jq -r '.Occurrence.State.Attributes.CONFIG_BUCKET' < "${BUILD_BLUEPRINT}" )"
  CONFIG_KEY="$( jq -r '.Occurrence.State.Attributes.CONFIG_FILE' < "${BUILD_BLUEPRINT}" )"
  CONFIG_FILE="${OPS_PATH}/config.json"

  info "Gettting configuration file from s3://${CONFIG_BUCKET}/${CONFIG_KEY}"
  aws --region "${AWS_REGION}" s3 cp --no-progress "s3://${CONFIG_BUCKET}/${CONFIG_KEY}" "${CONFIG_FILE}" || return $?

  # Operations data - Credentials, config etc.
  OPSDATA_BUCKET="$( jq -r '.BuildConfig.OPSDATA_BUCKET' < "${CONFIG_FILE}" )"
  CREDENTIALS_PREFIX="$( jq -r '.BuildConfig.CREDENTIALS_PREFIX' < "${CONFIG_FILE}" )"

  # The source of the prepared code repository zip
  SRC_BUCKET="$( jq -r '.BuildConfig.CODE_SRC_BUCKET' < "${CONFIG_FILE}" )"
  SRC_PREFIX="$( jq -r '.BuildConfig.CODE_SRC_PREFIX' < "${CONFIG_FILE}" )"

  APPDATA_BUCKET="$( jq -r '.BuildConfig.APPDATA_BUCKET' < "${CONFIG_FILE}" )"
  EXPO_APPDATA_PREFIX="$( jq -r '.BuildConfig.APPDATA_PREFIX' < "${CONFIG_FILE}" )"

  # Where the public artefacts will be published to
  PUBLIC_BUCKET="$( jq -r '.BuildConfig.OTA_ARTEFACT_BUCKET' < "${CONFIG_FILE}" )"
  PUBLIC_PREFIX="$( jq -r '.BuildConfig.OTA_ARTEFACT_PREFIX' < "${CONFIG_FILE}" )"
  PUBLIC_URL="$( jq -r '.BuildConfig.OTA_ARTEFACT_URL' < "${CONFIG_FILE}" )"

  BUILD_FORMAT_LIST="$( jq -r '.BuildConfig.APP_BUILD_FORMATS' < "${CONFIG_FILE}" )"
  arrayFromList BUILD_FORMATS "${BUILD_FORMAT_LIST}"

  BUILD_REFERENCE="$( jq -r '.BuildConfig.BUILD_REFERENCE' <"${CONFIG_FILE}" )"
  BUILD_NUMBER="$(date +"%Y%m%d.1%H%M%S")"
  RELEASE_CHANNEL="$( jq -r '.BuildConfig.RELEASE_CHANNEL' <"${CONFIG_FILE}" )"

  arrayFromList EXPO_QR_BUILD_FORMATS "${QR_BUILD_FORMATS}"

  BUILD_BINARY="false"

  TURTLE_EXTRA_BUILD_ARGS="--release-channel ${RELEASE_CHANNEL}"

  # Prepare the code build environment
  info "Getting source code from from s3://${SRC_BUCKET}/${SRC_PREFIX}/scripts.zip"
  aws --region "${AWS_REGION}" s3 cp --no-progress "s3://${SRC_BUCKET}/${SRC_PREFIX}/scripts.zip" "${tmpdir}/scripts.zip" || return $?

  unzip -q "${tmpdir}/scripts.zip" -d "${SRC_PATH}" || return $?

  cd "${SRC_PATH}"

  # Support the usual node package manager preferences
  case "${NODE_PACKAGE_MANAGER}" in
    "yarn")
        yarn install --production=false
        ;;

    "npm")
        npm ci
        ;;
  esac

  # decrypt secrets from credentials store
  info "Getting credentials from s3://${OPSDATA_BUCKET}/${CREDENTIALS_PREFIX}"
  aws --region "${AWS_REGION}" s3 sync --no-progress "s3://${OPSDATA_BUCKET}/${CREDENTIALS_PREFIX}" "${OPS_PATH}" || return $?
  find "${OPS_PATH}" -name \*.kms -exec decrypt_kms_file "${AWS_REGION}" "{}" \;

  # get the version of the expo SDK which is required
  EXPO_SDK_VERSION="$(jq -r '.expo.sdkVersion' < ./app.json)"
  EXPO_PROJECT_SLUG="$(jq -r '.expo.slug' < ./app.json)"

  case "${APP_VERSION_SOURCE}" in
    "manfiest")
        EXPO_APP_VERSION="$(jq -r '.expo.version' < ./app.json)"
        ;;

    "cmdb")
        EXPO_APP_VERSION="$( jq -r '.BuildConfig.APP_REFERENCE |  select (.!=null)' <"${CONFIG_FILE}" )"
        [[ -z "${APP_REFERENCE}" ]] && APP_REFERENCE="0.0.1"
        EXPO_APP_VERSION="${APP_REFERENCE#v}"
        ;;

    *)
        fatal "Invalid APP_VERSION_SOURCE - ${APP_VERSION_SOURCE}" && exit 255
        ;;
   esac
   EXPO_CURRENT_APP_VERSION="${EXPO_APP_VERSION}"

  # Determine Binary Build status
  EXPO_CURRENT_SDK_BUILD="$(aws s3api list-objects-v2 --bucket "${PUBLIC_BUCKET}" --prefix "${PUBLIC_PREFIX}/packages/${EXPO_SDK_VERSION}" --query "join(',', Contents[*].Key)" --output text)"
  arrayFromList EXPO_CURRENT_SDK_FILES "${EXPO_CURRENT_SDK_BUILD}"

  # Determine if App Version has been incremented
  if [[ -n "${EXPO_CURRENT_SDK_BUILD}" ]]; then
    for sdk_file in "${EXPO_CURRENT_SDK_FILES[@]}" ; do
        if [[ "${sdk_file}" == */${BUILD_FORMATS[0]}-index.json ]]; then
            aws --region "${AWS_REGION}" s3 cp --no-progress "s3://${PUBLIC_BUCKET}/${sdk_file}" "${AUTOMATION_DATA_DIR}/current-app-manifest.json"
            break
        fi
    done

    if [[ -f "${AUTOMATION_DATA_DIR}/current-app-manifest.json" ]]; then
        EXPO_CURRENT_APP_VERSION="$(jq -r '.version' < "${AUTOMATION_DATA_DIR}/current-app-manifest.json" )"
        EXPO_CURRENT_APP_REVISION_ID="$(jq -r '.revisionId' < "${AUTOMATION_DATA_DIR}/current-app-manifest.json" )"
    fi
  fi

  # If not built before, or the app version has changed, or forced to, build the binary
  if [[ -z "${EXPO_CURRENT_SDK_BUILD}" || "${FORCE_BINARY_BUILD}" == "true" || "${EXPO_CURRENT_APP_VERSION}" != "${EXPO_APP_VERSION}" ]]; then
    BUILD_BINARY="true"
  fi

  # variable for sentry source map upload
  SENTRY_SOURCE_MAP_S3_URL="s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/packages/${EXPO_SDK_VERSION}"
  echo "SENTRY_SOURCE_MAP_S3_URL=${SENTRY_SOURCE_MAP_S3_URL}" >> ${AUTOMATION_DATA_DIR}/chain.properties
  echo "SENTRY_URL_PREFIX=~/${PUBLIC_PREFIX}" >> ${AUTOMATION_DATA_DIR}/chain.properties

  # Update the app.json with build context information - Also ensure we always have a unique IOS build number
  # filter out the credentials used for the build process
  jq --slurpfile envConfig "${CONFIG_FILE}" \
    --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" \
    --arg BUILD_REFERENCE "${BUILD_REFERENCE}" \
    --arg BUILD_NUMBER "${BUILD_NUMBER}" \
    '.expo.releaseChannel=$RELEASE_CHANNEL | .expo.extra.BUILD_REFERENCE=$BUILD_REFERENCE | .expo.ios.buildNumber=$BUILD_NUMBER | .expo.extra=.expo.extra + $envConfig[]["AppConfig"]' <  "./app.json" > "${tmpdir}/environment-app.json"
  mv "${tmpdir}/environment-app.json" "./app.json"
  ## Optional app.json overrides
  IOS_DIST_BUNDLE_ID="$( jq -r '.BuildConfig.IOS_DIST_BUNDLE_ID' < "${CONFIG_FILE}" )"
  if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
    jq --arg IOS_DIST_BUNDLE_ID "${IOS_DIST_BUNDLE_ID}" '.expo.ios.bundleIdentifier=$IOS_DIST_BUNDLE_ID' <  "./app.json" > "${tmpdir}/ios-bundle-app.json"
    mv "${tmpdir}/ios-bundle-app.json" "./app.json"
  fi

  ANDROID_BUNDLE_ID="$( jq -r '.BuildConfig.ANDROID_BUNDLE_ID' < "${CONFIG_FILE}" )"
  if [[ "${ANDROID_BUNDLE_ID}" != "null" && -n "${ANDROID_BUNDLE_ID}" ]]; then
    jq --arg ANDROID_BUNDLE_ID "${ANDROID_BUNDLE_ID}" '.expo.android.package=$ANDROID_BUNDLE_ID' <  "./app.json" > "${tmpdir}/android-bundle-app.json"
    mv "${tmpdir}/android-bundle-app.json" "./app.json"
  fi

  # Create a build for the SDK
  info "Creating an OTA for this version of the SDK"
  expo export --dump-sourcemap --public-url "${PUBLIC_URL}" --output-dir "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}"  || return $?

  EXPO_ID_OVERRIDE="$( jq -r '.BuildConfig.EXPO_ID_OVERRIDE' < "${CONFIG_FILE}" )"
  if [[ "${EXPO_ID_OVERRIDE}" != "null" && -n "${EXPO_ID_OVERRIDE}" ]]; then

    jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' < "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/ios-index.json" > "${tmpdir}/ios-expo-override.json"
    mv "${tmpdir}/ios-expo-override.json" "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/ios-index.json"

    jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" '.id=$EXPO_ID_OVERRIDE' < "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/android-index.json" > "${tmpdir}/android-expo-override.json"
    mv "${tmpdir}/android-expo-override.json" "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/android-index.json"

  fi

  if [[ "${DISABLE_OTA}" == "false" ]]; then

    if [[ -n "${BUILD_REFERENCE}" ]]; then
      info "Override revisionId to match the build reference ${BUILD_REFERENCE}"
      jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' < "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/ios-index.json" > "${tmpdir}/ios-expo-override.json"
      mv "${tmpdir}/ios-expo-override.json" "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/ios-index.json"

      jq -c --arg REVISION_ID "${BUILD_REFERENCE}" '.revisionId=$REVISION_ID' < "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/android-index.json" > "${tmpdir}/android-expo-override.json"
      mv "${tmpdir}/android-expo-override.json" "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/android-index.json"

    fi

    info "Copying OTA to CDN"
    aws --region "${AWS_REGION}" s3 sync --no-progress --delete "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}" "s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/packages/${EXPO_SDK_VERSION}" || return $?

    # Merge all existing SDK packages into a master distribution
    aws --region "${AWS_REGION}" s3 cp --no-progress --recursive --exclude "${EXPO_SDK_VERSION}/*" "s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/packages/" "${SRC_PATH}/app/dist/packages/"
    EXPO_EXPORT_MERGE_ARGUMENTS=""
    for dir in ${SRC_PATH}/app/dist/packages/*/ ; do
        EXPO_EXPORT_MERGE_ARGUMENTS="${EXPO_EXPORT_MERGE_ARGUMENTS} --merge-src-dir "${dir}""
    done

    # Create master export
    info "Creating master OTA artefact with Extra Dirs: ${EXPO_EXPORT_MERGE_ARGUMENTS}"
    expo export --public-url "${PUBLIC_URL}" --output-dir "${SRC_PATH}/app/dist/master/" ${EXPO_EXPORT_MERGE_ARGUMENTS}  || return $?

    if [[ "${EXPO_ID_OVERRIDE}" != "null" && -n "${EXPO_ID_OVERRIDE}" ]]; then

        jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" 'if type=="array" then [ .[] | .id=$EXPO_ID_OVERRIDE ] else .id=$EXPO_ID_OVERRIDE end' < "${SRC_PATH}/app/dist/master/ios-index.json" > "${tmpdir}/ios-master-expo-override.json"
        mv "${tmpdir}/ios-master-expo-override.json" "${SRC_PATH}/app/dist/master/ios-index.json"

        jq -c --arg EXPO_ID_OVERRIDE "${EXPO_ID_OVERRIDE}" 'if type=="array" then [ .[] | .id=$EXPO_ID_OVERRIDE ] else .id=$EXPO_ID_OVERRIDE end' < "${SRC_PATH}/app/dist/master/android-index.json" > "${tmpdir}/android-master-expo-override.json"
        mv "${tmpdir}/android-master-expo-override.json" "${SRC_PATH}/app/dist/master/android-index.json"

    fi

    if [[ -n "${BUILD_REFERENCE}" ]]; then
      info "Override revisionId in master export to match the build reference ${BUILD_REFERENCE}"
      jq -c --arg REVISION_ID "${BUILD_REFERENCE}" 'if type=="array" then [ .[] | .revisionId=$REVISION_ID ] else .revisionId=$REVISION_ID end' < "${SRC_PATH}/app/dist/master/ios-index.json" > "${tmpdir}/ios-expo-override.json"
      mv "${tmpdir}/ios-expo-override.json" "${SRC_PATH}/app/dist/master/ios-index.json"

      jq -c --arg REVISION_ID "${BUILD_REFERENCE}" 'if type=="array" then [ .[] | .revisionId=$REVISION_ID ] else .revisionId=$REVISION_ID end' < "${SRC_PATH}/app/dist/master/android-index.json" > "${tmpdir}/android-expo-override.json"
      mv "${tmpdir}/android-expo-override.json" "${SRC_PATH}/app/dist/master/android-index.json"

    fi

    aws --region "${AWS_REGION}" s3 sync --no-progress "${SRC_PATH}/app/dist/master/" "s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}" || return $?
  fi

   DETAILED_HTML_QR_MESSAGE="<h4>Expo Client App QR Codes</h4> <p>Use these codes to load the app through the Expo Client</p>"
   DETAILED_HTML_BINARY_MESSAGE="<h4>Expo Binary Builds</h4>"
   if [[ "${BUILD_BINARY}" == "false" ]]; then
     DETAILED_HTML_BINARY_MESSAGE="${DETAILED_HTML_BINARY_MESSAGE} <p> No binary builds were generated for this publish </p>"
   fi

  for build_format in "${BUILD_FORMATS[@]}"; do

      BINARY_FILE_PREFIX="${build_format}"
      case "${build_format}" in
        "android")
            BINARY_FILE_EXTENSION="apk"
            ANDROID_KEYSTORE_ALIAS="$( jq -r '.BuildConfig.ANDROID_KEYSTORE_ALIAS' < "${CONFIG_FILE}" )"

            ANDROID_KEYSTORE_PASSWORD="$( jq -r '.BuildConfig.ANDROID_KEYSTORE_PASSWORD' < "${CONFIG_FILE}" )"
            export ANDROID_KEYSTORE_PASSWORD="$( decrypt_kms_string "${AWS_REGION}" "${ANDROID_KEYSTORE_PASSWORD#"base64:"}")"

            ANDROID_KEY_PASSWORD="$( jq -r '.BuildConfig.ANDROID_KEY_PASSWORD' < "${CONFIG_FILE}" )"
            export ANDROID_KEY_PASSWORD="$( decrypt_kms_string "${AWS_REGION}" "${ANDROID_KEY_PASSWORD#"base64:"}")"

            ANDROID_KEYSTORE_FILE="${OPS_PATH}/android_keystore.jks"

            TURTLE_EXTRA_BUILD_ARGS="${TURTLE_EXTRA_BUILD_ARGS} --keystore-path ${ANDROID_KEYSTORE_FILE} --keystore-alias ${ANDROID_KEYSTORE_ALIAS}"
            ;;
        "ios")
            BINARY_FILE_EXTENSION="ipa"
            export IOS_DIST_APPLE_ID="$( jq -r '.BuildConfig.IOS_DIST_APPLE_ID' < "${CONFIG_FILE}" )"
            export IOS_DIST_APP_ID="$( jq -r '.BuildConfig.IOS_DIST_APP_ID' < "${CONFIG_FILE}" )"

            export IOS_DIST_EXPORT_METHOD="$( jq -r '.BuildConfig.IOS_DIST_EXPORT_METHOD' < "${CONFIG_FILE}" )"

            export IOS_TESTFLIGHT_USERNAME="$(jq -r '.BuildConfig.IOS_TESTFLIGHT_USERNAME' < "${CONFIG_FILE}")"
            IOS_TESTFLIGHT_PASSWORD="$(jq -r '.BuildConfig.IOS_TESTFLIGHT_PASSWORD' < "${CONFIG_FILE}")"
            export IOS_TESTFLIGHT_PASSWORD="$( decrypt_kms_string "${AWS_REGION}" "${IOS_TESTFLIGHT_PASSWORD#"base64:"}")"

            IOS_DIST_P12_PASSWORD="$( jq -r '.BuildConfig.IOS_DIST_P12_PASSWORD' < "${CONFIG_FILE}" )"
            export EXPO_IOS_DIST_P12_PASSWORD="$( decrypt_kms_string "${AWS_REGION}" "${IOS_DIST_P12_PASSWORD#"base64:"}")"

            export IOS_DIST_PROVISIONING_PROFILE_BASE="ios_profile"
            export IOS_DIST_PROVISIONING_PROFILE_EXTENSION=".mobileprovision"
            export IOS_DIST_PROVISIONING_PROFILE="${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}"
            export IOS_DIST_P12_FILE="${OPS_PATH}/ios_distribution.p12"

            TURTLE_EXTRA_BUILD_ARGS="${TURTLE_EXTRA_BUILD_ARGS} --team-id ${IOS_DIST_APPLE_ID} --dist-p12-path ${IOS_DIST_P12_FILE} --provisioning-profile-path ${IOS_DIST_PROVISIONING_PROFILE}"
            ;;
        "*")
            echo "Unkown build format" && return 128
            ;;
      esac

      if [[ "${BUILD_BINARY}" == "true" ]]; then

        info "Building App Binary for ${build_format}"

        EXPO_BINARY_FILE_NAME="${BINARY_FILE_PREFIX}-${EXPO_APP_VERSION}-${BUILD_NUMBER}.${BINARY_FILE_EXTENSION}"
        EXPO_BINARY_FILE_PATH="${BINARY_PATH}/${EXPO_BINARY_FILE_NAME}"
        EXPO_MANIFEST_URL="${PUBLIC_URL}/packages/${EXPO_SDK_VERSION}/${build_format}-index.json"

        case "${BINARY_BUILD_PROCESS}" in
            "turtle")
                echo "Using turtle to build the binary image"

                # Setup Turtle
                if [[ "${TURTLE_VERSION}" != "${TURTLE_DEFAULT_VERSION}" ]]; then
                    npm install turtle-cli@"${TURTLE_VERSION}"
                fi
                npx turtle setup:"${build_format}" --sdk-version "${EXPO_SDK_VERSION}" || return $?

                # Build using turtle
                npx turtle build:"${build_format}" --public-url "${EXPO_MANIFEST_URL}" --output "${EXPO_BINARY_FILE_PATH}" ${TURTLE_EXTRA_BUILD_ARGS} "${SRC_PATH}" || return $?
                ;;

            "fastlane")
                echo "Using fastlane to build the binary image"
                export FASTLANE_DISABLE_COLORS=1

                FASTLANE_KEYCHAIN_PATH="${OPS_PATH}/${BUILD_NUMBER}.keychain"
                FASTLANE_KEYCHAIN_NAME="${BUILD_NUMBER}"
                FASTLANE_IOS_PROJECT_FILE="ios/${EXPO_PROJECT_SLUG}.xcodeproj"
                FASTLANE_IOS_WORKSPACE_FILE="ios/${EXPO_PROJECT_SLUG}.xcworkspace"
                FASTLANE_IOS_PODFILE="ios/Podfile"

                # Update App details
                # Pre SDK37, Expokit maintained an Info.plist in Supporting
                INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Supporting/Info.plist"
                [[ ! -e "ios/${INFO_PLIST_PATH}" ]] && INFO_PLIST_PATH="${EXPO_PROJECT_SLUG}/Info.plist"
                fastlane run set_info_plist_value path:"ios/${INFO_PLIST_PATH}" key:CFBundleVersion value:"${BUILD_NUMBER}" || return $?
                fastlane run set_info_plist_value path:"ios/${INFO_PLIST_PATH}" key:CFBundleShortVersionString value:"${EXPO_APP_VERSION}" || return $?
                if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
                    cd "${SRC_PATH}/ios"
                    fastlane run update_app_identifier app_identifier:"${IOS_DIST_BUNDLE_ID}" xcodeproj:"${EXPO_PROJECT_SLUG}.xcodeproj" plist_path:"${INFO_PLIST_PATH}" || return $?
                    cd "${SRC_PATH}"
                fi

                if [[ -e "${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" ]]; then
                    # Bare workflow support (SDK 37+)

                    # Updates URL
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesURL value:"${PUBLIC_URL}" || return $?

                    # SDK Version
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesSDKVersion value:"${EXPO_SDK_VERSION}" || return $?

                    # Release channel
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesReleaseChannel value:"${RELEASE_CHANNEL}" || return $?

                    # Check for updates
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesCheckOnLaunch value:"ALWAYS" || return $?

                    # Wait up to 10s for updates to download
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/Expo.plist" key:EXUpdatesLaunchWaitMs value:"10000" || return $?

                else
                    # Legacy Expokit support
                    # Update Expo Details and seed with latest expo expot bundles
                    BINARY_BUNDLE_FILE="${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/shell-app-manifest.json"
                    if [[ "${DISABLE_OTA}" == "false" ]]; then
                        cp "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/ios-index.json" "${BINARY_BUNDLE_FILE}"
                    fi

                    # Get the bundle file name from the manifest
                    BUNDLE_URL="$( jq -r '.bundleUrl' < "${BINARY_BUNDLE_FILE}")"
                    BUNDLE_FILE_NAME="$( basename "${BUNDLE_URL}")"

                    if [[ "${DISABLE_OTA}" == "false" ]]; then
                        cp "${SRC_PATH}/app/dist/build/${EXPO_SDK_VERSION}/bundles/${BUNDLE_FILE_NAME}" "${SRC_PATH}/ios/${EXPO_PROJECT_SLUG}/Supporting/shell-app.bundle"
                    fi

                    jq --arg RELEASE_CHANNEL "${RELEASE_CHANNEL}" --arg MANIFEST_URL "${EXPO_MANIFEST_URL}" '.manifestUrl=$MANIFEST_URL | .releaseChannel=$RELEASE_CHANNEL' <  "ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json" > "${tmpdir}/EXShell.json"
                    mv "${tmpdir}/EXShell.json" "ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.json"

                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:manifestUrl value:"${EXPO_MANIFEST_URL}" || return $?
                    fastlane run set_info_plist_value path:"ios/${EXPO_PROJECT_SLUG}/Supporting/EXShell.plist" key:releaseChannel value:"${RELEASE_CHANNEL}" || return $?
                fi

                # Keychain setup - Creates a temporary keychain
                fastlane run create_keychain path:"${FASTLANE_KEYCHAIN_PATH}" password:"${FASTLANE_KEYCHAIN_NAME}" add_to_search_list:"true" unlock:"true" timeout:3600 || return $?

                # codesigning setup
                fastlane run import_certificate certificate_path:"${OPS_PATH}/ios_distribution.p12" certificate_password:"${EXPO_IOS_DIST_P12_PASSWORD}" keychain_path:"${FASTLANE_KEYCHAIN_PATH}" keychain_password:"${FASTLANE_KEYCHAIN_NAME}" log_output:"true" || return $?
                CODESIGN_IDENTITY="$( security find-certificate -c "iPhone Distribution" -p "${FASTLANE_KEYCHAIN_PATH}"  |  openssl x509 -noout -subject -nameopt multiline | grep commonName | sed -n 's/ *commonName *= //p' )"

                # load the app provisioning profile
                fastlane run install_provisioning_profile path:"${IOS_DIST_PROVISIONING_PROFILE}" || return $?
                fastlane run update_project_provisioning xcodeproj:"${FASTLANE_IOS_PROJECT_FILE}" profile:"${IOS_DIST_PROVISIONING_PROFILE}" code_signing_identity:"iPhone Distribution" || return $?

                # load extension profiles
                # extension target name is assumed to be the string appended to "ios_profile" in the profile name
                # ios_profile_xxx.mobileprovision -> target is xxx
                for PROFILE in "${OPS_PATH}"/"${IOS_DIST_PROVISIONING_PROFILE_BASE}"*${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}; do
                    TARGET="${PROFILE%${IOS_DIST_PROVISIONING_PROFILE_EXTENSION}}"
                    TARGET="${TARGET#${OPS_PATH}/${IOS_DIST_PROVISIONING_PROFILE_BASE}}"
                    # Ignore the app provisioning profile
                    [[ -z "${TARGET}" ]] && continue
                    # Update the extension target
                    TARGET="${TARGET#_}"
                    echo "Updating target ${TARGET} ..."
                    fastlane run install_provisioning_profile path:"${PROFILE}" || return $?
                    fastlane run update_project_provisioning xcodeproj:"${FASTLANE_IOS_PROJECT_FILE}" profile:"${PROFILE}" target_filter:".*${TARGET}.*" code_signing_identity:"iPhone Distribution" || return $?
                    # Update the plist file as well if present
                    TARGET_PLIST_PATH="ios/${TARGET}/Info.plist"
                    if [[ -f "${TARGET_PLIST_PATH}" ]]; then
                        fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleVersion value:"${BUILD_NUMBER}" || return $?
                        fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleShortVersionString value:"${EXPO_APP_VERSION}" || return $?
                        if [[ "${IOS_DIST_BUNDLE_ID}" != "null" && -n "${IOS_DIST_BUNDLE_ID}" ]]; then
                            fastlane run set_info_plist_value path:"${TARGET_PLIST_PATH}" key:CFBundleIdentifier value:"${IOS_DIST_BUNDLE_ID}.${TARGET}" || return $?
                        fi
                    fi
                done

                fastlane run automatic_code_signing use_automatic_signing:false path:"${FASTLANE_IOS_PROJECT_FILE}" team_id:"${IOS_DIST_APPLE_ID}" code_sign_identity:"iPhone Distribution" || return $?

                # Build App
                fastlane run cocoapods podfile:"${FASTLANE_IOS_PODFILE}" try_repo_update_on_error:"true" || return $?
                fastlane run build_ios_app workspace:"${FASTLANE_IOS_WORKSPACE_FILE}" output_directory:"${BINARY_PATH}" output_name:"${EXPO_BINARY_FILE_NAME}" export_method:"${IOS_DIST_EXPORT_METHOD}" codesigning_identity:"${CODESIGN_IDENTITY}" || return $?

                ;;
        esac


        if [[ -f "${EXPO_BINARY_FILE_PATH}" ]]; then
            aws --region "${AWS_REGION}" s3 sync --no-progress --exclude "*" --include "${BINARY_FILE_PREFIX}*" "${BINARY_PATH}" "s3://${APPDATA_BUCKET}/${EXPO_APPDATA_PREFIX}/" || return $?
            EXPO_BINARY_PRESIGNED_URL="$(aws --region "${AWS_REGION}" s3 presign --expires-in "${BINARY_EXPIRATION}" "s3://${APPDATA_BUCKET}/${EXPO_APPDATA_PREFIX}/${EXPO_BINARY_FILE_NAME}" )"
            DETAILED_HTML_BINARY_MESSAGE="${DETAILED_HTML_BINARY_MESSAGE}<p><strong>${build_format}</strong> <a href="${EXPO_BINARY_PRESIGNED_URL}">${build_format} - ${EXPO_APP_VERSION} - ${BUILD_NUMBER}</a>"

            if [[ "${SUBMIT_BINARY}" == "true" && -n "${IOS_TESTFLIGHT_USERNAME}" ]]; then
                case "${build_format}" in
                    "ios")

                        # Ensure mandatory arguments have been provided
                        if [[ -z "${IOS_TESTFLIGHT_USERNAME}" || -z "${IOS_TESTFLIGHT_PASSWORD}" || -z "${IOS_DIST_APP_ID}" ]]; then
                            fatal "TestFlight details not found please provide IOS_TESTFLIGHT_USERNAME, IOS_TESTFLIGHT_PASSWORD and IOS_DIST_APP_ID"
                            return 255
                        fi

                        info "Submitting IOS binary to testflight"
                        export FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD="${IOS_TESTFLIGHT_PASSWORD}"
                        fastlane run upload_to_testflight skip_waiting_for_build_processing:true apple_id:"${IOS_DIST_APP_ID}" ipa:"${EXPO_BINARY_FILE_PATH}" username:"${IOS_TESTFLIGHT_USERNAME}" || return $?
                        DETAILED_HTML_BINARY_MESSAGE="${DETAILED_HTML_BINARY_MESSAGE}<strong> Submitted to TestFlight</strong>"
                    ;;
                esac
            fi
        fi
      else
        info "Skipping build of app binary for ${build_format}"
      fi

  done

  for qr_build_format in "${EXPO_QR_BUILD_FORMATS[@]}"; do

      #Generate EXPO QR Code
      EXPO_QR_FILE_PREFIX="${qr_build_format}"
      EXPO_QR_FILE_NAME="${EXPO_QR_FILE_PREFIX}-qr.png"
      EXPO_QR_FILE_PATH="${REPORTS_PATH}/${EXPO_QR_FILE_NAME}"

      qr "exp://${PUBLIC_URL#*//}/${qr_build_format}-index.json?release-channel=${RELEASE_CHANNEL}" > "${EXPO_QR_FILE_PATH}" || return $?

      DETAILED_HTML_QR_MESSAGE="${DETAILED_HTML_QR_MESSAGE}<p><strong>${qr_build_format}</strong> <br> <img src=\"./${EXPO_QR_FILE_NAME}\" alt=\"EXPO QR Code\" width=\"200px\" /></p>"

  done

  DETAILED_HTML="<html><body> <h4>Expo Mobile App Publish</h4> <p> A new Expo mobile app publish has completed </p> <ul> <li><strong>Public URL</strong> ${PUBLIC_URL}</li> <li><strong>Release Channel</strong> ${RELEASE_CHANNEL}</li><li><strong>SDK Version</strong> ${EXPO_SDK_VERSION}</li><li><strong>App Version</strong> ${EXPO_APP_VERSION}</li><li><strong>Build Number</strong> ${BUILD_NUMBER}</li><li><strong>Code Commit</strong> ${BUILD_REFERENCE}</li></ul> ${DETAILED_HTML_QR_MESSAGE} ${DETAILED_HTML_BINARY_MESSAGE} </body></html>"
  echo "${DETAILED_HTML}" > "${REPORTS_PATH}/build-report.html"

  aws --region "${AWS_REGION}" s3 sync  --no-progress "${REPORTS_PATH}/" "s3://${PUBLIC_BUCKET}/${PUBLIC_PREFIX}/reports/" || return $?

  if [[ "${BUILD_BINARY}" == "true" ]]; then
    if [[ "${SUBMIT_BINARY}" == "true" ]]; then
        DETAIL_MESSAGE="${DETAIL_MESSAGE} *Expo Publish Complete* - *NEW BINARIES CREATED* - *SUBMITTED TO APP TESTING* -  More details available <${PUBLIC_URL}/reports/build-report.html|Here>"
    else
        DETAIL_MESSAGE="${DETAIL_MESSAGE} *Expo Publish Complete* - *NEW BINARIES CREATED* -  More details available <${PUBLIC_URL}/reports/build-report.html|Here>"
    fi
  else
    DETAIL_MESSAGE="${DETAIL_MESSAGE} *Expo Publish Complete* - More details available <${PUBLIC_URL}/reports/build-report.html|Here>"
  fi

  echo "DETAIL_MESSAGE=${DETAIL_MESSAGE}" >> ${AUTOMATION_DATA_DIR}/context.properties

  # All good
  return 0
}

main "$@" || exit $?
