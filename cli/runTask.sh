#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}
trap '. ${GENERATION_BASE_DIR}/execution/cleanupContext.sh; exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${GENERATION_BASE_DIR}/execution/common.sh"

# Defaults
DELAY_DEFAULT=30
RETRY_COUNT_DEFAULT=120
ENV_NAMES=()
ENV_VALUES=()

tmpdir="$(getTempDir "hamlet_runTask_XXX")"

function usage() {
    cat <<EOF

Run an ECS task

Usage: $(basename $0) -t TIER -i COMPONENT -w TASK -e ENV -v VALUE -d DELAY

where

(o) -c CONTAINER_ID         is the name of the container that environment details are applied to
(o) -d DELAY                is the interval between checking the progress of the task
(o) -e ENV                  is the name of an environment variable to define for the task
    -h                      shows this text
(m) -i COMPONENT            is the name of the ecs component in the solution where the task is defined
(o) -j COMPONENT_INSTANCE   is the instance of the ecs cluster to run the task on
(o) -k COMPONENT_VERSION    is the version of the ecs clsuter to run the task on
(m) -t TIER                 is the name of the tier in the solution where the task is defined
(o) -v VALUE                is the value for the last environment value defined (via -e) for the task
(m) -w TASK                 is the name of the task to be run
(o) -x INSTANCE             is the instance of the task to be run
(o) -y VERSION              is the version of the task to be run

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

DELAY     = ${DELAY_DEFAULT} seconds

NOTES:

1. The ECS cluster is found using the provided tier and component combined with the product and segment
2. ENV and VALUE should always appear in pairs

EOF
    exit
}

# Parse options
while getopts ":c:d:e:hi:j:k:t:v:x:y:w:" opt; do
    case $opt in
        c)
            CONTAINER_ID="${OPTARG}"
            ;;
        d)
            DELAY="${OPTARG}"
            ;;
        e)
            addToArray "ENV_NAMES" "${OPTARG}"
            ;;
        h)
            usage
            ;;
        i)
            COMPONENT="${OPTARG}"
            ;;
        j)
            if [[ "${OPTARG}" == "default" ]]; then
                COMPONENT_INSTANCE=""
            else
                COMPONENT_INSTANCE="${OPTARG}"
            fi
            ;;
        k)
            COMPONENT_VERSION="${OPTARG}"
            ;;
        t)
            TIER="${OPTARG}"
            ;;
        v)
            addToArray "ENV_VALUES" "${OPTARG}"
            ;;
        w)
            TASK="${OPTARG}"
            ;;
        x)
            if [[ "${OPTARG}" == "default" ]]; then
                INSTANCE=""
            else
                INSTANCE="${OPTARG}"
            fi
            ;;
        y)
            VERSION="${OPTARG}"
            ;;
        \?)
            fatalOption
            ;;
        :)
            fatalOptionArgument
            ;;
    esac
done

DELAY="${DELAY:-${DELAY_DEFAULT}}"
RETRY_COUNT="${RETRY_COUNT:-${RETRY_COUNT_DEFAULT}}"

# Ensure mandatory arguments have been provided
if [[ -z "${TASK}" || -z "${TIER}" || -z "${COMPONENT}" ]]; then
     fatalMandatory
     exit 255
fi

# Set up the context
. "${GENERATION_BASE_DIR}/execution/setContext.sh"

status_file="$(getTopTempDir)/run_task_status.txt"

# Generate a blueprint that we can use to find hosting details
info "Generating blueprint to find details..."
${GENERATION_DIR}/createTemplate.sh -e "blueprint" -p "aws" -o "${tmpdir}" > /dev/null
SEGMENT_BLUEPRINT="${tmpdir}/blueprint-config.json"

if [[ ! -f "${SEGMENT_BLUEPRINT}" || -z "$(cat ${SEGMENT_BLUEPRINT} )" ]]; then
    fatal "Could not generate blueprint for task details"
    exit 255
fi

# Search through the blueprint to find the cluster and the task
CLUSTER_BLUEPRINT="$(getJSONValue "${SEGMENT_BLUEPRINT}" \
                                    " .Tenants[0]       | objects \
                                    | .Products[0]      | objects \
                                    | .Environments[0]  | objects \
                                    | .Segments[0]      | objects \
                                    | .Tiers[]          | objects | select(.Name==\"${TIER}\") \
                                    | .Components[]     | objects | select(.Name==\"${COMPONENT}\") \
                                    | .Occurrences[]    | objects | \
                                            select( \
                                                .Core.Type==\"ecs\" \
                                                and .Core.Instance.Name==\"${COMPONENT_INSTANCE}\" \
                                                and .Core.Version.Name==\"${COMPONENT_VERSION}\" \
                                            )")"

if [[ -z "${CLUSTER_BLUEPRINT}" ]]; then
    error "Could not find ECS Component - Tier: ${TIER} - Component: ${COMPONENT} - Component_Instance: ${COMPONENT_INSTANCE} - Component_Version: ${COMPONENT_VERSION}"
    exit 255
fi

COMPONENT_BLUEPRINT="$(echo "${CLUSTER_BLUEPRINT}" | jq \
                                    ".Occurrences[] | objects | \
                                            select( \
                                                .Core.Type==\"task\" \
                                                and .Core.Component.RawName==\"${TASK}\" \
                                                and .Core.Instance.Name==\"${INSTANCE}\" \
                                                and .Core.Version.Name==\"${VERSION}\" \
                                            )")"

if [[ -z "${COMPONENT_BLUEPRINT}" ]]; then
    error "Could not find ECS Task - Task: ${TASK} - Instance: ${INSTANCE} - Version: ${VERSION}"
    exit 255
fi

CLUSTER_ARN="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.State.Attributes.ECSHOST' )"

ENGINE="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.Configuration.Solution.Engine' )"
PLATFORM_VERSION="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.Configuration.Solution["aws:FargatePlatform"] | select (.!=null)' )"
if [[ -z "${PLATFORM_VERSION}" ]]; then
    PLATFORM_VERSION="LATEST"
fi

NETWORK_MODE="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.Configuration.Solution.NetworkMode' )"

DEFAULT_CONTAINER="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.Configuration.Solution.Containers | keys | .[0]' )"
TASK_DEFINITION_ID="-$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.State.ResourceGroups.default.Resources.task.Id' )-"

# Handle container name
if [[ -n "${CONTAINER_ID}" ]]; then
    CONTAINER="${CONTAINER_ID}"
else
    CONTAINER="${DEFAULT_CONTAINER%-*}"
fi

if [[ "${SEGMENT}" == "default" ]]; then
    SEGMENT=""
fi

TASK_DEFINITION_ARN="$(aws --region "${REGION}" ecs list-task-definitions --query "taskDefinitionArns[?contains(@, '${TASK_DEFINITION_ID}') == \`true\`]|[?contains(@, '${PRODUCT}-${ENVIRONMENT}-${SEGMENT}') == \`true\`] | [0]" --output text )"

info "Found the following task details \n * ClusterARN=${CLUSTER_ARN} \n * TaskDefinitionArn=${TASK_DEFINITION_ARN} \n * Container=${CONTAINER}"

# Check the cluster
if [[ -n "${CLUSTER_ARN}" ]]; then
    CLUSTER_STATUS="$(aws --region "${REGION}" ecs describe-clusters --clusters "${CLUSTER_ARN}" --output text --query 'clusters[0].status')"
    debug "Cluster Status ${CLUSTER_STATUS}"
    if [[ "${CLUSTER_STATUS}" != "ACTIVE" ]]; then
        fatal "ECS Cluster ${CLUSTER_ARN} could not be found or was not active"
        exit
    fi
else
    fatal "ECS Cluster not found - Component=${COMPONENT}"
    exit
fi

# Find the task definition
if [[ -z "${TASK_DEFINITION_ARN}" ]]; then
    fatal "Unable to locate task definition"
    exit
fi

# Configuration Overrides
CLI_CONFIGURATION="{}"

# Task hosting engine
case $ENGINE in
    fargate)
        CLI_CONFIGURATION="$( echo "${CLI_CONFIGURATION}" | jq --arg platformVersion "${PLATFORM_VERSION}" '. * { launchType: "FARGATE", platformVersion : $platformVersion  }' )"
        ;;
esac

# Task Networking
case $NETWORK_MODE in
    awsvpc)
        SECURITY_GROUP="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.State.Attributes.SECURITY_GROUP' )"
        SUBNET="$( echo "${COMPONENT_BLUEPRINT}" | jq -r '.State.Attributes.SUBNET' )"
        NETWORK_CONFIGURATION="$( echo "{}" | jq --arg sec_group "${SECURITY_GROUP}" --arg subnet "${SUBNET}" '. | { networkConfiguration : { awsvpcConfiguration : { subnets : [ $subnet ], securityGroups: [ $sec_group ]}}}' )"

        CLI_CONFIGURATION="$( echo "${CLI_CONFIGURATION}" | jq --argjson network "${NETWORK_CONFIGURATION}" '. * $network' )"
        ;;
esac

# Environment Var Configuration
if [[ -n "${ENV_NAMES}" && -n "${ENV_VALUES}" ]]; then

    ENV_CONFIG="[]"

    for i in "${!ENV_NAMES[@]}"; do
        ENV_NAME="${ENV_NAMES[$i]}"
        ENV_VALUE="${ENV_VALUES[$i]}"
        ENV_CONFIG="$(echo "${ENV_CONFIG}" | jq  --arg env_name "${ENV_NAME}" --arg env_value "${ENV_VALUE}" '. += [ { name : $env_name, value: $env_value } ]' )"
    done

    CLI_CONFIGURATION="$( echo "${CLI_CONFIGURATION}" | jq --arg container "${CONTAINER}" --argjson envvars "${ENV_CONFIG}" '. * { overrides : { containerOverrides : [ { name : $container, environment : $envvars }]}}' )"
fi

CLI_CONFIGURATION="$(echo "${CLI_CONFIGURATION}" | jq -c '.' )"

TASK_START="$(aws --region "${REGION}" ecs run-task --cluster "${CLUSTER_ARN}" --task-definition "${TASK_DEFINITION_ARN}" --count 1 ${TASK_ARGS} --cli-input-json "${CLI_CONFIGURATION}" --output json )"
TASK_ARN="$( echo "${TASK_START}" | jq -r '.tasks[0].taskArn' )"

info "Starting Task..."

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "null" ]]; then
    fatal "Task could not be started"
    echo "${TASK_START}"
    exit 255
fi

info "Watching task..."
CURRENT_RETRIES=0
while true; do
    LAST_STATUS="$(aws --region ${REGION} ecs describe-tasks --cluster "${CLUSTER_ARN}" --tasks "${TASK_ARN}" --query "tasks[?taskArn=='${TASK_ARN}'].lastStatus" --output text || break )"

    echo "...${LAST_STATUS}"

    if [[ "${LAST_STATUS}" == "STOPPED" ]]; then
        break
    fi

    CURRENT_RETRIES=$((CURRENT_RETRIES+1))

    if [[ "${CURRENT_RETRIES}" == "${RETRY_COUNT}" ]]; then
        fatal "Task has not completed in $(( RETRY_COUNT * DELAY )) seconds and has reached the DELAY and RETRY_COUNT limit"
        fatal "Stopping monitoring of the task - the task will keep running"
        exit 255
    fi

    sleep $DELAY
done

# Show the exit codes if they are not 0
TASK_FINAL_STATUS="$( aws --region "${REGION}" ecs describe-tasks --cluster "${CLUSTER_ARN}" --tasks "${TASK_ARN}" --query "tasks[?taskArn=='${TASK_ARN}'].{taskArn: taskArn, overrides: overrides, containers: containers }" || exit $? )"

info "Task Results"
echo "${TASK_FINAL_STATUS}"

# Use the exit status of the override container to determine the result
RESULT=$( echo "${TASK_FINAL_STATUS}" | jq -r ".[].containers[] | select(.name=\"${CONTAINER}\") | .exitCode" )
RESULT=${RESULT:-0}
