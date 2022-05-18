#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# DEPRECATED
deprecated_script

function main() {
  # Add conventional commit details
  DETAIL_MESSAGE="${DETAIL_MESSAGE}, cctype=manenv, ccdesc=${AUTOMATION_JOB_IDENTIFIER}"

  ${AUTOMATION_DIR}/manageUnits.sh -r "${PRODUCT_CONFIG_COMMIT}" || return $?

  # Commit the config repo
  # Segment level units can result in updates the the operations tree which should be in the repo
  # holding the state tree but just in case, check the repo holding the config as well
  save_product_config "${DETAIL_MESSAGE}" "${PRODUCT_CONFIG_REFERENCE}" || return $?

  # Commit the generated templates/stacks
  save_product_infrastructure "${DETAIL_MESSAGE}" "${PRODUCT_INFRASTRUCTURE_REFERENCE}" || return $?
}

main "$@"
