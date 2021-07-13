#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

# Defaults
DOCKER_TAG_DEFAULT="latest"
DOCKER_IMAGE_SOURCE_REMOTE="remote"
DOCKER_IMAGE_SOURCE_DEFAULT="${DOCKER_IMAGE_SOURCE_REMOTE}"
DOCKER_OPERATION_BUILD="build"
DOCKER_OPERATION_VERIFY="verify"
DOCKER_OPERATION_TAG="tag"
DOCKER_OPERATION_PULL="pull"
DOCKER_OPERATION_DEFAULT="${DOCKER_OPERATION_VERIFY}"
DOCKER_CONTEXT_DIR_DEFAULT="${AUTOMATION_BUILD_DIR}"

function usage() {
    cat <<EOF

Manage docker images

Usage: $(basename $0) -b -v -p -k
                        -a DOCKER_PROVIDER
                        -c REGISTRY_SCOPE
                        -l DOCKER_REPO
                        -t DOCKER_TAG
                        -z REMOTE_DOCKER_PROVIDER
                        -i REMOTE_DOCKER_REPO
                        -r REMOTE_DOCKER_TAG
                        -u DOCKER_IMAGE_SOURCE
                        -d DOCKER_PRODUCT
                        -s DOCKER_DEPLOYMENT_UNIT
                        -g DOCKER_CODE_COMMIT

where

(o) -a DOCKER_PROVIDER          is the local docker provider
(o) -b                          perform docker build and save in local registry
(o) -c REGISTRY_SCOPE           is the registry scope
(o) -d DOCKER_PRODUCT           is the product to use when defaulting DOCKER_REPO
(o) -g DOCKER_CODE_COMMIT       to use when defaulting DOCKER_REPO
    -h                          shows this text
(o) -i REMOTE_DOCKER_REPO       is the repository to pull
(o) -k                          tag an image in the local registry with the remote details
(o) -l DOCKER_REPO              is the local repository
(o) -p                          pull image from a remote to a local registry
(o) -r REMOTE_DOCKER_TAG        is the tag to pull
(o) -s DOCKER_DEPLOYMENT_UNIT   is the deployment unit to use when defaulting DOCKER_REPO
(o) -t DOCKER_TAG               is the local tag
(o) -u DOCKER_IMAGE_SOURCE      is the registry to pull from
(o) -v                          verify image is present in local registry
(o) -w DOCKER_LOCAL_REPO        local image that will be copied based on registry naming
(o) -x DOCKER_CONTEXT_DIR       set the local context dir during builds
(o) -y DOCKERFILE               set the dockerfile to use during builds
(o) -z REMOTE_DOCKER_PROVIDER   is the docker provider to pull from

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

DOCKER_PROVIDER=${PRODUCT_DOCKER_PROVIDER}
DOCKER_REPO="DOCKER_PRODUCT/DOCKER_DEPLOYMENT_UNIT-DOCKER_CODE_COMMIT" or
            "DOCKER_PRODUCT/DOCKER_CODE_COMMIT" if no DOCKER_DEPLOYMENT_UNIT defined
DOCKER_TAG=${DOCKER_TAG_DEFAULT}
REMOTE_DOCKER_PROVIDER=${PRODUCT_REMOTE_DOCKER_PROVIDER}
REMOTE_DOCKER_REPO=DOCKER_REPO
REMOTE_DOCKER_TAG=DOCKER_TAG
DOCKER_IMAGE_SOURCE=${DOCKER_IMAGE_SOURCE_DEFAULT}
DOCKER_OPERATION=${DOCKER_OPERATION_DEFAULT}
DOCKER_PRODUCT=${PRODUCT}
DOCKER_CONTEXT_DIR=${DOCKER_CONTEXT_DIR_DEFAULT}

NOTES:

1. DOCKER_IMAGE_SOURCE can be "remote" or "dockerhub"

EOF
    exit
}

function options() {

    # Parse options
    while getopts ":a:bc:d:g:hki:l:pr:s:t:u:vw:x:y:z:" opt; do
        case $opt in
            a)
                DOCKER_PROVIDER="${OPTARG}"
                ;;
            b)
                DOCKER_OPERATION="${DOCKER_OPERATION_BUILD}"
                ;;
            c)
                REGISTRY_SCOPE="${OPTARG}"
                ;;
            d)
                DOCKER_PRODUCT="${OPTARG}"
                ;;
            g)
                DOCKER_CODE_COMMIT="${OPTARG}"
                ;;
            h)
                usage
                ;;
            i)
                REMOTE_DOCKER_REPO="${OPTARG}"
                ;;
            k)
                DOCKER_OPERATION="${DOCKER_OPERATION_TAG}"
                ;;
            l)
                DOCKER_REPO="${OPTARG}"
                ;;
            p)
                DOCKER_OPERATION="${DOCKER_OPERATION_PULL}"
                ;;
            r)
                REMOTE_DOCKER_TAG="${OPTARG}"
                ;;
            s)
                DOCKER_DEPLOYMENT_UNIT="${OPTARG}"
                ;;
            t)
                DOCKER_TAG="${OPTARG}"
                ;;
            u)
                DOCKER_IMAGE_SOURCE="${OPTARG}"
                ;;
            v)
                DOCKER_OPERATION="${DOCKER_OPERATION_VERIFY}"
                ;;
            w)
                DOCKER_LOCAL_REPO="${OPTARG}"
                ;;
            x)
                DOCKER_CONTEXT_DIR="${OPTARG}"
                ;;
            y)
                DOCKERFILE="${OPTARG}"
                ;;
            z)
                REMOTE_DOCKER_PROVIDER="${OPTARG}"
                ;;
            \?)
                fatalOption
                ;;
            :)
                fatalOptionArgument
                ;;
        esac
    done

    # Apply local registry defaults
    DOCKER_PROVIDER="${DOCKER_PROVIDER:-${PRODUCT_DOCKER_PROVIDER}}"
    DOCKER_TAG="${DOCKER_TAG:-${DOCKER_TAG_DEFAULT}}"
    DOCKER_IMAGE_SOURCE="${DOCKER_IMAGE_SOURCE:-${DOCKER_IMAGE_SOURCE_DEFAULT}}"
    DOCKER_OPERATION="${DOCKER_OPERATION:-${DOCKER_OPERATION_DEFAULT}}"
    DOCKER_PRODUCT="${DOCKER_PRODUCT:-${PRODUCT}}"
    DOCKER_CONTEXT_DIR="${DOCKER_CONTEXT_DIR:-${DOCKER_CONTEXT_DIR_DEFAULT}}"
}

function dockerLogin() {
    local registry="${1}"; shift
    local provider="${1}"; shift
    local user="${1}"; shift
    local password="${1}"; shift

    case "${registry}" in
        *.amazonaws.com)

            local registry_region="$(cut -d '.' -f 4 <<< "${registry}")"
            aws ecr get-login-password --region "${registry_region}" \
                | docker login --username AWS --password-stdin "${registry}"
            ;;

        *)
            docker login -u "${user}" -p "${password}" "${registry}"
            ;;
    esac
}

function imagePresent() {
    local registry="${1}"; shift
    local repository="${1}"; shift
    local tag="${1}"; shift
    local docker_registry_api_hostname="${1}"; shift
    local user_name="${1}"; shift
    local password="${1}"; shift

    case "${registry}" in
        *.amazonaws.com)

            local registry_region="$(cut -d '.' -f 4 <<< "${registry}")"
            local registry_account="$(cut -d '.' -f 1 <<< "${registry}")"
            if [[ -n "$( aws --region "${registry_region}" ecr list-images --registry-id "${registry_account}" --repository-name "${repository}" --filter "tagStatus=TAGGED" --query "imageIds[?imageTag=='${tag}'].imageDigest" --output text )" ]]; then
                return 0
            else
                return 1
            fi
            ;;

        *)
            # Be careful of @ characters in the username or password
            local user_name="$(sed "s/@/%40/g" <<< ${user_name})"
            local password="$(sed "s/@/%40/g" <<< ${password})"

            if [[ -n "$(curl -s https://${user_name}:${password}@${docker_registry_api_hostname}/v1/repositories/${repository}/tags | jq ".[\"${tag}\"] | select(.!=null)" )" ]]; then
                return 0
            else
                return 1
            fi
            ;;
    esac

    return 1
}

# Perform logic required to create a repository depending on the registry implementation
function createRepository() {
    local registry="${1}"; shift
    local repository="${1}"; shift

    case "${registry}" in
        *.amazonaws.com)

            local registry_region="$(cut -d '.' -f 4 <<< "${registry}")"
            local registry_account="$(cut -d '.' -f 1 <<< "${registry}")"

            if [[ -z "$(aws --region "${registry_region}" ecr describe-repositories --registry-id "${registry_account}" --query "repositories[?repositoryName=='${repository}'].repositoryName" --output text || return $?)" ]]; then
                # Not there yet so create it
                aws --region ${registry_region} ecr create-repository --repository-name "${repository}" || return $?
            fi
            ;;
        *)
            warn "Cannot create repository for the reigstry ${registry}"
            warn "Ensure the repository is available to push to"
            ;;
    esac
}

# Define docker provider attributes
# $1 = provider
# $2 = variable prefix
function defineDockerProviderAttributes() {
    DDPA_PROVIDER="${1^^}"
    DDPA_PREFIX="${2^^}"

    # Direct variable names
    for DDPA_ATTRIBUTE in "DNS" "API_DNS"; do
        DDPA_PROVIDER_VAR="${DDPA_PROVIDER}_DOCKER_${DDPA_ATTRIBUTE}"
        declare -g ${DDPA_PREFIX}_${DDPA_ATTRIBUTE}="${!DDPA_PROVIDER_VAR}"
    done

    # Indirect variable names
    for DDPA_ATTRIBUTE in "USER_VAR" "PASSWORD_VAR"; do
        DDPA_PROVIDER_VAR="${DDPA_PROVIDER}_DOCKER_${DDPA_ATTRIBUTE}"
        if [[ -n "${!DDPA_PROVIDER_VAR}" ]]; then
            declare -g ${DDPA_PREFIX}_${DDPA_ATTRIBUTE}="${!DDPA_PROVIDER_VAR}"
        else
            declare -g ${DDPA_PREFIX}_${DDPA_ATTRIBUTE}="EMPTY_VAR"
        fi
    done
}

function main() {

  options "$@" || return $?

    # Set credentials for the local provider
    . ${AUTOMATION_DIR}/setCredentials.sh "${DOCKER_PROVIDER}"

    # Handle registry scope values
    REGISTRY_SUBTYPE=""
    case "${REGISTRY_SCOPE}" in
        account)
            if [[ -n "${ACCOUNT}" ]]; then
                DOCKER_PRODUCT="account"
            fi
            ;;
        segment)
            if [[ -n "${SEGMENT}" ]]; then
                REGISTRY_SUBTYPE="-${SEGMENT}"
            else
                fatal "Segment scoped registry required but SEGMENT not defined" && RESULT=1 && exit
            fi
            ;;
        *)
            [[ "${REGISTRY_SCOPE:-unset}" != "unset" && "${REGISTRY_SCOPE}" != "?" ]] && REGISTRY_SUBTYPE="-${REGISTRY_SCOPE}"
            ;;
    esac

    # Default local repository is based on standard image naming conventions
    if [[ (-n "${DOCKER_PRODUCT}") &&
            (-n "${DOCKER_CODE_COMMIT}") ]]; then
        if [[ (-n "${DOCKER_DEPLOYMENT_UNIT}" ) ]]; then
            DOCKER_REPO="${DOCKER_REPO:-${DOCKER_PRODUCT}${REGISTRY_SUBTYPE}/${DOCKER_DEPLOYMENT_UNIT}-${DOCKER_CODE_COMMIT}}"
        else
            DOCKER_REPO="${DOCKER_REPO:-${DOCKER_PRODUCT}${REGISTRY_SUBTYPE}/${DOCKER_CODE_COMMIT}}"
        fi
    fi

    # Determine docker provider details
    defineDockerProviderAttributes "${DOCKER_PROVIDER}" "DOCKER_PROVIDER"

    # Ensure the local repository has been determined
    [[ -z "${DOCKER_REPO}" ]] &&
        fatal "Job requires the local repository name, or the product/deployment unit/commit" && RESULT=1 && exit

    # Apply remote registry defaults
    REMOTE_DOCKER_PROVIDER="${REMOTE_DOCKER_PROVIDER:-${PRODUCT_REMOTE_DOCKER_PROVIDER}}"
    REMOTE_DOCKER_REPO="${REMOTE_DOCKER_REPO:-$DOCKER_REPO}"
    REMOTE_DOCKER_TAG="${REMOTE_DOCKER_TAG:-$DOCKER_TAG}"

    # Determine remote docker provider details
    defineDockerProviderAttributes "${REMOTE_DOCKER_PROVIDER}" "REMOTE_DOCKER_PROVIDER"

    # pull = tag if local provider = remote provider
    if [[ ("${DOCKER_PROVIDER}" == "${REMOTE_DOCKER_PROVIDER}") &&
            ("${DOCKER_OPERATION}" == "${DOCKER_OPERATION_PULL}") ]]; then
        DOCKER_OPERATION="${DOCKER_OPERATION_TAG}"
    fi

    # Formulate the local registry details
    DOCKER_IMAGE="${DOCKER_REPO}:${DOCKER_TAG}"
    FULL_DOCKER_IMAGE="${DOCKER_PROVIDER_DNS}/${DOCKER_IMAGE}"

    # Confirm access to the local registry
    dockerLogin ${DOCKER_PROVIDER_DNS} ${DOCKER_PROVIDER} ${!DOCKER_PROVIDER_USER_VAR} ${!DOCKER_PROVIDER_PASSWORD_VAR}
    RESULT=$?
    [[ "$RESULT" -ne 0 ]] && fatal "Can't log in to ${DOCKER_PROVIDER_DNS}" && RESULT=1 && exit

    # Perform the required action
    case ${DOCKER_OPERATION} in
        ${DOCKER_OPERATION_BUILD})
            if [[ -z "${DOCKER_LOCAL_REPO}" ]]; then
                # Locate the Dockerfile
                DOCKERFILE="${DOCKERFILE:-"./Dockerfile"}"
                if [[ -f "${AUTOMATION_BUILD_DEVOPS_DIR}/docker/Dockerfile" ]]; then
                    DOCKERFILE="${AUTOMATION_BUILD_DEVOPS_DIR}/docker/Dockerfile"
                fi

                # Permit an explicit override relative to the AUTOMATION_BUILD_SRC_DIR
                if [[ -n "${DOCKER_FILE}" && -f "${AUTOMATION_DATA_DIR}/${DOCKER_FILE}" ]]; then
                    DOCKERFILE="${AUTOMATION_DATA_DIR}/${DOCKER_FILE}"
                fi

                if [[ -n ${DOCKER_GITHUB_SSH_KEY_FILE} ]]; then
                    if [[ -f "${DOCKER_GITHUB_SSH_KEY_FILE}" ]]; then
                        # Perform the build
                        info "build docker image with SSH_KEY argument"
                        docker build -t "${FULL_DOCKER_IMAGE}" -f "${DOCKERFILE}" "${DOCKER_CONTEXT_DIR}" --build-arg SSH_KEY="$(cat ${DOCKER_GITHUB_SSH_KEY_FILE})"
                        RESULT=$?
                    else
                        fatal "Unable to locate github ssh key file for the docker image" && RESULT=1 && exit
                    fi
                else
                    # Perform the build
                    docker build -t "${FULL_DOCKER_IMAGE}" -f "${DOCKERFILE}" "${DOCKER_CONTEXT_DIR}"
                    RESULT=$?
                fi

                [[ $RESULT -ne 0 ]] && fatal "Cannot build image ${DOCKER_IMAGE}" && RESULT=1 && exit
            else
                # Use a local image to create a registry docker image
                docker tag "${DOCKER_LOCAL_REPO}" "${FULL_DOCKER_IMAGE}"
            fi

            createRepository ${DOCKER_PROVIDER_DNS} ${DOCKER_REPO}
            RESULT=$?
            [[ $RESULT -ne 0 ]] &&
                fatal "Unable to create repository ${DOCKER_REPO} in the local registry" && RESULT=1 && exit

            docker push ${FULL_DOCKER_IMAGE}
            RESULT=$?
            [[ $RESULT -ne 0 ]] &&
                fatal "Unable to push ${DOCKER_IMAGE} to the local registry" && RESULT=1 && exit
            ;;

        ${DOCKER_OPERATION_VERIFY})
            # Check whether the image is already in the local registry
            # Use the docker API to avoid having to download the image to verify its existence
            if imagePresent "${DOCKER_PROVIDER_DNS}" "${DOCKER_REPO}" "${DOCKER_TAG}" "${DOCKER_PROVIDER_API_DNS}" "${!DOCKER_PROVIDER_USER_VAR}" "${!DOCKER_PROVIDER_PASSWORD_VAR}"; then
                RESULT=0
                info "Docker image ${DOCKER_IMAGE} present in the local registry"
            else
                RESULT=1
                info "Docker image ${DOCKER_IMAGE} not present in local registry"
            fi
            ;;

        ${DOCKER_OPERATION_TAG})
            # Formulate the tag details
            REMOTE_DOCKER_IMAGE="${REMOTE_DOCKER_REPO}:${REMOTE_DOCKER_TAG}"
            FULL_REMOTE_DOCKER_IMAGE="${DOCKER_PROVIDER_DNS}/${REMOTE_DOCKER_IMAGE}"

            # Pull in the local image
            docker pull ${FULL_DOCKER_IMAGE}
            RESULT=$?
            if [[ "$RESULT" -ne 0 ]]; then
                error "Can't pull ${DOCKER_IMAGE} from ${DOCKER_PROVIDER_DNS}"
            else
                # Tag the image ready to push to the registry
                docker tag ${FULL_DOCKER_IMAGE} ${FULL_REMOTE_DOCKER_IMAGE}
                RESULT=$?
                if [[ "$?" -ne 0 ]]; then
                    error "Couldn't tag image ${FULL_DOCKER_IMAGE} with ${FULL_REMOTE_DOCKER_IMAGE}"
                else
                    # Push to registry
                    createRepository ${DOCKER_PROVIDER_DNS} ${REMOTE_DOCKER_REPO}
                    RESULT=$?
                    if [[ $RESULT -ne 0 ]]; then
                        error "Unable to create repository ${REMOTE_DOCKER_REPO} in the local registry"
                    else
                        docker push ${FULL_REMOTE_DOCKER_IMAGE}
                        RESULT=$?
                        [[ $RESULT -ne 0 ]] &&
                            error "Unable to push ${REMOTE_DOCKER_IMAGE} to the local registry"
                    fi
                fi
            fi
            ;;

        ${DOCKER_OPERATION_PULL})
            # Formulate the remote registry details
            REMOTE_DOCKER_IMAGE="${REMOTE_DOCKER_REPO}:${REMOTE_DOCKER_TAG}"

            case ${DOCKER_IMAGE_SOURCE} in
                ${DOCKER_IMAGE_SOURCE_REMOTE})

                    # Set credentials for the remote provider
                    . ${AUTOMATION_DIR}/setCredentials.sh "${REMOTE_DOCKER_PROVIDER}"

                    FULL_REMOTE_DOCKER_IMAGE="${REMOTE_DOCKER_PROVIDER_DNS}/${REMOTE_DOCKER_IMAGE}"

                    # Confirm access to the remote registry
                    dockerLogin ${REMOTE_DOCKER_PROVIDER_DNS} ${REMOTE_DOCKER_PROVIDER} ${!REMOTE_DOCKER_PROVIDER_USER_VAR} ${!REMOTE_DOCKER_PROVIDER_PASSWORD_VAR}
                    RESULT=$?
                    [[ "$RESULT" -ne 0 ]] &&
                        fatal "Can't log in to ${REMOTE_DOCKER_PROVIDER_DNS}" && RESULT=1 && exit
                    ;;

                *)
                    # Docker utility defaults to dockerhub if no registry provided to a pull command
                    FULL_REMOTE_DOCKER_IMAGE="${REMOTE_DOCKER_IMAGE}"
                    ;;
            esac

            # Pull in the remote image
            docker pull ${FULL_REMOTE_DOCKER_IMAGE}
            RESULT=$?
            if [[ "$RESULT" -ne 0 ]]; then
                error "Can't pull ${REMOTE_DOCKER_IMAGE} from ${DOCKER_IMAGE_SOURCE}"
            else
                # Tag the image ready to push to the registry
                docker tag ${FULL_REMOTE_DOCKER_IMAGE} ${FULL_DOCKER_IMAGE}
                RESULT=$?
                if [[ "$RESULT" -ne 0 ]]; then
                    error "Couldn't tag image ${FULL_REMOTE_DOCKER_IMAGE} with ${FULL_DOCKER_IMAGE}"
                else
                    # Push to registry

                    # Set credentials for the local provider
                    . ${AUTOMATION_DIR}/setCredentials.sh "${DOCKER_PROVIDER}"

                    createRepository ${DOCKER_PROVIDER_DNS} ${DOCKER_REPO}
                    RESULT=$?
                    if [[ $RESULT -ne 0 ]]; then
                        error "Unable to create repository ${DOCKER_REPO} in the local registry"
                    else
                        docker push ${FULL_DOCKER_IMAGE}
                        RESULT=$?
                        [[ "$RESULT" -ne 0 ]] &&
                            error "Unable to push ${DOCKER_IMAGE} to the local registry"
                    fi
                fi
            fi
            ;;

        *)
            fatal "Unknown operation \"${DOCKER_OPERATION}\"" && RESULT=1 && exit
            ;;
    esac

    IMAGEID=$(docker images | grep "${REMOTE_DOCKER_REPO}" | grep "${REMOTE_DOCKER_TAG}" | head -1 |awk '{print($3)}')
    [[ "${IMAGEID}" != "" ]] && docker rmi -f ${IMAGEID}

    IMAGEID=$(docker images | grep "${DOCKER_REPO}" | grep "${DOCKER_TAG}" | head -1 |awk '{print($3)}')
    [[ "${IMAGEID}" != "" ]] && docker rmi -f ${IMAGEID}

    # The RESULT variable is not explicitly set here so result of operation
    # can be returned after image cleanup.

    return 0
}

main "$@"
