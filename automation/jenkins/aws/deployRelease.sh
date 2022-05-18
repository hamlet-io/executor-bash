#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# DEPRECATED
deprecated_script

function main() {
  # Add conventional commit and deploy/release tag to details
  DETAIL_MESSAGE="deployment=${DEPLOYMENT_TAG}, release=${RELEASE_TAG}, ${DETAIL_MESSAGE}, cctype=deploy, ccdesc=${AUTOMATION_JOB_IDENTIFIER}"
  save_context_property DETAIL_MESSAGE

  # Update the stacks
  ${AUTOMATION_DIR}/manageUnits.sh -l "application" -a "${DEPLOYMENT_UNIT_LIST}" || return $?

  # Commit the generated application templates/stacks
  # It is assumed no changes have been made to the config part of the cmdb
  save_product_infrastructure "${DETAIL_MESSAGE}" "${PRODUCT_INFRASTRUCTURE_REFERENCE}" || return $?
}

main "$@"
