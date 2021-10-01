#!/usr/bin/env bash

# Generation framework common definitions
#
# This script is designed to be sourced into other scripts

. ${GENERATION_BASE_DIR}/execution/utility.sh
. ${GENERATION_BASE_DIR}/execution/contextTree.sh

# Only do remainder once if this script is invoked more than once
if [[ -n "${COMMON_CONTEXT_DEFINED}" ]]; then return 0; fi
export COMMON_CONTEXT_DEFINED="true"

# For cleanupContext.sh, ensure we only cleanup from where
# this script is first invoked
COMMON_CONTEXT_DEFINED_LOCAL="true"

# Load any plugin provider utility.sh
IFS=';' read -ra PLUGINDIRS <<< ${GENERATION_PLUGIN_DIRS}
for dir in "${PLUGINDIRS[@]}"; do
  plugin_provider=${dir##*/}
    if [[ -e "${dir}/${plugin_provider}/utility.sh" ]]; then
      . "${dir}/${plugin_provider}/utility.sh"
    fi
done

# Set global default cache
export HAMLET_HOME_DIR="${HAMLET_HOME_DIR:-"${HOME}/.hamlet"}"
export GENERATION_CACHE_DIR="${HAMLET_HOME_DIR}/cache"
export PLUGIN_CACHE_DIR="${HAMLET_HOME_DIR}/plugins"
export COMMIT_CACHE_DIR="${HAMLET_HOME_DIR}/commits"

# Set the log level if not set
export GENERATION_LOG_LEVEL="${GENERATION_LOG_LEVEL:-${LOG_LEVEL_INFORMATION}}"
export GENERATION_LOG_FORMAT="${GENERATION_LOG_FORMAT:-${LOG_FORMAT_COMPACT}}"

# Determine if using the cmdb plugin
# Provide an explicit override as well
# TODO(mfl) remove once migration to the cmdb plugin is complete and proven
if contains "${GENERATION_PLUGIN_DIRS};" "(engine-plugin-cmdb|cmdb;)"; then
  export GENERATION_USE_CMDB_PLUGIN="${GENERATION_USE_CMDB_PLUGIN:-true}"
fi

function getLogLevel() {
  checkLogLevel "${GENERATION_LOG_LEVEL}"
}

# Create a temporary directory for this run
if [[ -z "${GENERATION_TMPDIR}" ]]; then
  pushTempDir "hamletc_XXXXXX"
  export GENERATION_TMPDIR="$( getTopTempDir )"
fi
debug "GENERATION_TMPDIR=${GENERATION_TMPDIR}"

# Override default implementation
function getTempRootDir() {
  echo -n "${GENERATION_TMPDIR}"
}

# Check the root of the context tree can be located
if [[ -n "${ROOT_DIR}" ]]; then
  export GENERATION_DATA_DIR="${ROOT_DIR}"
else
  export GENERATION_DATA_DIR="$(findGen3RootDir "$(pwd)")"
fi
debug "GENERATION_DATA_DIR=${GENERATION_DATA_DIR}"

# Cache for assembled components
export CACHE_DIR="$( getCacheDir "${GENERATION_CACHE_DIR}" "${GENERATION_DATA_DIR}" )"
debug "CACHE_DIR=${CACHE_DIR}"
