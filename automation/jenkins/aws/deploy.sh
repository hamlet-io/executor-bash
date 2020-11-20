#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

function main() {
  # Add conventional commit details
  DETAIL_MESSAGE="${DETAIL_MESSAGE}, cctype=deploy, ccdesc=${AUTOMATION_JOB_IDENTIFIER}"
  save_context_property DETAIL_MESSAGE

  # Create the templates
  ${AUTOMATION_DIR}/manageUnits.sh -l "application" -a "${DEPLOYMENT_UNIT_LIST}" -r "${PRODUCT_CONFIG_COMMIT}" || return $?

  # Commit the generated application templates/stacks
  # It is assumed no changes have been made to the config part of the cmdb
  save_product_infrastructure "${DETAIL_MESSAGE}" "${PRODUCT_INFRASTRUCTURE_REFERENCE}" || return $?
}

main "$@"
