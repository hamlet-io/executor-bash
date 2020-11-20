#!/usr/bin/env bash

# Generation framework common definitions
#
# This script is designed to be sourced into other scripts

. ${GENERATION_BASE_DIR}/execution/utility.sh
. ${GENERATION_BASE_DIR}/execution/contextTree.sh

# Load any plugin provider utility.sh
IFS=';' read -ra PLUGINDIRS <<< ${GENERATION_PLUGIN_DIRS}
for dir in "${PLUGINDIRS[@]}"; do
  plugin_provider=${dir##*/}
    if [[ -e "${dir}/${plugin_provider}/utility.sh" ]]; then
      . "${dir}/${plugin_provider}/utility.sh"
    fi
done

# Set global default cache
GENERATION_CACHE_DIR="${GENERATION_CACHE_DIR:-"${HOME}/.hamlet/cache"}"
PROVIDER_CACHE_DIR="${GENERATION_CACHE_DIR}/providers"

function getLogLevel() {
  checkLogLevel "${GENERATION_LOG_LEVEL}"
}

# Override default implementation
function getTempRootDir() {
  echo -n "${GENERATION_TMPDIR}"
}
