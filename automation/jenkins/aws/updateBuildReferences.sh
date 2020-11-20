#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# Update build references
${AUTOMATION_DIR}/manageBuildReferences.sh -u
RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

# Release mode info
[[ -n "${RELEASE_MODE_TAG}" ]] && DETAIL_MESSAGE="${DETAIL_MESSAGE}, relmode=${RELEASE_MODE_TAG}"

# Add conventional commit details
DETAIL_MESSAGE="${DETAIL_MESSAGE}, cctype=updref, ccdesc=${AUTOMATION_JOB_IDENTIFIER}"

# Save the results
save_product_config "${DETAIL_MESSAGE}" "${PRODUCT_CONFIG_REFERENCE}"
RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

if [[ (-n "${AUTODEPLOY+x}") &&
        ("$AUTODEPLOY" != "true") ]]; then
    RESULT=2
    fatal "AUTODEPLOY is not true, triggering exit" && exit
fi

# Record key parameters for downstream jobs
save_chain_property DEPLOYMENT_UNITS "${DEPLOYMENT_UNIT_LIST}"

# All good
RESULT=0


