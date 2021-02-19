#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

function main() {
  # Add conventional commit details
  DETAIL_MESSAGE="${DETAIL_MESSAGE}, cctype=manacc, ccdesc=${AUTOMATION_JOB_IDENTIFIER}"

  ${AUTOMATION_DIR}/manageUnits.sh -r "${ACCOUNT_CONFIG_COMMIT}" || return $?

  # With the removal of tagging, this shouldn't be needed as no changes should be made to the config part of the cmdb
  # All ok so tag the config repo
  # save_repo "${ACCOUNT_DIR}" "account config" "${DETAIL_MESSAGE}" "${PRODUCT_CONFIG_REFERENCE}" || return $?

  # Commit the generated application templates/stacks
  save_repo "${ACCOUNT_INFRASTRUCTURE_DIR}" "account infrastructure" "${DETAIL_MESSAGE}" "${ACCOUNT_INFRASTRUCTURE_REFERENCE}" || return $?
}

main "$@"
