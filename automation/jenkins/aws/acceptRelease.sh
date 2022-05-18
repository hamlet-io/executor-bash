#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# DEPRECATED
deprecated_script

# Ensure mandatory arguments have been provided
[[ (-z "${RELEASE_MODE}") ||
    (-z "${RELEASE_TAG}") ]] && fatalMandatory

# Include the build information in the detail message
${AUTOMATION_DIR}/manageBuildReferences.sh -l
RESULT=$? && [[ "${RESULT}" -ne 0 ]] && exit

# Tag the builds
${AUTOMATION_DIR}/manageBuildReferences.sh -a "${RELEASE_TAG}"
RESULT=$?
