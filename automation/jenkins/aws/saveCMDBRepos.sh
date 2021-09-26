#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

. "${AUTOMATION_BASE_DIR}/common.sh"

ACCOUNT_REPOS_DEFAULT="false"
PRODUCT_REPOS_DEFAULT="false"

function options() {

  # Parse options
  while getopts ":ahm:pr:t:" option; do
      case "${option}" in
          a) ACCOUNT_REPOS="true" ;;
          h) usage; return 1 ;;
          m) COMMIT_MESSAGE="${OPTARG}" ;;
          p) PRODUCT_REPOS="true";;
          r) REFERENCE="${OPTARG}" ;;
          t) TAG-"${OPTARG}" ;;
          \?) fatalOption; return 1 ;;
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

function main() {

  options "$@" || return $?

  # save account details
  if [[ "${ACCOUNT_REPOS}" == "true" && -n "${ACCOUNT}" ]]; then

    info "Committing changes to account repositories"
    save_repo "${ACCOUNT_DIR}" "account config" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
    save_repo "${ACCOUNT_INFRASTRUCTURE_DIR}" "account infrastructure" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}"  || return $?

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
