#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

REPO_OPERATION_CLONE="clone"
REPO_OPERATION_INIT="init"
REPO_OPERATION_PUSH="push"

# Defaults
REPO_OPERATION_DEFAULT="${REPO_OPERATION_PUSH}"
REPO_REMOTE_DEFAULT="origin"
REPO_BRANCH_DEFAULT="master"
DEFER_REPO_PUSH_DEFAULT="false"

function usage() {
    cat <<EOF

Manage git repos

Usage: $(basename $0) -l REPO_LOG_NAME -m REPO_MESSAGE -d REPO_DIR
        -u REPO_URL -n REPO_NAME -v REPO_PROVIDER
        -t REPO_TAG -r REPO_REMOTE -b REPO_BRANCH
        -s GIT_USER -e GIT_EMAIL -i -c -p

where

(o) -b REPO_BRANCH      is the repo branch
(o) -c (REPO_OPERATION=${REPO_OPERATION_CLONE}) clone repo
(m) -d REPO_DIR         is the directory containing the repo
(o) -e GIT_EMAIL        is the repo user email
    -h                  shows this text
(o) -i (REPO_OPERATION=${REPO_OPERATION_INIT}) initialise repo
(o) -l REPO_NAME        is the repo name for the git provider
(o) -m REPO_MESSAGE     is used as the commit/tag message
(m) -n REPO_LOG_NAME    to use in log messages
(o) -p (REPO_OPERATION=${REPO_OPERATION_PUSH}) commit local repo and push to origin
(o) -q DEFER_REPO_PUSH  saves the push details for a future push
(o) -r REPO_REMOTE      is the remote name for pushing
(o) -s GIT_USER         is the repo user
(o) -t REPO_TAG         is the tag to add after any commit
(o) -u REPO_URL         is the repo URL
(o) -v REPO_PROVIDER    is the repo git provider

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

REPO_OPERATION=${REPO_OPERATION_DEFAULT}
REPO_REMOTE=${REPO_REMOTE_DEFAULT}
REPO_BRANCH=${REPO_BRANCH_DEFAULT}

NOTES:

1. Initialise requires REPO_LOG_NAME and REPO_URL
2. Initialise does nothing if existing repo detected
3. Current branch is assumed when pushing
4. REPO_NAME and REPO_PROVIDER can be supplied as
   an alternative to REPO_URL

EOF
}

function init() {
    debug "Initialising the ${REPO_LOG_NAME} repo..."
    git status >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        # Convert directory into a repo
        git init .
    fi

    check_for_invalid_environment_variables "REPO_REMOTE" || return $?

    git remote show "${REPO_REMOTE}" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        check_for_invalid_environment_variables "REPO_URL" || return $?

        git remote add "${REPO_REMOTE}" "${REPO_URL}"
        RESULT=$?
        [[ ${RESULT} -ne 0 ]] &&
            fatal "Can't add remote ${REPO_REMOTE} to ${REPO_LOG_NAME} repo" && return 1
    fi

    git log -n 1 >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        # Create basic files
        echo -e "# ${REPO_LOG_NAME}" > README.md
        touch .gitignore LICENSE.md

        # Commit to repo in preparation for first push
        REPO_MESSAGE="${REPO_MESSAGE:-Initial commit}"
        push
    fi
}

function clone() {
    debug "Cloning the ${REPO_LOG_NAME} repo and checking out the ${REPO_BRANCH} branch ..."
    check_for_invalid_environment_variables "REPO_URL" "REPO_BRANCH" || return $?

    git clone -b "${REPO_BRANCH}" "${REPO_URL}" .
    RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Can't clone ${REPO_LOG_NAME} repo" && return 1
}

function push() {

    if ! git -C "${REPO_DIR}" rev-parse --is-inside-work-tree &>/dev/null; then
        warning "Directory ${REPO_DIR} is not part of a git repo - skipping push"
        return 0
    fi

    commit_stage_file="${COMMIT_CACHE_DIR}/commit_details.json"

    if [[ -f "${commit_stage_file}" ]]; then
        commit_details="$(cat "${commit_stage_file}" )"
    else
        mkdir -p "${COMMIT_CACHE_DIR}"
    fi

    if [[ -z "${commit_details}" ]]; then
        commit_details="{}"
    fi

    # Break the message in name/value pairs
    conventional_commit_base_body="$(format_conventional_commit_body "${REPO_MESSAGE}")"

    # Separate the values based on the conventional commit format
    conventional_commit_type="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "cctype" )"
    conventional_commit_scope="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "account product environment segment" )"
    conventional_commit_description="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "ccdesc" )"
    conventional_commit_body="$( format_conventional_commit_body_subset "${conventional_commit_base_body}" "cctype ccdesc account product environment segment" )"

    formatted_commit_message="$(format_conventional_commit \
        "${conventional_commit_type:-hamlet}" \
        "${conventional_commit_scope}" \
        "${conventional_commit_description:-automation}" \
        "${conventional_commit_body}" )"

    if [[ "${DEFER_REPO_PUSH,,}" == "true" ]]; then
        info "Deferred push saving details for the next requested push"

        commit_time="$( date -u +"%Y-%m-%dT%H:%M:%SZ" )"
        echo "${commit_details}" | jq --arg dir "${REPO_DIR}" --arg commit_time "${commit_time}" --arg msg "${REPO_MESSAGE}" '.dirs += [{"dir": $dir, "commit_time": $commit_time, "message": $msg }]' > "${commit_stage_file}"

        return 0
    else
        if [[ -s "${commit_stage_file}" ]]; then

            commit_msg_file="$( getTempFile XXXXXXX )"
            staged_commits="$( jq -r --arg dir "${REPO_DIR}" '.dirs[] | select(.dir == $dir) | .message' "${commit_stage_file}")"

            if [[ -n "${staged_commits}" ]]; then

                echo "${REPO_MESSAGE}" > "${commit_msg_file}"
                echo "${staged_commits}" >> "${commit_msg_file}"

                formatted_commit_message+=$'\n\n'

                while read msg; do
                    # Break the message in name/value pairs
                    conventional_commit_base_body="$(format_conventional_commit_body "${msg}")"

                    # Separate the values based on the conventional commit format
                    conventional_commit_type="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "cctype" )"
                    conventional_commit_scope="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "account product environment segment" )"
                    conventional_commit_description="$( format_conventional_commit_body_summary "${conventional_commit_base_body}" "ccdesc" )"
                    conventional_commit_body="$( format_conventional_commit_body_subset "${conventional_commit_base_body}" "cctype ccdesc account product environment segment" )"

                    formatted_commit_message+="$(format_conventional_commit \
                        "${conventional_commit_type:-hamlet}" \
                        "${conventional_commit_scope}" \
                        "${conventional_commit_description:-automation}" \
                        "${conventional_commit_body}" )"
                    formatted_commit_message+=$'\n--------\n'

                done < "${commit_msg_file}"
            fi
        fi
    fi

    check_for_invalid_environment_variables "GIT_USER" "GIT_EMAIL" "REPO_MESSAGE" "REPO_REMOTE" || return $?

    # Make sure we can access the remote and that the branch exists
    git ls-remote -q "${REPO_REMOTE}" "${REPO_BRANCH}" 1> /dev/null || return $?

    # Ensure git knows who we are
    git config user.name  "${GIT_USER}"
    git config user.email "${GIT_EMAIL}"

    # Add anything that has been added/modified/deleted
    git add -A

    if [[ -n "$(git status --porcelain)" ]]; then
        # Commit changes
        debug "Committing to the ${REPO_LOG_NAME} repo..."

        git commit -m "${formatted_commit_message}"
        RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Can't commit to the ${REPO_LOG_NAME} repo" && return 1

        REPO_PUSH_REQUIRED="true"
    else
        info "no changes to ${REPO_DIR}"
    fi

    # Tag the commit if required
    if [[ -n "${REPO_TAG}" ]]; then
        EXISTING_TAG=$(git ls-remote --tags 2>/dev/null | grep "refs/tags/${REPO_TAG}$")
        if [[ -n "${EXISTING_TAG}" ]]; then
            warning "Tag ${REPO_TAG} not added to the ${REPO_LOG_NAME} repo - it is already present"
        else
            debug "Adding tag \"${REPO_TAG}\" to the ${REPO_LOG_NAME} repo..."
            git tag -a "${REPO_TAG}" -m "${REPO_MESSAGE}"
            RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Can't tag the ${REPO_LOG_NAME} repo" && return 1

            REPO_PUSH_REQUIRED="true"
        fi
    fi

    # Update upstream repo
    GENERATION_REPO_PUSH_RETRIES="${GENERATION_REPO_PUSH_RETRIES:-6}"
    REPO_PUSHED=false
    HEAD_DETACHED=false
    if [[ "${REPO_PUSH_REQUIRED}" == "true" ]]; then
        for TRY in $( seq 1 ${GENERATION_REPO_PUSH_RETRIES} ); do
            # Check if remote branch exists
            EXISTING_BRANCH=$(git ls-remote --heads 2>/dev/null | grep "refs/heads/${REPO_BRANCH}$")
            if [[ -n "${EXISTING_BRANCH}" ]]; then
                debug "Rebasing ${REPO_LOG_NAME} in case of changes..."
                git pull --rebase ${REPO_REMOTE} ${REPO_BRANCH}
                RESULT=$? && [[ ${RESULT} -ne 0 ]] && \
                    fatal "Can't rebase the ${REPO_LOG_NAME} repo from upstream ${REPO_REMOTE}" && return 1
            fi

            debug "Pushing the ${REPO_LOG_NAME} repo upstream..."
            git symbolic-ref -q HEAD
            RESULT=$? && [[ ${RESULT} -ne 0 ]] && HEAD_DETACHED=true
            if [[ "${HEAD_DETACHED}" == "false" ]]; then
                git push --tags ${REPO_REMOTE} ${REPO_BRANCH} && REPO_PUSHED=true && break || \
                  info "Waiting to retry push to ${REPO_LOG_NAME} repo ..." && sleep 5
            else
              # If push failed HEAD might be detached. Create a temp branch and merge it to the target to fix it.
                git branch temp-${REPO_BRANCH} && \
                git checkout ${REPO_BRANCH} && \
                git merge temp-${REPO_BRANCH} && \
                git branch -D temp-${REPO_BRANCH} && \
                git push --tags ${REPO_REMOTE} ${REPO_BRANCH} && REPO_PUSHED=true
            fi
        done
        if [[ "${REPO_PUSHED}" == "false" ]]; then
            fatal "Can't push the ${REPO_LOG_NAME} repo changes to upstream repo ${REPO_REMOTE}" && return 1
        fi
    fi

    # Removing commits which have been pushed
    if [[ -s "${commit_stage_file}" ]]; then
        remaining_commits="$(jq --arg dir "${REPO_DIR}" 'del(.dirs[] | select(.dir == $dir))' "${commit_stage_file}")"
        echo "${remaining_commits}" > "${commit_stage_file}"
    fi
}

# Define git provider attributes
# $1 = provider
# $2 = variable prefix
function defineGitProviderAttributes() {
    DGPA_PROVIDER="${1^^}"
    DGPA_PREFIX="${2^^}"

    # Attribute variable names
    for DGPA_ATTRIBUTE in "DNS" "API_DNS" "ORG" "CREDENTIALS_VAR"; do
        DGPA_PROVIDER_VAR="${DGPA_PROVIDER}_GIT_${DGPA_ATTRIBUTE}"
        declare -g ${DGPA_PREFIX}_${DGPA_ATTRIBUTE}="${!DGPA_PROVIDER_VAR}"
    done
}

function set_context() {
  # Parse options
  while getopts ":b:cd:e:hil:m:n:pqr:s:t:u:v:" opt; do
      case $opt in
          b) REPO_BRANCH="${OPTARG}" ;;
          c) REPO_OPERATION="${REPO_OPERATION_CLONE}" ;;
          d) REPO_DIR="${OPTARG}" ;;
          e) GIT_EMAIL="${OPTARG}" ;;
          h) usage; return 1 ;;
          i) REPO_OPERATION="${REPO_OPERATION_INIT}" ;;
          l) REPO_LOG_NAME="${OPTARG}" ;;
          m) REPO_MESSAGE="${OPTARG}" ;;
          n) REPO_NAME="${OPTARG}" ;;
          p) REPO_OPERATION="${REPO_OPERATION_PUSH}" ;;
          q) DEFER_REPO_PUSH="true" ;;
          r) REPO_REMOTE="${OPTARG}" ;;
          s) GIT_USER="${OPTARG}" ;;
          t) REPO_TAG="${OPTARG}" ;;
          u) REPO_URL="${OPTARG}" ;;
          v) REPO_PROVIDER="${OPTARG}" ;;
          \?) fatalOption; return 1 ;;
          :) fatalOptionArgument; return 1 ;;
       esac
  done

  # Apply defaults
  DEFER_REPO_PUSH="${DEFER_REPO_PUSH:-${DEFER_REPO_PUSH_DEFAULT}}"
  REPO_OPERATION="${REPO_OPERATION:-${REPO_OPERATION_DEFAULT}}"
  REPO_REMOTE="${REPO_REMOTE:-${REPO_REMOTE_DEFAULT}}"
  REPO_BRANCH="${REPO_BRANCH:-${REPO_BRANCH_DEFAULT}}"
  if [[ -z "${REPO_URL}" ]]; then
    if [[ (-n "${REPO_PROVIDER}") &&
            (-n "${REPO_NAME}") ]]; then
      defineGitProviderAttributes "${REPO_PROVIDER}" "REPO_PROVIDER"
      if [[ -n "${!REPO_PROVIDER_CREDENTIALS_VAR}" ]]; then
        REPO_URL="https://${!REPO_PROVIDER_CREDENTIALS_VAR}@${REPO_PROVIDER_DNS}/${REPO_PROVIDER_ORG}/${REPO_NAME}"
      else
        REPO_URL="https://${REPO_PROVIDER_DNS}/${REPO_PROVIDER_ORG}/${REPO_NAME}"
      fi
    fi
  fi

  # Ensure mandatory arguments have been provided
  check_for_invalid_environment_variables "REPO_DIR" "REPO_LOG_NAME" || return $?

  # Ensure we are inside the repo directory
  if [[ ! -d "${REPO_DIR}" ]]; then
    mkdir -p "${REPO_DIR}"
    RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Can't create repo directory ${REPO_DIR}" && return 1
  fi

  return 0
}

function main() {

  set_context "$@" || return 1

  cd "${REPO_DIR}"

  # Perform the required action
  case ${REPO_OPERATION} in
    ${REPO_OPERATION_INIT})  init || return $? ;;
    ${REPO_OPERATION_CLONE}) clone || return $? ;;
    ${REPO_OPERATION_PUSH})  push || return $? ;;
  esac

  # All good
  RESULT=0
  return 0
}

main "$@"
