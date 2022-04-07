#!/usr/bin/env bash

# Automation framework common definitions
#
# This script is designed to be sourced into other scripts

# TODO(mfl): Remove symlinks in /automation once all explicit usage
#            of these in jenkins jobs has been modified to use
#            /execution instead.

. "${GENERATION_BASE_DIR}/execution/utility.sh"
. "${GENERATION_BASE_DIR}/execution/contextTree.sh"

# Set hamlet local store
export HAMLET_HOME_DIR="${HAMLET_HOME_DIR:-"${HOME}/.hamlet"}"
export HAMLET_EVENT_DIR="${HAMLET_HOME_DIR}/events"
export HAMLET_EVENT_LOG="${HAMLET_EVENT_DIR}/event_log.json"

# -- Repositories --

function save_repo() {
  local directory="$1"; shift
  local name="$1"; shift
  local message="$1"; shift
  local reference="$1"; shift
  local tag="$1"; shift

  local optional_arguments=()
  [[ -n "${reference}" ]] && optional_arguments+=("-b" "${reference}")
  [[ -n "${tag}" ]] && optional_arguments+=("-t" "${tag}")

  ${AUTOMATION_DIR}/manageRepo.sh -p \
    -d "${directory}" \
    -l "${name}" \
    -m "${message}" \
    "${optional_arguments[@]}"
}

function save_product_config() {
  local arguments=("$@")

  save_repo "${PRODUCT_DIR}" "config" "${arguments[@]}"
}

function save_product_infrastructure() {
  local arguments=("$@")

  save_repo "${PRODUCT_INFRASTRUCTURE_DIR}" "infrastructure" "${arguments[@]}"
}

function save_product_state() {
  local arguments=("$@")

  save_repo "${PRODUCT_STATE_DIR}" "state" "${arguments[@]}"
}

function save_product_code() {
  local arguments=("$@")

  save_repo "${AUTOMATION_BUILD_DIR}" "code" "${arguments[@]}"
}

# -- Logging --
function getLogLevel() {
  checkLogLevel "${AUTOMATION_LOG_LEVEL}"
}
