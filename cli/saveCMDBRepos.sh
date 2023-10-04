#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

. "${GENERATION_BASE_DIR}/execution/common.sh"

ACCOUNT_REPOS_DEFAULT="false"
PRODUCT_REPOS_DEFAULT="false"

function options() {

    # Parse options
    while getopts ":ahm:pr:t:" option; do
        case "${option}" in
        a) ACCOUNT_REPOS="true" ;;
        h)
            usage
            return 1
            ;;
        m) COMMIT_MESSAGE="${OPTARG}" ;;
        p) PRODUCT_REPOS="true" ;;
        r) REFERENCE="${OPTARG}" ;;
        t) TAG="${OPTARG}" ;;
        \?)
            fatalOption
            return 1
            ;;
        esac
    done

    ACCOUNT_REPOS="${ACCOUNT_REPOS:-${ACCOUNT_REPOS_DEFAULT}}"
    PRODUCT_REPOS="${PRODUCT_REPOS:-${PRODUCT_REPOS_DEFAULT}}"

    exit_on_invalid_environment_variables "COMMIT_MESSAGE"

    return 0
}

function usage() {
    cat <<EOF

DESCRIPTION:
  save the current state of cmdbs to their repositories

USAGE:
  $(basename $0)

PARAMETERS:

  (o) -a                         includes account repositories
      -h                         shows this text
  (m) -m  COMMIT_MESSAGE         the commit message to use for the save
  (o) -p                         includes product repositories
  (o) -r                         the reference branch to commit changes to
  (o) -t                         the tag to apply

  (m) mandatory, (o) optional, (d) deprecated

DEFAULTS:


NOTES:


EOF
}

function commit_tag_push() {
    repo_branch="${1}"
    shift
    repo_dir="${1}"
    shift
    repo_message="${1}"
    shift
    defer_repo_push="${1}"
    shift
    repo_remote="${1}"
    shift
    repo_tag="${1}"
    shift

    # Ensure we are inside the repo directory
    if [[ ! -d "${repo_dir}" ]]; then
        fatal "directory provided for repo_dir \"${repo_dir}\" does not exist"
        return 1
    fi

    if ! git -C "${repo_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
        warning "Directory ${repo_dir} is not part of a git repo - skipping push"
        return 0
    fi

    # Break the message in name/value pairs
    conventional_commit_base_body="$(format_conventional_commit_body "${repo_message}")"

    # Separate the values based on the conventional commit format
    conventional_commit_type="$(format_conventional_commit_body_summary "${conventional_commit_base_body}" "cctype")"
    conventional_commit_scope="$(format_conventional_commit_body_summary "${conventional_commit_base_body}" "account product environment segment")"
    conventional_commit_description="$(format_conventional_commit_body_summary "${conventional_commit_base_body}" "ccdesc")"
    conventional_commit_body="$(format_conventional_commit_body_subset "${conventional_commit_base_body}" "cctype ccdesc account product environment segment")"

    formatted_commit_message="$(format_conventional_commit \
        "${conventional_commit_type:-hamlet}" \
        "${conventional_commit_scope}" \
        "${conventional_commit_description:-automation}" \
        "${conventional_commit_body}")"

    # Extract relevant events and remove the event log
    repo_event_log="$(getTempFile XXXXXXX)"

    pull_events_from_state "directory" "$(git -C "${repo_dir}" rev-parse --show-toplevel)" "${repo_event_log}" "starts_with"

    if [[ -s "${repo_event_log}" ]]; then

        commit_logs=("$(jq -rc '.events[] | del(._id, .directory)' "${repo_event_log}")")

        if [[ -n "${commit_logs}" ]]; then

            formatted_commit_message+=$'\n\n'

            while read msg; do
                formatted_commit_message+="$(echo "${msg}" | jq -r 'to_entries|map("\(.key):  \(.value|tostring)")|.[]')"
                formatted_commit_message+=$'\n--------\n\n'

            done <<<"${commit_logs}"
        fi
    fi

    # Make sure we can access the remote and that the branch exists
    git -C "${repo_dir}" ls-remote -q "${repo_remote}" "${repo_branch}" 1>/dev/null || return $?

    # Add anything that has been added/modified/deleted
    git -C "${repo_dir}" add -A

    if [[ -n "$(git -C "${repo_dir}" status --porcelain)" ]]; then
        # Commit changes
        debug "Committing changes"

        if ! git -C "${repo_dir}" commit -m "${formatted_commit_message}"; then
            fatal "Can't commit to the repo"
            return 1
        fi

        REPO_PUSH_REQUIRED="true"
    else
        info "no changes to ${repo_dir}"
    fi

    # Tag the commit if required
    if [[ -n "${repo_tag}" ]]; then
        EXISTING_TAG=$(git -C "${repo_dir}" ls-remote --tags 2>/dev/null | grep "refs/tags/${repo_tag}$")
        if [[ -n "${EXISTING_TAG}" ]]; then
            warning "Tag ${repo_tag} is already present - skipping tag "
        else
            debug "Adding tag \"${repo_tag}\""
            if ! git -C "${repo_dir}" tag -a "${repo_tag}" -m "${repo_message}"; then
                fatal "Can't create tag"
                return 1
            fi

            REPO_PUSH_REQUIRED="true"
        fi
    fi

    # Update upstream repo
    GENERATION_REPO_PUSH_RETRIES="${GENERATION_REPO_PUSH_RETRIES:-6}"
    REPO_PUSHED=false
    if [[ ("${defer_repo_push}" != "true") && ("${REPO_PUSH_REQUIRED}" == "true") ]]; then
        for TRY in $(seq 1 ${GENERATION_REPO_PUSH_RETRIES}); do
            # Check if remote branch exists
            EXISTING_BRANCH=$(git -C "${repo_dir}" ls-remote --heads 2>/dev/null | grep "refs/heads/${repo_branch}$")
            if [[ -n "${EXISTING_BRANCH}" ]]; then
                debug "Rebasing in case of changes"
                if ! git -C "${repo_dir}" pull --rebase ${repo_remote} ${repo_branch}; then
                    fatal "Can't rebase from upstream ${repo_remote}"
                    return 1
                fi
            fi

            debug "Pushing the repo upstream"
            if git -C "${repo_dir}" symbolic-ref -q HEAD; then
                if git -C "${repo_dir}" push --tags ${repo_remote} ${repo_branch}; then
                    REPO_PUSHED=true
                    break
                else
                    info "Waiting to retry push"
                    sleep 5
                fi
            else
                # If push failed HEAD might be detached. Create a temp branch and merge it to the target to fix it.
                git -C "${repo_dir}" branch temp-${repo_branch} &&
                    git -C "${repo_dir}" checkout ${repo_branch} &&
                    git -C "${repo_dir}" merge temp-${repo_branch} &&
                    git -C "${repo_dir}" branch -D temp-${repo_branch} &&
                    git -C "${repo_dir}" push --tags ${repo_remote} ${repo_branch} && REPO_PUSHED=true
            fi
        done
        if [[ "${REPO_PUSHED}" == "false" ]]; then
            fatal "Can't push the to upstream repo ${repo_remote}"
            return 1
        fi
    fi

    # All good
    return 0
}

function save_repo() {
    local directory="$1"
    shift
    local message="$1"
    shift
    local reference="$1"
    shift
    local tag="$1"
    shift

    commit_tag_push "${reference:-"master"}" "${directory}" "${message}" "${DEFER_REPO_PUSH:-"false"}" "${REPO_REMOTE:-"origin"}" "${tag}"
}

function save_product_config() {
    local arguments=("$@")

    save_repo "${PRODUCT_DIR}" "${arguments[@]}"
}

function save_product_infrastructure() {
    local arguments=("$@")

    save_repo "${PRODUCT_INFRASTRUCTURE_DIR}" "${arguments[@]}"
}

function save_product_state() {
    local arguments=("$@")

    save_repo "${PRODUCT_STATE_DIR}" "${arguments[@]}"
}

function main() {

    options "$@" || return $?

    . "${GENERATION_BASE_DIR}/execution/setContext.sh"

    # save account details
    if [[ "${ACCOUNT_REPOS}" == "true" && -n "${ACCOUNT}" ]]; then

        info "Committing changes to account repositories"
        save_repo "${ACCOUNT_DIR}" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
        save_repo "${ACCOUNT_STATE_DIR}" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?

    fi

    # save product details
    if [[ "${PRODUCT_REPOS}" == "true" && -n "${PRODUCT}" ]]; then

        info "Committing changes to product repositories"

        save_product_config "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
        save_product_infrastructure "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?

        if [[ -n "${PRODUCT_STATE_DIR}" ]]; then
            save_product_state "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
        fi
    fi

    RESULT=$?
    return "${RESULT}"
}

main "$@"
