#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

# DEPRECATED
deprecated_script

${AUTOMATION_BASE_DIR}/constructTree.sh "$@"
RESULT=$?
