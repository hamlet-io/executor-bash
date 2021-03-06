#!/usr/bin/env bash
[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap '[[ (-z "${AUTOMATION_DEBUG}") ; exit 1' SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# Get the generation context so we can run template generation
. "${GENERATION_BASE_DIR}/execution/setContext.sh"

tmpdir="$(getTempDir "cota_inf_XXX")"


function main() {
    info "Building Deployment ${DEPLOYMENT_UNIT_LIST}"
    for DEPLOYMENT_UNIT in ${DEPLOYMENT_UNIT_LIST[0]}; do

        DEPLOYMENT_GROUP="${DEPLOYMENT_GROUP:-"application"}"
         # Generate a build blueprint so that we can find out the source S3 bucket
        info "Generating blueprint to find details..."
        ${GENERATION_DIR}/createTemplate.sh -e "buildblueprint" -p "aws" -l "${DEPLOYMENT_GROUP}" -u "${DEPLOYMENT_UNIT}" -o "${tmpdir}" > /dev/null
        BUILD_BLUEPRINT="${tmpdir}/buildblueprint-${DEPLOYMENT_GROUP}-${DEPLOYMENT_UNIT}-config.json"

        if [[ ! -f "${BUILD_BLUEPRINT}" || -z "$(cat ${BUILD_BLUEPRINT} )" ]]; then
            fatal "Could not generate blueprint for task details"
            return 255
        fi

        mkdir -p "${tmpdir}/${DEPLOYMENT_UNIT}"
        data_manifest_file="${tmpdir}/${DEPLOYMENT_UNIT}/${data_manifest_filename}"

        rdssnapshot_database_id="$( jq -r '.Occurrence.State.Attributes.INSTANCEID' < "${BUILD_BLUEPRINT}" )"
        rdssnapshot_region="$( jq -r '.Occurrence.State.Attributes.REGION' < "${BUILD_BLUEPRINT}" )"
        rdssnapshot_type="$( jq -r '.Occurrence.State.Attributes.TYPE' < "${BUILD_BLUEPRINT}" )"

        info "Creating Snapshot of RDS Instance: ${rdssnapshot_database_id} ..."

        snapshot_id="buildSnapshot-${DEPLOYMENT_UNIT}-$(date +%Y%m%d%H%M)"

        create_snapshot "${rdssnapshot_region}" "${rdssnapshot_type}" "${rdssnapshot_database_id}" "${snapshot_id}"
        RESULT=$?

        if [[ "${RESULT}" -eq 0 ]]; then

            snapshot_create_time="$( aws --region "${rdssnapshot_region}" rds describe-db-snapshots --db-snapshot-identifier "${snapshot_id}" --query "DBSnapshots[0].SnapshotCreateTime" --output text )"
            build_reference="$( echo "${snapshot_create_time}" | shasum -a 1 | cut -d " " -f 1  )"

            save_context_property CODE_COMMIT_LIST "${build_reference}"
            save_context_property SNAPSHOT_SOURCE "${snapshot_id}"
            save_chain_property GIT_COMMIT "${build_reference}"

            info "Commit: ${build_reference}"

        else
            fatal "Could not create snapshot of rds instance ${rdssnapshot_database_id}"
            return 128
        fi
    done

    return 0
}

main "$@"
