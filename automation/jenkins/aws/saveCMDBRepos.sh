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
  if [[ "${ACCOUNT_REPOS}" == "true" ]]; then

    info "Committing changes to account repositories"

    if [[ -n "${ACCOUNT_CONFIG_DIR}" ]]; then
      save_repo "${ACCOUNT_CONFIG_DIR}" "account config" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
    else
      warn "Could not find ACCOUNT_CONFIG_DIR"
    fi

    if [[ -n "${ACCOUNT_INFRASTRUCTURE_DIR}" ]]; then
      save_repo "${ACCOUNT_INFRASTRUCTURE_DIR}" "account infrastructure" "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}"  || return $?
    else
      warn "Could not find ACCOUNT_INFRASTRUCTURE_DIR"
    fi
  fi

  # save product details
  if [[ "${PRODUCT_REPOS}" == "true" ]]; then

    info "Committing changes to product repositories"

    if [[ -n "${PRODUCT_CONFIG_DIR}" ]]; then
      save_product_config "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
    else
      warn "Could not find PRODUCT_CONFIG_DIR"
    fi

    if [[ -n "${PRODUCT_INFRASTRUCTURE_DIR}" ]]; then
      save_product_infrastructure "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
    else
       warn "Could not find PRODUCT_INFRASTRUCTURE_DIR"
    fi

    if [[ -n "${PRODUCT_STATE_DIR}" ]]; then
      save_product_state "${COMMIT_MESSAGE}" "${REFERENCE}" "${TAG}" || return $?
    else
      warn "Could not find PRODUCT_STATE_DIR"
    fi
  fi

  RESULT=$?
  return "${RESULT}"
}

main "$@"
