#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

function main() {

    # Planning should only affect the state
    cd "${PRODUCT_STATE_DIR}"

    # Switch to the plan branch
    BRANCH="plan-${PRODUCT}-${ENVIRONMENT}-${SEGMENT}-${JOB_IDENTIFIER}"

    # Create the plan branch
    git checkout -b "${BRANCH}"

    # Create the templates and corresponding change sets
    ${AUTOMATION_DIR}/manageUnits.sh -l "application" -m "${DEPLOYMENT_MODE_PLAN}" -a "${DEPLOYMENT_UNIT_LIST}" -r "${PRODUCT_CONFIG_COMMIT}" || return $?

    # Commit the results for later review
    save_product_state "${DETAIL_MESSAGE}" "${PRODUCT_INFRASTRUCTURE_REFERENCE}" || return $?
}

main "$@"
