#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

[[ ( -z "${CODE_COMMIT_LIST}" ) && ( -z "${CODE_TAG_LIST}" ) ]] &&
    fatal "This job requires a GIT_COMMIT or a DEPLOYMENT_UNIT! value" && exit

# Ensure at least one deployment unit has been provided
[[ -z "${DEPLOYMENT_UNIT_LIST}" ]] &&
    fatal "Job requires at least one deployment unit" && exit

# All good
RESULT=0



