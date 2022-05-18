#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

# DEPRECATED
deprecated_script

# All the logic is in the openapi build
${AUTOMATION_DIR}/buildOpenapi.sh "$@"
RESULT=$?
