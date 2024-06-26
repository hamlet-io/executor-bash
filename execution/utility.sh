#!/usr/bin/env bash

# Utility Functions
#
# This script is designed to be sourced into other scripts

# -- Detect is namedef support available
function namedef_supported() {
  [[ "${BASH_VERSION}" =~ ([^.]+)\.([^.]+)\.(.+) ]] || return 1

  [[ (${BASH_REMATCH[1]} -gt 4) || (${BASH_REMATCH[2]} -ge 3) ]]
}

# -- Error handling  --

export LOG_LEVEL_DEBUG="debug"
export LOG_LEVEL_TRACE="trace"
export LOG_LEVEL_INFORMATION="info"
export LOG_LEVEL_WARNING="warn"
export LOG_LEVEL_ERROR="error"
export LOG_LEVEL_FATAL="fatal"

# log display modes for engine
export LOG_FORMAT_COMPACT="compact"
export LOG_FORMAT_FULL="full"

# -- Error tracing --
# -- Output an errors source, line and function name --
export PS4='+(${BASH_SOURCE[0]}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

declare -A LOG_LEVEL_ORDER
LOG_LEVEL_ORDER=(
  ["${LOG_LEVEL_TRACE}"]="0"
  ["${LOG_LEVEL_DEBUG}"]="1"
  ["${LOG_LEVEL_INFORMATION}"]="3"
  ["${LOG_LEVEL_WARNING}"]="5"
  ["${LOG_LEVEL_ERROR}"]="7"
  ["${LOG_LEVEL_FATAL}"]="9"
)

function checkLogLevel() {
  local level="$1"

  [[ (-n "${level}") && (-n "${LOG_LEVEL_ORDER[${level}]}") ]] && { echo -n "${level}"; return 0; }
  [[ -n "${GENERATION_DEBUG}" ]] && { echo -n "${LOG_LEVEL_DEBUG}"; return 0; }
  echo -n "${LOG_LEVEL_INFORMATION}"
  return 0
}

# Default implementation - can be overriden by caller
function getLogLevel() {
  checkLogLevel
}

# Default implementation - can be overriden by caller but must honour parameter order
function outputLogEntry() {
  local severity="${1^}"; shift
  local parts=("$@")

  echo -e "(${severity})" "${parts[@]}"
  return 0
}

function willLog() {
  local severity="$1"

  (( "${LOG_LEVEL_ORDER[$(getLogLevel)]}" <= "${LOG_LEVEL_ORDER[${severity}]}" ))
}

function message() {
  local severity="$1"; shift
  local parts=("$@")

  if willLog "${severity}"; then
    outputLogEntry "${severity}" "${parts[@]}"
  else
    return 0
  fi
}

function locationMessage() {
  local restore_nullglob=$(shopt -p nullglob)
  local restore_globstar=$(shopt -p globstar)
  shopt -u nullglob globstar

  echo -n "$@" "Are we in the right place?"

  ${restore_nullglob}
  ${restore_globstar}
}

function cantProceedMessage() {
  echo -n "$@" "Nothing to do."
}

function debug() {
  message "${LOG_LEVEL_DEBUG}" "$@"
}

function trace() {
  message "${LOG_LEVEL_TRACE}" "$@"
}

function information() {
  message "${LOG_LEVEL_INFORMATION}" "$@"
}

function info() {
  information "$@"
}

function warning() {
  message "${LOG_LEVEL_WARNING}" "$@"
}

function warn() {
  warning "$@"
}

function error() {
  message "${LOG_LEVEL_ERROR}" "$@" >&2
}

function fatal() {
  message "${LOG_LEVEL_FATAL}" "$@" >&2
}

function fatalOption() {
  local option="${1:-${OPTARG}}"

  fatal "Invalid option: \"-${option}\""
}

function fatalOptionArgument() {
  local option="${1:-${OPTARG}}"

  fatal "Option \"-${option}\" requires an argument"
}

function fatalCantProceed() {
  fatal "$(cantProceedMessage "$@")"
}

function fatalLocation() {
  local restore_nullglob=$(shopt -p nullglob)
  local restore_globstar=$(shopt -p globstar)
  shopt -u nullglob globstar

  fatal "$(locationMessage "$@")"

  ${restore_nullglob}
  ${restore_globstar}
}

function fatalDirectory() {
  local name="$1"; shift

  fatalLocation "We don\'t appear to be in the ${name} directory."
}

function fatalMandatory() {
  local name="$1"; shift
  fatal "Mandatory argument missing: \"${name}\". Check usage via -h option."
}

# -- Event logging
function setup_event_log() {
    local event_log_file="$1"; shift

    if [[ ! -s "${event_log_file}" ]]; then
        mkdir -p "$( dirname ${event_log_file} )"
        echo '{"events":[]}' > "${event_log_file}"
    fi
}

## Adds a new key value pair to a given event id
function update_event_state() {
    local event_id="$1"; shift
    local event_type="$1"; shift
    local event_key="$1"; shift
    local event_value="$1"; shift

    setup_event_log "${HAMLET_EVENT_LOG}"

    event_time="$( date -u +"%Y-%m-%dT%H:%M:%SZ" )"
    events="$(cat "${HAMLET_EVENT_LOG}")"

    event="$( jq -r --arg event_id "${event_id}" '.events[] | select(._id == $event_id) | select (.!=null)' "${HAMLET_EVENT_LOG}")"
    [[ -z "${event}" ]] && event="{}"

    event="$( echo "${event}" | jq --arg event_type "${event_type}" --arg event_id "${event_id}" --arg event_key "${event_key}" \
                                    --arg event_value "${event_value}" --arg event_time "${event_time}" \
                '. += { "_type": $event_type, "_id": $event_id, "_time": $event_time, ($event_key): $event_value }')"

    existing_events="$(jq --arg event_id "${event_id}" 'del(.events[] | select(._id == $event_id))' "${HAMLET_EVENT_LOG}")"
    echo "${existing_events}" > "${HAMLET_EVENT_LOG}"

    echo "${existing_events}" | jq --sort-keys --argjson event "${event}" \
        '.events += [$event]' > "${HAMLET_EVENT_LOG}"
}

# Get all events that match a given key value pair
function get_events_from_state() {
    local event_key="$1"; shift
    local event_value="$1"; shift
    local output_file="$1"; shift
    local match_type="$1"; shift

    if [[ ! -s "${HAMLET_EVENT_LOG}" ]]; then
        return 0
    fi

    events="$( cat "${HAMLET_EVENT_LOG}" )"

    [[ -z "${match_type}" ]] && match_type="equal"
    case "${match_type}" in
      "equal")
        matched_events="$(echo "${events}" | jq -r --arg event_key "${event_key}" --arg event_value "${event_value}" \
            '[ .events[] | select(.[$event_key] == $event_value)]')"
        ;;
      "starts_with")
        matched_events="$(echo "${events}" | jq -r --arg event_key "${event_key}" --arg event_value "${event_value}" \
            '[ .events[] | select(.[$event_key] | startswith($event_value))]')"
        ;;

      *)
        fatal "Invalid event match format type ${match_type}"
        return 1
        ;;
    esac

    if [[ -n "$( echo "${matched_events}" | jq -r '. | select(length!=0)')" ]]; then
        echo "{}" | jq --argjson events "${matched_events}" '.events = $events' > "${output_file}"
    fi
}

# Get all events that match a given key/value pair and remove the event from the logs
function pull_events_from_state() {
    local event_key="$1"; shift
    local event_value="$1"; shift
    local output_file="$1"; shift
    local match_type="$1"; shift

    if [[ ! -s "${HAMLET_EVENT_LOG}" ]]; then
        return 0
    fi

    matched_event_file="$( getTempFile XXXXXXX )"
    get_events_from_state "${event_key}" "${event_value}" "${matched_event_file}" "${match_type}" || return 1

    if [[ -s "${matched_event_file}" ]]; then
        cp "${matched_event_file}" "${output_file}" || return 1

        matched_ids=( $(jq -r '[.events[]._id | select (.!=null) ] | join(" ")' "${matched_event_file}") )
        events="$( cat "${HAMLET_EVENT_LOG}" )"

        for id in "${matched_ids[@]}"; do
            events="$(echo "${events}" | jq --arg id "${id}" 'del(.events[] | select(._id == $id))')"
        done
        echo "${events}" > "${HAMLET_EVENT_LOG}"
    fi
}

# Log an event using the standard context for generation
function log_write_event() {
    local event_id="$1"; shift
    local type="$1"; shift
    local directory="$1"; shift
    local messages=("$@"); shift

    # Set the directory where the write event occurred
    update_event_state "${event_id}" "${type}" "directory" "$(realpath "${directory}")"

    # Set the basic context
    [[ -n "${TENANT}" ]] && update_event_state "${event_id}" "${type}" "tenant" "${TENANT}"
    [[ -n "${ACCOUNT}" ]] && update_event_state "${event_id}" "${type}" "account" "${ACCOUNT}"
    [[ -n "${PRODUCT}" ]] && update_event_state "${event_id}" "${type}" "product" "${PRODUCT}"
    [[ -n "${ENVIRONMENT}" ]] && update_event_state "${event_id}" "${type}" "environment" "${ENVIRONMENT}"
    [[ -n "${SEGMENT}" ]] && update_event_state "${event_id}" "${type}" "segment" "${SEGMENT}"

    [[ -n "${DISTRICT_TYPE}" ]] && update_event_state "${event_id}" "${type}" "district_type" "${DISTRICT_TYPE}"

    # Log who made the call for the write
    [[ -n "$(caller)" ]] && update_event_state "${event_id}" "${type}" "calling_script" "$(basename "$(caller)")"

    for message in "${messages[@]}"; do
        update_event_state "${event_id}" "${type}" "${message%%=*}" "${message#*=}"
    done
}

# -- Deprecation Handling

function deprecated_script() {
  local callReference="$(caller)"
  warn ""
  warn "The script \"${callReference##* }\" has been deprecated and will be removed in the next major release.\nSee https://docs.hamlet.io/blog for details on the replacement"
  warn ""
}

# -- String manipulation --

function join() {
  local IFS="$1"; shift
  echo -n "$*"
}

function contains() {
  local string="$1"; shift
  local pattern="$1"; shift

  [[ "${string}" =~ ${pattern} ]]
}

function generateComplexString() {
  # String suitable for a password - Alphanumeric and special characters
  local length="$1"; shift

  echo "$(dd bs=256 count=1 if=/dev/urandom | base64 | env LC_CTYPE=C tr -dc '[:punct:][:alnum:]' | tr -d '@"/+'  | fold -w "${length}" | head -n 1)" || return $?
}

function generateSimpleString() {
  # Simple string - Alphanumeric only
  local length="$1"; shift

  echo "$(dd bs=256 count=1 if=/dev/urandom | base64 | env LC_CTYPE=C tr -dc '[:alnum:]' | fold -w "${length}" | head -n 1)" || return $?
}

# -- File manipulation --

function formatPath() {
  join "/" "$@"
}

function filePath() {
  local file="$1"; shift

  contains "${file}" "/" &&
    echo -n "${file%/*}" ||
    echo -n ""
}

function fileName() {
  local file="$1"; shift

  echo -n "${file##*/}"
}

function fileBase() {
  local file="$1"; shift

  local name="$(fileName "${file}")"
  echo -n "${name%.*}"
}

function fileExtension() {
  local file="$1"; shift

  local name="$(fileName "${file}")"
  echo -n "${name##*.}"
}

function fileContents() {
  local file="$1"; shift

  [[ -f "${file}" ]] && cat "${file}"
}

function fileContentsInEnv() {
  local env="$1"; shift
  local files=("$@"); shift

  for file in "${files[@]}"; do
    if [[ -f "${file}" ]]; then
      declare -gx ${env}="$(fileContents "${file}")"
      break
    fi
  done
}

function findAncestorDir() {
  local ancestor="$1"; shift
  local current="${1:-$(pwd)}"

  while [[ -n "${current}" ]]; do
    # Ancestor can either be a directory or a marker file
    if [[ ("$(fileName "${current}")" == "${ancestor}") ||
            ( -f "${current}/${ancestor}" ) ]]; then
      echo -n "${current}"
      return 0
    fi
    current="$(filePath "${current}")"
  done

  return 1
}

function findDir() {
  local root_dir="$1"; shift
  local patterns=("$@")

  local restore_nullglob="$(shopt -p nullglob)"
  local restore_globstar="$(shopt -p globstar)"
  shopt -s nullglob globstar

  local matches=()
  for pattern in "${patterns[@]}"; do
    matches+=("${root_dir}"/**/${pattern})
    if [[ "${#matches[@]}" -gt 0 ]]; then
      break
    fi
  done

  ${restore_nullglob}
  ${restore_globstar}

  for match in "${matches[@]}"; do
    [[ -f "${match}" ]] && echo -n "$(filePath "${match}")" && return 0
    [[ -d "${match}" ]] && echo -n "${match}" && return 0
  done

  return 1
}

function findFile() {

  local restore_nullglob="$(shopt -p nullglob)"
  local restore_globstar="$(shopt -p globstar)"
  shopt -s nullglob globstar

  # Note that any spaces in file specs must be escaped
  local matches=($@)

  ${restore_nullglob}
  ${restore_globstar}

  for match in "${matches[@]}"; do
    [[ -f "${match}" ]] && echo -n "${match}" && return 0
  done

  return 1
}

function findFiles() {

  local restore_nullglob="$(shopt -p nullglob)"
  local restore_globstar="$(shopt -p globstar)"
  shopt -s nullglob globstar

  # Note that any spaces in file specs must be escaped
  local matches=($@)

  ${restore_nullglob}
  ${restore_globstar}

  local file_match="false"

  for match in "${matches[@]}"; do
    if [[ -f "${match}" ]]; then
      echo "${match}"
      local file_match="true"
    fi
  done

  if [[ "${file_match}" == "true" ]]; then
    return 0
  fi

  return 1
}

# -- Array manipulation --

function inArray() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi
  local pattern="$1"

  contains "${array[*]}" "${pattern}"
}

function arrayFromList() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    local array=()
  fi
  local list="$1"; shift
  local separators="${1:- ,}"

  # Handle situation of multi-line inputs e.g. from Jenkins multi-line string parameter plugin
  readarray -t list_lines <<< "${list}"

  IFS="${separators}" read -ra array <<< "$(join "${separators:0:1}" "${list_lines[@]}" )"
  if ! namedef_supported; then
    eval "${array_name}=(\"\${array[@]}\")"
  fi
}

function arrayFromCommand() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    local array=()
  fi
  local command="$1"; shift

  readarray -t array < <(${command})
  if ! namedef_supported; then
    eval "${array_name}=(\"\${array[@]}\")"
  fi
}

function listFromArray() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi

  local separators="${1:- ,}"

  join "${separators}" "${array[@]}"
}

function arraySize() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi

  echo -n "${#array[@]}"
}

function arrayIsEmpty() {
  local array="$1";

  [[ $(arraySize "${array}") -eq 0 ]]
}

function reverseArray() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi
  local target="$1"; shift

  if [[ -n "${target}" ]]; then
    if namedef_supported; then
      local -n result="${target}"
    else
      local result=()
    fi
  else
    local result=()
  fi

  result=()
  for (( index=${#array[@]}-1 ; index>=0 ; index-- )) ; do
    result+=("${array[index]}")
  done

  if [[ (-n "${target}") ]]; then
    if ! namedef_supported; then
      eval "${target}=(\"\${result[@]}\")"
    fi
  else
    if namedef_supported; then
      array=("${result[@]}")
    else
      eval "${array_name}=(\"\${result[@]}\")"
    fi
  fi
}

function addToArrayInternal() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi
  local type="$1"; shift
  local prefix="$1"; shift
  local elements=("$@")

  for element in "${elements[@]}"; do
    if [[ -n "${element}" ]]; then
      [[ "${type,,}" == "stack" ]] &&
        array=("${prefix}${element}" "${array[@]}") ||
        array+=("${prefix}${element}")
    fi
  done

  ! namedef_supported && eval "${array_name}=(\"\${array[@]}\")"
  return 0
}

function removeFromArrayInternal() {
  if namedef_supported; then
    local -n array="$1"; shift
  else
    local array_name="$1"; shift
    eval "local array=(\"\${${array_name}[@]}\")"
  fi
  local type="$1"; shift
  local count="${1:-1}"; shift

  local remaining=$(( ${#array[@]} - ${count} ))
  [[ ${remaining} -lt 0 ]] && remaining=0

  [[ "${type,,}" == "stack" ]] &&
    array=("${array[@]:${count}}") ||
    array=("${array[@]:0:${remaining}}")

  ! namedef_supported && eval "${array_name}=(\"\${array[@]}\")"
  return 0
}

function addToArray() {
  local array="$1"; shift
  local elements=("$@")

  addToArrayInternal "${array}" "array" "" "${elements[@]}"
}

function addToArrayHead() {
  local array="$1"; shift
  local elements=("$@")

  addToArrayInternal "${array}" "stack" "" "${elements[@]}"
}

function removeFromArray() {
  local array="$1"; shift
  local count="$1"; shift

  removeFromArrayInternal "${array}" "array" "${count}"
}

function removeFromArrayHead() {
  local array="$1"; shift
  local count="$1"; shift

  removeFromArrayInternal "${array}" "stack" "${count}"
}

function pushStack() {
  local array="$1"; shift
  local elements=("$@")

  addToArrayHead "${array}" "${elements[@]}"
}

function popStack() {
  local array="$1"; shift
  local count="$1"; shift

  removeFromArrayHead "${array}" "${count}"
}

# -- Temporary file management --

# OS Temporary directory
function getOSTempRootDir() {
  uname | grep -iq "MINGW64" &&
    echo -n "c:/tmp" ||
    echo -n "$(filePath $(mktemp -u -t tmp.XXXXXXXXXX))"
}

# Default implementation - can be overriden by caller
function getTempRootDir() {
  getOSTempRootDir
}

function getTempDir() {
  local template="$1"; shift
  local tmp_dir="$1"; shift

  [[ -z "${template}" ]] && template="XXXXXX"
  [[ -z "${tmp_dir}" ]] && tmp_dir="$(getTempRootDir)"

  [[ -n "${tmp_dir}" ]] &&
    mktemp -d "${tmp_dir}/${template}" ||
    mktemp -d "$(getOSTempRootDir)/${template}"
}

# Initial the temporary directory stack but only if it
# isn't already in use
arrayIsEmpty "tmp_dir_stack" && export tmp_dir_stack=()

function pushTempDir() {
  local template="$1"; shift

  local tmp_dir="$( getTempDir "${template}" "${tmp_dir_stack[0]}" )"

  pushStack "tmp_dir_stack" "${tmp_dir}"
}

function popTempDir() {
  local count="${1:-1}"; shift

  # Popped value not returned but keep the code here for now
  local index=$(( $count - 1 ))
  local tmp_dir="${tmp_dir_stack[@]:${index}:1}"

  popStack "tmp_dir_stack" "${count}"
}

function getTopTempDir() {
  echo -n "${tmp_dir_stack[@]:0:1}"
}

function getTempFile() {
  local template="$1"; shift
  local tmp_dir="$1"; shift

  [[ -z "${template}" ]] && template="XXXXXX"
  [[ -z "${tmp_dir}" ]] && tmp_dir="$(getTempRootDir)"

  [[ -n "${tmp_dir}" ]] &&
    mktemp    "${tmp_dir}/${template}" ||
    mktemp -t "${template}"
}

#-- Cache management

function getCacheDir() {
  local cache_root="$1"; shift
  local cache_path="${1//"/"/"_"}"; shift

  if [[ -n "${cache_root}" ]]; then
    mkdir -p "${cache_root}"
  fi

  if [[ -n "${cache_path}" ]]; then
    cache_dir="${cache_root}/${cache_path}"
    mkdir -p "${cache_dir}"
    echo "${cache_dir}"
  else
    getTempDir "hamlet_cache_XXXXXX" "${cache_root}"
  fi
}

# -- Cli file generation --
function split_cli_file() {
  local cli_file="$1"; shift
  local outdir="$1"; shift

  for resource in $( jq -r 'keys[]' < "${cli_file}" ) ; do
    for command in $( jq -r ".$resource | keys[]" < "${cli_file}" ); do
        jq ".${resource}.${command}" > "${outdir}/cli-${resource}-${command}.json" <"${cli_file}"
    done
  done
}

# -- JSON manipulation --

function runJQ() {
  local arguments=("$@")

  # TODO(mfl): remove once path length limitations in jq are fixed

  local file_seen="false"
  local file
  local tmp_dir="."
  local modified_arguments=()
  local return_status

  for argument in "${arguments[@]}"; do
    if [[ -f "${argument}" ]]; then
      if [[ "${file_seen}" != "true" ]]; then
        pushTempDir "${FUNCNAME[0]}_XXXXXX"
        tmp_dir="$(getTopTempDir)"
        file_seen="true"
      fi
      file="$( getTempFile "XXXXXX" "${tmp_dir}" )"
      cp "${argument}" "${file}" > /dev/null
      modified_arguments+=("./$(fileName "${file}" )")
    else
      modified_arguments+=("${argument}")
    fi
  done

  # TODO(mfl): Add -L once path length limitations fixed
  (cd ${tmp_dir}; jq "${modified_arguments[@]}"); return_status=$?
  [[ "${file_seen}" == "true" ]] && popTempDir
  return ${return_status}
}

function jqMergeFilter() {
  local files=("$@")

  local command_line=""
  local index=0

  for f in "${files[@]}"; do
    [[ "${index}" > 0 ]] && command_line+=" * "
    command_line+=".[${index}]"
    index=$(( $index + 1 ))
  done

  echo -n "${command_line}"
}

function jqMerge() {
  local files=("$@")

  if [[ "${#files[@]}" -gt 0 ]]; then
    runJQ -s "$( jqMergeFilter "${files[@]}" )" "${files[@]}"
  else
    echo -n "{}"
    return 0
  fi
}

function getJSONValue() {
  local file="$1"; shift
  local patterns=("$@")

  local value=""

  for pattern in "${patterns[@]}"; do
    value="$(runJQ -r "${pattern} | select (.!=null)" < "${file}")"
    [[ -n "${value}" ]] && echo -n "${value}" && return 0
  done

  return 1
}

function addJSONAncestorObjects() {
  local file="$1"; shift
  local ancestors=("$@")

  # Reverse the order of the ancestors
  local pattern="."

  for (( index=${#ancestors[@]}-1 ; index >= 0 ; index-- )) ; do
    [[ -n "${ancestors[index]}" ]] && pattern="{\"${ancestors[index]}\" : ${pattern} }"
  done

  runJQ "${pattern}" < "${file}"
}

# -- URL manipulation

function get_url_component() {
  local url="$1"; shift
  local component="$1"; shift

  proto="$(echo "$url" | grep :// | sed -e's,^\(.*://\).*,\1,g')"
  url="$(echo ${url/$proto/})"
  userpass="$(echo $url | grep @ | cut -d@ -f1)"
  pass="$(echo $userpass | grep : | cut -d: -f2)"
  if [ -n "$pass" ]; then
    user="$(echo $userpass | grep : | cut -d: -f1)"
  else
      user=$userpass
  fi
  host="$(echo ${url/$user@/} | cut -d/ -f1)"
  port="$(echo $host | sed -e 's,^.*:,:,g' -e 's,.*:\([0-9]*\).*,\1,g' -e 's,[^0-9],,g')"
  path="$(echo $url | grep / | cut -d/ -f2-)"

  case $component in
    proto)
      echo "${proto}"
      ;;

    userpass)
      echo "${userpass}"
      ;;

    user)
      echo "${user}"
      ;;

    pass)
      echo "${pass}"
      ;;

    host)
      echo "${host}"
      ;;

    port)
      echo "${port}"
      ;;

    path)
      echo "${path}"
      ;;

    *)
      echo "${url}"
  esac
}

# -- Contract manipulation --
function getTasksFromContract() {
    local contractFile="$1"; shift
    local taskOutputFile="$1"; shift
    local paramSeperator="$1"; shift
    local requiredTaskType="$1"; shift
    local paramsList="$1"; shift

    pushTempDir "${FUNCNAME[0]}_XXXXXX"
    local tmp_dir="$(getTopTempDir)"
    local tmp_file="$( getTempFile "XXXXXX" "${tmp_dir}" )"

    if [[ ! -f "${contractFile}" ]]; then
        fatal "Could not find contract file ${contractFile}"
        return 255
    fi

    arrayFromList stage_list "$( jq -r '.Stages[].Id' < "${contractFile}" || return $?)"
    for stageIndex in "${!stage_list[@]}"; do
        arrayFromList stage_steps_list "$( jq -r --arg stageIndex "${stageIndex}" '.Stages[$stageIndex | tonumber].Steps[] | select(.Status == "available" ) | .Id' < "${contractFile}" || return $? )"
        for stepIndex in "${!stage_steps_list[@]}"; do
            getTaskFromContractStep >> "${tmp_file}"
        done
    done

    if [[ -s "${tmp_file}" ]]; then
        if [[ ! -d "$( filePath "${taskOutputFile}" )" ]]; then
            mkdir -p "$( filePath "${taskOutputFile}" )"
        fi
        cp "${tmp_file}" "${taskOutputFile}"
    fi

    popTempDir
    return
}


function getTaskFromContractStep() {
  local contractStep="$1"; shift
  local paramSeperator="$1"; shift
  local paramsList="$1"; shift
  local requiredTaskType="$1"; shift

  parameter_set="$( echo "${contractStep}" | jq -c '.Parameters' || return $? )"

  if [[ -n "${paramsList}" ]]; then
    arrayFromList params_list "${paramsList}"
    parameters_ordered=()

    for param in "${params_list[@]}"; do
      parameters_ordered+=( "$( echo "${parameter_set}" | jq -r --arg parameter "${param}" '"\(.[$parameter] | select (.!=null))"' || return $? )" )
    done

    parameters="$(listFromArray "parameters_ordered" "${paramSeperator}" )"

  else
    parameters="$( echo "${parameter_set}" | jq -r --arg seperator "${paramSeperator}" \
                    '[ . | to_entries[] | "\(.value)" ] | join($seperator )' || return $?)"
  fi

  taskType="$( echo "${contractStep}" | jq -r '.Type' || return $?)"

  if [[ -z "${requiredTaskType}" || "${taskType}" == "${requiredTaskType}" ]]; then
    echo "${taskType} ${parameters}"
  else
    echo ""
  fi
}

function getStepTypesFromContractStage() {
  local contractStage="$1"; shift
  local seperator="$1"; shift

  echo "$( echo "${contractStage}" | jq -r --arg seperator "${seperator}" '[ .Steps[].Type ] | join($seperator)' || return $?)"
}

function getStepStatusesFromContractStage() {
  local contractStage="$1"; shift
  local seperator="$1"; shift

  echo "$( echo "${contractStage}" | jq -r --arg seperator "${seperator}" '[ .Steps[].Status ] | join($seperator)' || return $?)"
}

# -- Environment Config handling
# handles environment variable configuration with qualification support
function find_env_config() {
  local result_variable_name="${1}"; shift
  local namespace="${1^^}"; shift
  local config_key="${1^^}"; shift
  local level1="${1^^}"; shift
  local level2="${1^^}"; shift

  local selected_variable_name=""

  if [[ -n "${namespace}" ]]; then
    namespace="${namespace}_"
  fi

  # Variables to check
  local base_variable_name="${namespace}${config_key}"
  local level1_variable_name="${namespace}${level1}_${config_key}"
  local level2_variable_name="${nampspace}${level1}_${level2}_${config_key}"

  # Two level definition
  if [[ (-n "${level2}") && (-n "${!level2_variable_name}") ]]; then
      selected_variable_name="${level2_variable_name}"
  else
      # One level definition
      if [[ (-n "${level1}") && (-n "${!level1_variable_name}") ]]; then
          selected_variable_name="${level1_variable_name}"
      else
          # Base config value
          if [[ -n "${!base_variable_name}" ]]; then
            selected_variable_name="${base_variable_name}"
          fi
      fi
  fi

  if [[ (-n "${selected_variable_name}") && (-n "${!selected_variable_name}") ]]; then
      # Value found
      local config_value="${!selected_variable_name}"
  else
      local config_value=""
  fi

  # make the variable available aoutside of this scope
  eval "${result_variable_name}"="${config_value}"
}


# -- Context properties file --
function save_context_property() {
  local name="$1"; shift
  local value="$1"; shift
  local file="${1}"; shift

  if [[ -z "${file}" && -n "${AUTOMATION_DATA_DIR}" ]]; then
    file="${AUTOMATION_DATA_DIR}/context.properties"
  fi

  if [[ -z "${file}" ]]; then
    file="$( getTempFile "XXXXXX")"
    debug "Saving context property to ${file} - AUTOMATION_DATA_DIR not defined"
  fi

  if [[ -n "${value}" ]]; then
    local property_value="${value}"
  else
    if namedef_supported; then
      local -n property_value="${name}"
    else
      eval "local property_value=\"\${${name}}\""
    fi
  fi

  export ${name}="${property_value}"

  case "${AUTOMATION_PROVIDER}" in
    jenkins|hamletcli)
      echo "${name}=${property_value}" >> "${file}"
      ;;

    azurepipelines)
      # remove trailing whitespace from any var about to be set
      property_value_nospace=$(echo "${property_value}" | sed -e 's/[[:space:]]*$//')
      export ${name}="${property_value_nospace}"
      set +x
      echo "##vso[task.setvariable variable=${name}]${property_value_nospace}"
      set -x
      ;;
  esac
}

function save_chain_property() {
  local name="$1"; shift
  local value="$1"; shift

  if [[ -n "${AUTOMATION_DATA_DIR}" ]]; then
    file="${AUTOMATION_DATA_DIR}/chain.properties"
  else
    context_temp_file=getTempFile "XXXXXX"
    debug "Saving context property to ${context_temp_file} - AUTOMATION_DATA_DIR not defined"
    file="${context_temp_file}"
  fi

  save_context_property "${name}" "${value}" "${file}"

}

function define_context_property() {
  local name="${1^^}"; shift
  local value="$1"; shift
  local capitalisation="$1,,"; shift

  case "${capitalisation}" in
    lower)
      value="${value,,}"
      ;;
    upper)
      value="${value^^}"
      ;;
  esac

  declare -g ${name}="${value}"
  save_context_property "${name}" "${value}"
}

function save_gen3_dirs_in_context() {
  local prefix="$1"; shift

  local directories=(ROOT_DIR \
    TENANT_DIR TENANT_INFRASTRUCTURE_DIR \
    ACCOUNT_DIR ACCOUNT_STATE_DIR ACCOUNT_SETTINGS_DIR ACCOUNT_OPERATIONS_DIR \
    PRODUCT_DIR PRODUCT_INFRASTRUCTURE_DIR PRODUCT_SETTINGS_DIR PRODUCT_SOLUTIONS_DIR PRODUCT_OPERATIONS_DIR \
    SEGMENT_SETTINGS_DIR SEGMENT_BUILDS_DIR SEGMENT_SHARED_BUILDS_DIR SEGMENT_SOLUTIONS_DIR)

  for directory in "${directories[@]}"; do
    save_context_property "${directory}" "$(getGen3Env "${directory}" "${prefix}")"
  done

  return 0
}

# -- KMS --
function decrypt_kms_string() {
  local region="$1"; shift
  local value="$1"; shift

  pushTempDir "${FUNCNAME[0]}_XXXXXX"
  local tmp_file="$(getTopTempDir)/value"
  local return_status

  echo "${value}" | base64 --decode > "${tmp_file}"
  aws --region "${region}" kms decrypt --ciphertext-blob "fileb://${tmp_file}" --output text --query Plaintext | base64 --decode; return_status=$?

  popTempDir
  return ${return_status}
}

function encrypt_kms_string() {
  local region="$1"; shift
  local value="$1"; shift
  local kms_key_id="$1"; shift

  local cli_v1="$(aws --version | grep 'aws-cli/1.')"
  if [[ -n "$cli_v1" ]] ; then
    local cli_encrypt="kms encrypt"
  else
    local cli_encrypt="kms encrypt --cli-binary-format raw-in-base64-out"
  fi

  aws --region "${region}" ${cli_encrypt} --key-id "${kms_key_id}" --plaintext "${value}" --query CiphertextBlob --output text
}

function encrypt_kms_file() {
  local region="$1"; shift
  local input_file="$1"; shift
  local output_file="$1"; shift
  local kms_key_id="$1"; shift

  pushTempDir "${FUNCNAME[0]}_XXXXXX"
  local tmp_dir="$(getTopTempDir)"
  local return_status

  local cli_v1="$(aws --version | grep 'aws-cli/1.')"
  if [[ -n "$cli_v1" ]] ; then
    local cli_encrypt="kms encrypt"
  else
    local cli_encrypt="kms encrypt --cli-binary-format raw-in-base64-out"
  fi

  cp "${input_file}" "${tmp_dir}/encrypt_file" || return_status=255

  if [[ -z "${return_status}" ]]; then
    (cd "${tmp_dir}"; aws --region "${region}" --output text ${cli_encrypt} \
      --key-id "${kms_key_id}" --query CiphertextBlob \
      --plaintext "fileb://encrypt_file" > "${output_file}"; return_status=$?)
  fi

  popTempDir

  return ${return_status}
}

# -- IAM --
function create_iam_accesskey() {
  local region="$1"; shift
  local username="$1"; shift

  accesskey="$(aws --region "${region}" iam create-access-key --user-name "${username}" )" || return $?

  if [[ -n "${accesskey}" ]]; then
    access_key_id="$( echo "${accesskey}" | jq -r '.AccessKey.AccessKeyId')"
    secret_access_key="$( echo "${accesskey}" | jq -r '.AccessKey.SecretAccessKey')"

    echo "${access_key_id} ${secret_access_key}"
    return 0

  else
    fatal "Could not generate accesskey for ${username}"
    return 255
  fi
}

function manage_iam_userpassword() {
  local region="$1"; shift
  local action="$1"; shift
  local username="$1"; shift
  local password="$1"; shift

  login_profile="$(aws --region "${region}" iam get-login-profile --user-name "${username}" --query 'LoginProfile.UserName' --output text 2>/dev/null )"

  case "${action}" in
    delete)
      if [[ "${login_profile}" == "${username}" ]]; then
        aws --region "${region}" iam delete-login-profile --user-name "${username}" || return $?
      fi
      ;;

    *)
      if [[ "${login_profile}" != "${username}" ]]; then
        aws --region "${region}" iam create-login-profile --user-name "${username}" --password "${password}" --no-password-reset-required || return $?
      else
        aws --region "${region}" iam update-login-profile --user-name "${username}" --password "${password}" --no-password-reset-required || return $?
      fi
      ;;
  esac
  return 0
}

# -- CloudWatch Events --
function delete_cloudwatch_event() {
    local region="$1"; shift
    local ruleName="$1"; shift
    local includeRule="$1"; shift

    local return_status=0

    if [[ -n "$(aws --region "${region}" events list-rules --query "Rules[?Name == '$ruleName'].Name" --output text)" ]]; then

      rule_targets="$( aws --region "${region}" events list-targets-by-rule --rule "${ruleName}" --query "Targets[*].Id | join(' ',@)" --output text)"
      if [[ -n "${rule_targets}" ]]; then
        aws --region "${region}" events remove-targets --rule "${ruleName}" --ids ${rule_targets} || return $?
      fi

      if [[ "${includeRule}" == "true" ]]; then
        aws --region "${region}" events delete-rule --name "${ruleName}" || return $?
      fi

    fi

    return ${return_status}
}

function create_cloudwatch_event () {
  local region="$1"; shift
  local ruleName="$1"; shift
  local eventRoleId="$1"; shift
  local ruleConfigFile="$1"; shift
  local targetConfigFile="$1"; shift

  local return_status=0

  if [[ "${eventRoleId}" != arn:* ]]; then
    eventRoleArn="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${eventRoleId}" "arn" || return $?)"
  else
    eventRoleArn="${eventRoleId}"
  fi

  arnLookupTargetConfigFile="$(filePath ${targetConfigFile})/ArnLookup-$(fileBase ${targetConfigFile})"
  jq --arg eventRoleArn "${eventRoleArn}" '.Targets[0].RoleArn= $eventRoleArn' < "${targetConfigFile}" > "${arnLookupTargetConfigFile}"

  delete_cloudwatch_event "${region}" "${ruleName}" "false" || return $?
  aws --region "${region}" events put-rule --name "${ruleName}" --cli-input-json "file://${ruleConfigFile}" || return $?
  aws --region "${region}" events put-targets --rule "${ruleName}" --cli-input-json "file://${arnLookupTargetConfigFile}" || return $?

  return ${return_status}
}

function set_cloudwatch_log_group_retention () {
  local region="$1"; shift
  local logGroupName="$1"; shift
  local retentionInDays="$1"; shift

  info "Setting retention period ${retentionInDays} on ${logGroupName}"
  if [[ -n "$(aws --region "${region}" logs describe-log-groups --output text --query "logGroups[?logGroupName == '${logGroupName}'].logGroupName" || return $?)"  ]]; then
    aws --region "${region}" logs put-retention-policy --log-group-name "${logGroupName}" --retention-in-days "${retentionInDays}"
  else
    info "log group ${logGroupName} not found - will try on next update"
  fi
}

# -- CloudFormation --
function get_cloudformation_stack_output() {
  local region="$1"; shift
  local stackName="$1"; shift
  local resourceId="$1"; shift
  local attributeType="$1"; shift

  if [[ -z "${attributeType}" || "${attributeType}" == "ref" ]]; then
    stackOutputKey="${resourceId}"
  else
    stackOutputKey="${resourceId}X${attributeType}"
  fi

  stack_id="$(aws --region "${region}" cloudformation list-stacks --stack-status-filter "CREATE_COMPLETE" "UPDATE_COMPLETE" --query "StackSummaries[?StackName == '$stackName'].StackId" --output text || return $?)"
  if [[ -n "${stack_id}" ]]; then
    aws --region "${region}" cloudformation describe-stacks --stack-name "${stackName}" --query "Stacks[*].Outputs[?OutputKey == '${stackOutputKey}'].OutputValue" --output text || return $?
  fi
}

# -- Content Node --
function copy_contentnode_file() {
  local files="$1"; shift
  local engine="$1"; shift
  local path="$1"; shift
  local prefix="$1"; shift
  local nodepath="$1"; shift
  local branch="$1"; shift
  local copymode="$1"; shift

  local contentnodedir="${tmp_dir}/contentnode"
  local contenthubdir="${tmp_dir}/contenthub"
  local hubpath="${contenthubdir}/${prefix}${nodepath}"

  # Copy files into repo
  if [[ -f "${files}" ]]; then

    case ${engine} in
      github)

        # Copy files locally so we can synch with git
        for file in "${files[@]}" ; do
          if [[ -f "${file}" ]]; then
            case "$(fileExtension "${file}")" in
              zip)
                unzip "${file}" -d "${contentnodedir}" || return $?
                ;;
              *)
                if [[ ! -d "${contentnodedir}" ]]; then
                  mkdir -p "${contentnodedir}"
                fi
                cp "${file}" "${contentnodedir}" || return $?
                ;;
            esac
          fi
        done

        # Clone the Repo
        local git_url="$( format_git_url "${engine}" "github.com" "${path}" )"
        clone_git_repo "${git_url}" "${branch}" "${contenthubdir}" || return $?

        case ${STACK_OPERATION} in

          delete)
            if [[ -n "${hubpath}" ]]; then
              rm -rf "${hubpath}" || return $?
            else
              fatal "Hub path not defined"
              return 1
            fi
          ;;

          create|update)
            if [[ -n "${hubpath}" ]]; then
              if [[ -d "${hubpath}" && "${copymode}" == "replace" ]]; then
                rm -rf "${hubpath}" || return $?
              fi
              mkdir -p "${hubpath}"
              cp -R ${contentnodedir}/* ${hubpath} || return $?
            else
              fatal "Hub path not defined"
              return 1
            fi
          ;;
        esac

        # Commit Repo
        push_git_repo "${git_url}" "${branch}" "origin" \
          "ContentNodeDeployment-${PRODUCT}-${SEGMENT}-${DEPLOYMENT_UNIT}" \
          "${GIT_USER}" "${GIT_EMAIL}" \
          "${contenthubdir}" || return $?

      ;;
    esac
  else
    info "No files found to copy"
  fi

  return 0
}

# -- Cognito --

function update_cognito_userpool() {
  local region="$1"; shift
  local userpoolid="$1"; shift
  local configfile="$1"; shift

  aws --region "${region}" cognito-idp update-user-pool --user-pool-id "${userpoolid}" --cli-input-json "file://${configfile}"
}

function update_cognito_userpool_client() {
  local region="$1"; shift
  local userpoolid="$1"; shift
  local userpoolclientid="$1"; shift
  local configfile="$1"; shift

  aws --region "${region}" cognito-idp update-user-pool-client --user-pool-id "${userpoolid}" --client-id "${userpoolclientid}" --cli-input-json "file://${configfile}"
}

function update_cognito_userpool_authprovider() {
  local region="$1"; shift
  local userpoolid="$1"; shift
  local authprovidername="$1"; shift
  local authprovidertype="$1"; shift
  local encryption_scheme="$1"; shift
  local oidc_client_secret="$1"; shift
  local configfile="$1"; shift

  if [[ "${authprovidertype}" == "OIDC" ]]; then
    if [[ "${oidc_client_secret}" == "${encryption_scheme}"* ]]; then
        decrypted_oidc_client_secret="$( decrypt_kms_string "${region}" "${oidc_client_secret#${encryption_scheme}}" || return $? )"
    else
        decrypted_oidc_client_secret="${oidc_client_secret}"
    fi

    jq --arg client_secret "${decrypted_oidc_client_secret}" -r '.ProviderDetails.client_secret=$client_secret' < "${configfile}" > "${configfile}_clientsecret" || return $?

    if [[ -f "${configfile}_clientsecret" ]]; then
      mv "${configfile}_clientsecret" "${configfile}"
    fi
  fi

  current_provider_type="$(aws --region "${region}" cognito-idp describe-identity-provider --user-pool-id "${userpoolid}" --provider-name "${authprovidername}" --query "IdentityProvider.ProviderType" --output text 2>/dev/null || true )"

  if [[ -n "${current_provider_type}" && ( "${current_provider_type}" != "${authprovidertype}" ) ]]; then
    # delete the provider if the type is different
    aws --region "${region}" cognito-idp delete-identity-provider --user-pool-id "${userpoolid}" --provider-name "${authprovidername}" || return $?
  fi

  if [[ -z "${current_provider_type}" || ( "${current_provider_type}" != "${authprovidertype}" ) ]]; then
    # create the provider
    aws --region "${region}" cognito-idp create-identity-provider --user-pool-id "${userpoolid}" --provider-name "${authprovidername}" --provider-type "${authprovidertype}" --cli-input-json "file://${configfile}" || return $?
  fi

  if [[ "${current_provider_type}" == "${authprovidertype}" ]]; then
    # update the provider
    aws --region "${region}" cognito-idp update-identity-provider --user-pool-id "${userpoolid}" --provider-name "${authprovidername}" --cli-input-json "file://${configfile}" || return $?
  fi

}

function cleanup_cognito_userpool_authproviders() {
  local region="$1"; shift
  local userpoolid="$1"; shift
  local expectedproviders="$1"; shift
  local removeall="$1"; shift

  current_providers="$(aws --region "${region}" cognito-idp list-identity-providers --user-pool-id "${userpoolid}" --query "Providers[*].ProviderName" --output text)"

  if [[ "${current_providers}" != "None" && -n "${current_providers}" ]]; then
    arrayFromList expected_provider_list "${expectedproviders}"
    arrayFromList current_provider_list "${current_providers}"

    for provider in "${current_provider_list[@]}"; do
      if [[ $( ! inArray "expected_provider_list" "${provider}" ) || "${removeall}" == "true" ]]; then
        info "Removing auth provider ${provider} from ${userpoolid}"
        aws --region "${region}" cognito-idp delete-identity-provider --user-pool-id "${userpoolid}" --provider-name "${provider}" || return $?
      fi
    done

  else
    info "No providers found moving on.."
  fi
}

function manage_cognito_userpool_domain() {
  local region="$1"; shift
  local userpoolid="$1"; shift
  local configfile="$1"; shift
  local action="$1"; shift
  local domaintype="$1"; shift

  local return_status=0

  domain="$( jq -r '.Domain' < $configfile )"
  domain_userpool="$( aws --region ${region} cognito-idp describe-user-pool-domain --domain ${domain} --query "DomainDescription.UserPoolId" --output text )"

  if [[ "${domain_userpool}" == "None" ]]; then

    case "${action}" in
        create)
            info "Adding domain to userpool"

            case "${domaintype}" in
              internal)
                userpool_domain="$(aws --region ${region} cognito-idp describe-user-pool --user-pool-id "${userpoolid}" --query "UserPool.Domain" --output text)"
                ;;
              custom)
                userpool_domain="$(aws --region ${region} cognito-idp describe-user-pool --user-pool-id "${userpoolid}" --query "UserPool.CustomDomain" --output text)"
                ;;
            esac

            if [[ "${userpool_domain}" != "${domain}" && "${userpool_domain}" != "None" && -n "${userpool_domain}" ]]; then
              aws --region "${region}" cognito-idp delete-user-pool-domain --user-pool-id "${userpoolid}" --domain "${userpool_domain}" || return $?
            fi

            if [[ ( "${userpool_domain}" == "None" || "${userpool_domain}" != "${domain}" ) && -n "${userpool_domain}" ]]; then
              aws --region "${region}" cognito-idp create-user-pool-domain --user-pool-id "${userpoolid}" --cli-input-json "file://${configfile}" || return $?
              return_status=$?
            fi
            ;;
        delete)
            info "Domain not assigned to a userpool. Nothing to do"
            ;;
    esac

  elif [[ "${domain_userpool}" != "${userpoolid}" ]]; then
    error "User Pool Domain ${domain} is used by userpool ${domain_userpool}"
    return_status=255

  else
    case "${action}" in
        create)
            info "User Pool domain already configured"
            ;;
        delete)
            info "Deleting domain from user pool"
            aws --region "${region}" cognito-idp delete-user-pool-domain --user-pool-id "${userpoolid}" --domain "${domain}" || return $?
            ;;
    esac
  fi

  return ${return_status}
}

function get_cognito_userpool_custom_distribution() {
  local region="$1"; shift
  local domain="${1}"; shift

  aws --region "${region}" cognito-idp describe-user-pool-domain --domain ${domain} --query "DomainDescription.CloudFrontDistribution" --output text || return $?
}

#-- DynamoDB --
function upsert_dynamodb_item() {
  local region="$1"; shift
  local tableName="$1"; shift
  local configfile="$1"; shift
  local cfnStackName="$1"; shift

  aws --region "${region}" dynamodb update-item --table-name "${tableName}" --return-values "UPDATED_NEW" --cli-input-json "file://${configfile}" || return $?

  return 0
}

function scan_dynamodb_table() {
  local region="$1"; shift
  local tableName="$1"; shift
  local configfile="$1"; shift
  local cfnStackName="$1"; shift

  items="$(aws --region "${region}" dynamodb scan --table-name "${tableName}" --cli-input-json "file://${configfile}" --query "Items[*]" --output json || return $? )"

  # return each item as a new line
  items="$( echo "${items}" | jq -c '.[]' )"

  echo "${items}"

  return 0
}

function delete_dynamodb_items() {
  local region="$1"; shift
  local tableName="$1"; shift
  local itemKeys="$1"; shift
  local cfnStackName="$1"; shift

  arrayFromList items_to_delete "${itemKeys}"

  for item in "${items_to_delete[@]}"; do
    aws --region "${region}" dynamodb delete-item --table-name "${tableName}" --key "${item}" || return $?
  done
}

#-- Ec2 --
function get_ec2_autoscalegroup_arn() {
  local region="$1"; shift
  local groupName="$1"; shift

  aws --region "${region}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${groupName}" --query "AutoScalingGroups[*].AutoScalingGroupARN" --output text || return $?
}

function update_ec2_autoscalegroup() {
  local region="$1"; shift
  local groupName="$1"; shift
  local configfile="$1"; shift

  aws --region "${region}" autoscaling update-auto-scaling-group --auto-scaling-group-name "${groupName}" --cli-input-json "file://${configfile}" || return $?
}

function remove_ec2_scaleinprotection() {
  local region="$1"; shift
  local groupName="$1"; shift

  protected_instances="$( aws --region "${region}" autoscaling describe-auto-scaling-groups --auto-scaling-group-names "${groupName}" --query 'AutoScalingGroups[*].Instances[?ProtectedFromScaleIn].InstanceId' --output text || return $? )"
  if [[ -n "${protected_instances}" ]]; then
    info "Disabling scale in protection to allow for scaling events"
    aws --region "${region}" autoscaling set-instance-protection --auto-scaling-group-name "${groupName}" --no-protected-from-scale-in --instance-ids ${protected_instances} || return $?
  fi
}

function manage_ec2_volume_encryption() {
  local region="$1"; shift
  local encryptionEnabled="$1"; shift
  local kmsKeyArn="$1"; shift

  current_state="$(aws --region "${region}" ec2 get-ebs-encryption-by-default --output text --query 'EbsEncryptionByDefault' | tr '[:upper:]' '[:lower:]' )"
  encryptionEnabled="$( echo ${encryptionEnabled} | tr '[:upper:]' '[:lower:]')"

  if [[ "${current_state}" != "${encryptionEnabled}" ]]; then
    aws --region "${region}" ec2 modify-ebs-default-kms-key-id --kms-key-id "${kmsKeyArn}"

    if [[ "${encryptionEnabled}" == "true" ]]; then
        info "Enabling KMS Volume Encryption"
        aws --region "${region}" ec2 enable-ebs-encryption-by-default
    fi

    if [[ "${encryptionEnabled}" == "false" ]]; then
      info "Disabling KMS Volume Encryption"
      aws --region "${region}" ec2 disable-ebs-encryption-by-default
    fi
  else
    info "Volume Encryption State - expected: ${encryptionEnabled} - current: ${current_state}"
  fi
}

#-- ECS --
function manage_ecs_account_settings() {
  local region="$1"; shift
  local setting="$1"; shift
  local state="$1"; shift


  info "Configuring ecs account setting - ${region} - ${setting} - ${state}"
  # Remove settings applied at the principal level to ensure defaults are respected
  principal_setting="$(aws --region "${region}" ecs list-account-settings --name "${setting}" --query 'settings[].name' --no-effective-settings  | jq -r '.[]')"
  if [[ -n "${principal_setting}" ]]; then
    info "Removing ecs account settings for automation role principal"
    aws --region "${region}" ecs delete-account-setting --name "${principal_setting}" || return $?
  fi

  info "Setting account/region wide default value"
  aws --region "${region}" ecs put-account-setting-default --name "${setting}" --value "${state}" || return $?

  info "Effective value"
  aws --region "${region}" ecs list-account-settings --effective-settings --name "${setting}" || return $?

}

function create_ecs_scheduled_task() {
  local region="$1"; shift
  local ruleName="$1"; shift
  local ruleConfigFile="$1"; shift
  local targetConfigFile="$1"; shift
  local cfnStackName="$1"; shift
  local taskId="$1"; shift
  local eventRoleId="$1"; shift
  local securityGroupId="$1"; shift

  ecsTaskArn="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${taskId}" "arn" || return $?)"
  securityGroup="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${securityGroupId}" "ref" || return $?)"

  arnLookupConfigFile="$(filePath ${targetConfigFile})/ArnLookup-$(fileBase ${targetConfigFile})"
  jq --arg ecsTaskArn "${ecsTaskArn}" --arg securityGroup "$securityGroup" '.Targets[0].EcsParameters.TaskDefinitionArn = $ecsTaskArn | .Targets[0].EcsParameters.NetworkConfiguration.awsvpcConfiguration.SecurityGroups = [ $securityGroup ]' < "${targetConfigFile}" > "${arnLookupConfigFile}"

  create_cloudwatch_event "${region}" "${ruleName}" "${eventRoleId}" "${ruleConfigFile}" "${arnLookupConfigFile}"  || return $?

  return 0
}

function create_ecs_capacity_provider() {
  local region="$1"; shift
  local name="$1"; shift
  local autoScalingGroupArn="$1"; shift

  capacity_provider_arn="$(aws --region ${region} ecs describe-capacity-providers --capacity-providers "${name}"  --query "capacityProviders[*].capacityProviderArn" --output text || return $?)"

  if [[ -z "${capacity_provider_arn}"  ]]; then
    info "Creating capacity provider ${name}..."
    aws --region "${region}" ecs create-capacity-provider --name "${name}" \
    --auto-scaling-group-provider "autoScalingGroupArn=\"${autoScalingGroupArn}\",managedScaling={status=\"ENABLED\",targetCapacity=100,minimumScalingStepSize=1,maximumScalingStepSize=1},managedTerminationProtection=\"ENABLED\"" || return $?
  else
    info "Capacity provider ${name} already exists"
    aws --region ${region} ecs describe-capacity-providers --capacity-providers "${name}" ||return $?
  fi

}

function update_ecs_cluster_capacity_providers() {
  local region="$1"; shift
  local clusterArn="$1"; shift
  local capacityProviderName="$1"; shift

  aws --region "${region}" ecs put-cluster-capacity-providers --cluster "${clusterArn}" \
          --capacity-providers "${capacityProviderName}" \
          --default-capacity-provider-strategy "capacityProvider=\"${capacityProviderName}\",weight=1,base=0" || return $?
}

# -- ElasticSearch --
function update_es_domain() {
  local region="$1"; shift
  local esid="$1"; shift
  local configfile="$1"; shift

  aws --region "${region}" es update-elasticsearch-domain-config --domain-name "${esid}" --cli-input-json "file://${configfile}" || return $?
}

# -- Elastic Load Balancing --
function create_elbv2_rule() {
  local region="$1"; shift
  local listenerid="$1"; shift
  local configfile="$1"; shift

  rule_arn="$(aws --region "${region}" elbv2 create-rule --listener-arn "${listenerid}" --cli-input-json "file://${configfile}" --query 'Rules[0].RuleArn' --output text || return $? )"

  if [[ "${rule_arn}" == "None" ]]; then
    fatal "Rule was not created"
    return 255
  else
    echo "${rule_arn}"
    return 0
  fi
}

function cleanup_elbv2_rules() {
  local region="$1"; shift
  local listenerarn="$1"; shift

  pushTempDir "elbv2_listener_cleanup_XXXXXX"
  local tmp_file="$(getTopTempDir)/cleanup.sh"

  all_listener_rules="$(aws --region "${region}" elbv2 describe-rules --listener-arn "${listenerarn}" --query 'Rules[?!IsDefault].RuleArn' --output json )"

  info "Removing all listener rules from ${listenerarn}"
  if [[ -n "${all_listener_rules}" ]]; then
    echo "${all_listener_rules}" | jq --arg region "${region}" -r '.[] | "aws --region \($region) elbv2 delete-rule --rule-arn \(.) || { status=$?; popTempDir; return $status; }"' > "${tmp_file}"
    if [[ -f "${tmp_file}" ]]; then
      chmod u+x "${tmp_file}"
      "${tmp_file}"
    fi
  fi

  popTempDir
  return 0
}


# -- S3 --

function isBucketAccessible() {
  local bucket="$1"; shift
  local prefix="$1"; shift

  result_file="$(getTopTempDir)/is_bucket_accessible_XXXXXX.txt"
  aws s3 ls "s3://${bucket}/${prefix}${prefix:+/}" > "${result_file}" 2>&1
}

function copyFilesFromBucket() {
  local region="$1"; shift
  local bucket="$1"; shift
  local prefix="$1"; shift
  local dir="$1"; shift
  local optional_arguments=("$@")

  aws --region ${region} s3 cp --recursive "${optional_arguments[@]}" "s3://${bucket}/${prefix}${prefix:+/}" "${dir}/"
}

function syncFilesToBucket() {
  local region="$1"; shift
  local bucket="$1"; shift
  local prefix="$1"; shift
  if namedef_supported; then
    local -n syncFiles="$1"; shift
  else
    eval "local syncFiles=(\"\${${1}[@]}\")"; shift
  fi
  local optional_arguments=("$@")

  # Does the bucket/prefix exist?
  if isBucketAccessible "${bucket}"; then
    pushTempDir "${FUNCNAME[0]}_XXXXXX"
    local tmp_dir="$(getTopTempDir)"
    local return_status

    # Copy files locally so we can synch with S3, potentially including deletes
    for file in "${syncFiles[@]}" ; do
      if [[ -f "${file}" ]]; then
        case "$(fileExtension "${file}")" in
          zip)
            # Always use local time to force redeploy of files
            # in case we are reverting to an earlier version
            unzip -DD "${file}" -d "${tmp_dir}"
            ;;
          *)
            cp "${file}" "${tmp_dir}"
            ;;
        esac
      fi
    done

    local target_url="s3://${bucket}/${prefix}${prefix:+/}"

    # Now synch with s3 - cli guesses content-type based on extension
    aws --region ${region} s3 sync "${optional_arguments[@]}" "${tmp_dir}/" "${target_url}"; return_status=$?

    if [[ "${return_status}" -eq 0 ]]; then
      # Handle encoded files specially to set the encoding metadata on the resulting S3 objects
      readarray -t encoded_files < <(find "${tmp_dir}" -type f -name "encoded--*--*" )
      for f in "${encoded_files[@]}"; do
        local filename=$(fileName "${f}")

        # Ensure the encoding has been provided
        [[ "$filename" =~ ^encoded--(.+)--(.+)$ ]] || continue
        local encoding="${BASH_REMATCH[1]}"

        # Encoding specific processing
        case "${encoding,,}" in
          gzip)
            [[ "$filename" =~ ^(.+)\.([^\.]+)\.([^\.]+)$ ]] || continue
            local encoding_extension="${BASH_REMATCH[2],,}"
            case "${encoding_extension}" in
              gzip|gz)
                # Encoding applied
                ;;
              *)
                # Extension doesn't match encoding
                continue
                ;;
            esac
            ;;
        esac

        # Work out the relative path
        local relative_path="${f#${tmp_dir}/}"

        # Copy the file and set the encoding metadata
        aws --region ${region} s3 cp --content-encoding "${encoding}" "${f}" "${target_url}${relative_path}"; return_status=$?
      done
    fi

    popTempDir
    return ${return_status}
  fi
  return 0
}

function deleteTreeFromBucket() {
  local region="$1"; shift
  local bucket="$1"; shift
  local prefix="$1"; shift
  local optional_arguments=("$@")

  # Does the bucket/prefix exist?
  isBucketAccessible "${bucket}" "${prefix}" || return 0

  # Delete everything below the prefix
  aws --region "${region}" s3 rm "${optional_arguments[@]}" --recursive "s3://${bucket}/${prefix}${prefix:+/}"
}

function deleteBucket() {
  local region="$1"; shift
  local bucket="$1"; shift
  local optional_arguments=("$@")

  # Does the bucket exist?
  isBucketAccessible "${bucket}" || return 0

  # Delete the bucket
  aws --region "${region}" s3 rb "${optional_arguments[@]}" "s3://${bucket}" --force
}

# -- SNS --
function deploy_sns_platformapp() {
  local region="$1"; shift
  local name="$1"; shift
  local existing_arn="$1"; shift
  local encryption_scheme="$1"; shift
  local engine="$1"; shift
  local configfile="$1"; shift

  platform_principal="$(jq -rc '.Attributes.PlatformPrincipal | select (.!=null)' < "${configfile}" )"
  platform_credential="$(jq -rc '.Attributes.PlatformCredential | select (.!=null)' < "${configfile}" )"

  #Decrypt the principal and certificate if they are encrypted
  if [[ "${platform_principal}" == "${encryption_scheme}"* ]]; then
      decrypted_platform_principal="$( decrypt_kms_string "${region}" "${platform_principal#${encryption_scheme}}" || return $? )"
  else
      decrypted_platform_principal="${platform_principal}"
  fi

  if [[ "${platform_credential}" == "${encryption_scheme}"* ]]; then
    decrypted_platform_credential="$( decrypt_kms_string "${region}" "${platform_credential#${encryption_scheme}}" || return $? )"
  else
    decrypted_platform_credential="${platform_credential}"
  fi

  jq -rc '. | del(.Attributes.PlatformPrincipal) | del(.Attributes.PlatformCredential)' < "${configfile}" > "${configfile}_decrypted"

  if [[ -n "${existing_arn}" ]]; then
    platform_app_arn="${existing_arn}"
    update_platform_app="$(aws --region "${region}" sns set-platform-application-attributes --platform-application-arn "${platform_app_arn}" --attributes PlatformPrincipal="${decrypted_platform_principal}",PlatformCredential="${decrypted_platform_credential}"  || return $? )"
  else
    platform_app_arn="$(aws --region "${region}" sns create-platform-application --name "${name}" \
      --attributes PlatformPrincipal="${decrypted_platform_principal}",PlatformCredential="${decrypted_platform_credential}" \
      --platform="${engine}" --query 'PlatformApplicationArn' --output text )"
  fi

  update_platform_app="$(aws --region "${region}" sns set-platform-application-attributes --platform-application-arn "${platform_app_arn}" --cli-input-json "file://${configfile}_decrypted"  || return $? )"

  if [[ -z "${platform_app_arn}" ]]; then
    fatal "Platform app was not deployed"
    return 255
  else
    echo "${platform_app_arn}"
    return 0
  fi

}

function delete_sns_platformapp() {
  local region="$1"; shift
  local arn="$1"; shift

  aws --region "${region}" sns delete-platform-application --platform-application-arn "${arn}" || return $?
}

function cleanup_sns_platformapps() {
  local region="$1"; shift
  local mobile_notifier_name="$1"; shift
  local expected_platform_arns="$1"; shift

  pushTempDir "${mobile_notifier_name}_cleanup_XXXXXX"
  local tmp_file="$(getTopTempDir)/cleanup.sh"

  all_platform_apps="$(aws --region "${region}" sns list-platform-applications )"
  current_platform_arns="$(echo "${all_platform_apps}" | jq --arg namefilter "${mobile_notifier_name}" -rc '.PlatformApplications[] | select( .PlatformApplicationArn | endswith("/" + $namefilter)) | [ .PlatformApplicationArn ]')"

  if [[ -n "${current_platform_arns}" ]]; then
    unexpected_platform_arns="$(echo "${expected_platform_arns}" | jq --argjson currentarns "${current_platform_arns}" '. - $currentarns')"
    info "Found the following unexpected Platforms: ${unexpected_platform_arns}"
    echo "${unexpected_platform_arns}" | jq --arg region "${region}" -r '.[] | "delete_sns_platform \($region) \(.)"' > "${tmp_file}"

    if [[ -f "${tmp_file}" ]]; then
      chmod u+x "${tmp_file}"
      "${tmp_file}"
    fi
  fi

  popTempDir
  return $?
}

function update_sms_account_attributes() {
  local region="$1"; shift
  local configfile="$1"; shift

  aws --region "${region}" sns set-sms-attributes --cli-input-json "file://${configfile}" || return $?
}

# -- PKI --
function create_pki_credentials() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift
  local publickeyname="$1"; shift
  local privatekeyname="$1"; shift
  local include_legacy="$1"; shift

  include_legacy="${include_legacy:-"true"}"
  create_key="false"

  if [[ "${include_legacy}" == "true" ]]; then

    if [[ (! -f "${dir}/aws-ssh-crt.pem") &&
          (! -f "${dir}/aws-ssh-prv.pem") &&
          (! -f "${dir}/.aws-ssh-crt.pem") &&
          (! -f "${dir}/.aws-ssh-prv.pem") &&
          (! -f "${dir}/.aws-${account}-${region}-ssh-crt.pem") &&
          (! -f "${dir}/.aws-${account}-${region}-ssh-prv.pem") ]]; then

        create_key="true"
    fi

  else
    if [[ (! -f "${dir}/${publickeyname}") &&
          (! -f "${dir}/${privatekeyname}") ]]; then

        create_key="true"
    fi
  fi

  if [[ "${create_key}" == "true" ]]; then
        openssl genrsa -out "${dir}/${privatekeyname}.plaintext" 2048 || return $?
        openssl rsa -in "${dir}/${privatekeyname}.plaintext" -pubout > "${dir}/${publickeyname}" || return $?
  fi

  if [[ ! -f "${dir}/.gitignore" ]]; then
    cat << EOF > "${dir}/.gitignore"
*.plaintext
*.decrypted
*.ppk
EOF
  fi

  return 0
}

function delete_pki_credentials() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift
  local publickeyname="$1"; shift
  local privatekeyname="$1"; shift

  local restore_nullglob="$(shopt -p nullglob)"
  shopt -s nullglob

  rm -f "${dir}"/.aws-${account}-${region}-ssh-crt* "${dir}"/.aws-${account}-${region}-ssh-prv* "${dir}"/${publickeyname}* "${dir}"/${privatekeyname}*

  ${restore_nullglob}
}
# -- SSH --

function check_ssh_credentials() {
  local region="$1"; shift
  local name="$1"; shift

  aws --region "${region}" ec2 describe-key-pairs --key-name "${name}" > /dev/null 2>&1
}

function show_ssh_credentials() {
  local region="$1"; shift
  local name="$1"; shift

  aws --region "${region}" ec2 describe-key-pairs --key-name "${name}"
}

function update_ssh_credentials() {
  local region="$1"; shift
  local name="$1"; shift
  local key_file="$1"; shift

  local ssh_key_file="$( getTempFile ssh_pub_key_XXXXX )"

  chmod 400 "${key_file}"
  ssh-keygen -y -f "${key_file}" > "${ssh_key_file}"
  aws --region "${region}" ec2 import-key-pair --key-name "${name}" --public-key-material "fileb://${ssh_key_file}"
}

function delete_ssh_credentials() {
  local region="$1"; shift
  local name="$1"; shift

  aws --region "${region}" ec2 describe-key-pairs --key-name "${name}" > /dev/null 2>&1 && \
    { aws --region "${region}" ec2 delete-key-pair --key-name "${name}" || return $?; }

  return 0
}


# -- SSM --

function cleanup_ssm_document() {
  local region="$1"; shift
  local name="$1"; shift

  listDocument="$(aws --region "${region}" ssm list-documents  --filters Key=Name,Values="${name}" --query 'DocumentIdentifiers[*].Name' --output text )"

  if [[ -n "${listDocument}" ]]; then

    info "Removing Document ${name}"
    aws --region "${region}" ssm delete-document --name "${name}" || return $?

  fi
}

# -- Transfer --
function manage_transfer_security_groups() {
    local region="$1"; shift
    local operation="$1"; shift
    local cfnStackName="$1"; shift
    local securityGroupId="$1"; shift
    local transferServerId="$1"; shift

    securityGroup="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${securityGroupId}" "ref" || return $?)"
    defaultSecurityGroup="$( aws --region "${region}" ec2 describe-security-groups --filter Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text || return $?)"

    transferServer="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${transferServerId}" "name" || return $?)"
    vpcEndpoint="$( aws --region "${region}" transfer describe-server --server-id "${transferServer}" --query 'Server.EndpointDetails.VpcEndpointId' --output text || return $?)"

    case ${operation} in
      delete)
        if [[ -n "${defaultSecurityGroup}" ]]; then
          aws --region "${region}" ec2 modify-vpc-endpoint --vpc-endpoint-id "${vpcEndpoint}" --add-security-group-ids "${defaultSecurityGroup}" --output text || return $?
        fi
        aws --region "${region}" ec2 modify-vpc-endpoint --vpc-endpoint-id "${vpcEndpoint}" --remove-security-group-ids "${securityGroup}" --output text || return $?
        ;;

      update|create)
        aws --region "${region}" ec2 modify-vpc-endpoint --vpc-endpoint-id "${vpcEndpoint}" --add-security-group-ids "${securityGroup}" --output text || return $?
        if [[ -n "${defaultSecurityGroup}" ]]; then
          aws --region "${region}" ec2 modify-vpc-endpoint --vpc-endpoint-id "${vpcEndpoint}" --remove-security-group-ids "${defaultSecurityGroup}" --output text || return $?
        fi
        ;;
    esac
}

# -- Transit Gateway --

function get_transitgateway_vpn_attachment() {
  local region="$1"; shift
  local cfnStackName="$1"; shift
  local vpnConnectionId="$1"; shift

  vpnConnection="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${vpnConnectionId}" "ref" || return $?)"
  transitGatewayAttachment="$( aws --region "${region}" ec2 describe-transit-gateway-attachments --filters "Name=resource-id,Values=${vpnConnection}" --query 'TransitGatewayAttachments[*].TransitGatewayAttachmentId' --output text || return $? )"

  echo "${transitGatewayAttachment}"
  return 0
}

# -- VPN Gateway --
function get_vpn_connection_tunnel_ips() {
  local region="${1}"; shift
  local cfnStackName="$1"; shift
  local vpnConnectionId="${1}"; shift

  vpnConnection="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${vpnConnectionId}" "ref" || return $?)"
  echo "$( aws --region "${region}" ec2 describe-vpn-connections --output text --vpn-connection-ids ${vpnConnection} --query 'VpnConnections[0].VgwTelemetry[].[OutsideIpAddress]' || return $? )"
}

function update_vpn_options() {
  local region="${1}"; shift
  local cfnStackName="$1"; shift
  local vpnConnectionId="${1}"; shift
  local vpnTunnelIndex="${1}"; shift
  local configfile="${1}"; shift

  vpnConnection="$(get_cloudformation_stack_output "${region}" "${cfnStackName}" "${vpnConnectionId}" "ref" || return $?)"
  vpnIPList=( $( aws --region "${region}" ec2 describe-vpn-connections --output text --filters Name=vpn-connection-id,Values="${vpnConnection}" --query 'VpnConnections[0].VgwTelemetry[*].OutsideIpAddress' || return $? ) )

  aws --region "${region}" ec2 wait vpn-connection-available --vpn-connection-ids "${vpnConnection}" || return $?

  for vpn_ip in "${vpnIPList[vpnTunnelIndex]}"; do
    info "Updating VPN: ${vpnConnection} - IP: ${vpn_ip}"
    aws --region "${region}" ec2 modify-vpn-tunnel-options --vpn-connection-id "${vpnConnection}" --vpn-tunnel-outside-ip-address "${vpn_ip}" --cli-input-json "file://${configfile}" || return $?
    aws --region "${region}" ec2 wait vpn-connection-available --vpn-connection-ids "${vpnConnection}" || return $?
  done
}

# -- OAI --

function update_oai_credentials() {
  local region="$1"; shift
  local name="$1"; shift
  local result_file="${1:-$( getTempFile update_oai_XXXXXX.json)}"; shift

  local oai_list_file="$( getTempFile oai_list_XXXXXX.json)"
  local oai_id=

  # Check for existing identity
  aws --region "${region}" cloudfront list-cloud-front-origin-access-identities > "${oai_list_file}" || return $?
  jq ".CloudFrontOriginAccessIdentityList.Items[] | select(.Comment==\"${name}\")" < "${oai_list_file}" > "${result_file}" || return $?
  oai_id=$(jq -r ".Id" < "${result_file}") || return $?

  # Create if not there already
  if [[ -z "${oai_id}" ]]; then
    set -o pipefail
    aws --region "${region}" cloudfront create-cloud-front-origin-access-identity \
      --cloud-front-origin-access-identity-config "{\"Comment\" : \"${name}\", \"CallerReference\" : \"${name}\"}" | jq ".CloudFrontOriginAccessIdentity" > "${result_file}" || return $?
    set +o pipefail
  fi

  # Show the current credential
  cat "${result_file}"

  return 0
}

function delete_oai_credentials() {
  local region="$1"; shift
  local name="$1"; shift

  local oai_delete_file="$( getTempFile oai_delete_XXXXXX.json)"
  local oai_id=
  local oai_etag=

  # Check for existing identity
  aws --region "${region}" cloudfront list-cloud-front-origin-access-identities > "${oai_delete_file}" || return $?
  oai_id=$(jq -r ".CloudFrontOriginAccessIdentityList.Items[] | select(.Comment==\"${name}\") | .Id" < "${oai_delete_file}") || return $?

  # delete if present
  if [[ -n "${oai_id}" ]]; then
    # Retrieve the ETag value
    aws --region "${region}" cloudfront get-cloud-front-origin-access-identity --id "${oai_id}" > "${oai_delete_file}" || return $?
    oai_etag=$(jq -r ".ETag" < "${oai_delete_file}") || return $?
    # Delete the OAI
    aws --region "${region}" cloudfront delete-cloud-front-origin-access-identity --id "${oai_id}" --if-match "${oai_etag}" || return $?
  fi

  return 0
}

function is_oai_credential_used() {
  local region="$1"; shift
  local name="$1"; shift

  # Check for existing identity
  oai_id=$(aws --region "${region}" cloudfront list-cloud-front-origin-access-identities \
  --query "CloudFrontOriginAccessIdentityList.Items[?Comment=='${name}'].Id" --output text) || return $?

  # check if used if present
  if [[ -n "${oai_id}" ]]; then
    oai_ids=$(aws --region "${region}" cloudfront list-distributions --query "DistributionList.Items[].Origins.Items[].S3OriginConfig.OriginAccessIdentity" --output text) || return $?
    if [[ -n "${oai_ids}" ]]; then
      if contains "${oai_ids}" "${oai_id}"; then
        echo "true"
        return 0
      fi
    fi
  fi

  # Not in use
  echo "false"
  return 0
}

# -- RDS --

function add_tag_rds_resource() {
  local region="$1"; shift
  local rds_identifier="$1"; shift
  local key="${1}"; shift
  local value="${1}"; shift

  aws --region "${region}" rds add-tags-to-resource --resource-name "${rds_identifier}" --tags "Key=${key},Value=${value}" || return $?

}

function create_snapshot() {
  local region="$1"; shift
  local db_type="$1"; shift
  local db_identifier="$1"; shift
  local db_snapshot_identifier="$1"; shift

  # Check that the database exists
  if [[ "${db_type}" == "cluster" ]]; then
    db_info=$(aws --region "${region}" rds describe-db-clusters --db-cluster-identifier ${db_identifier} )

    if [[ -n "${db_info}" ]]; then
      aws --region "${region}" rds create-db-cluster-snapshot --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  --db-cluster-identifier "${db_identifier}" 1> /dev/null || return $?
    else
      info "Could not find db ${db_identifier} - Skipping pre-deploy snapshot"
      return 0
    fi

    sleep 5
    while [ "${exit_status}" != "0" ]
    do
        SNAPSHOT_STATE="$(aws --region "${region}" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" --query 'DBClusterSnapshots[0].Status' || return $? )"
        SNAPSHOT_PROGRESS="$(aws --region "${region}" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" --query 'DBClusterSnapshots[0].PercentProgress' || return $? )"
        info "Snapshot id ${db_snapshot_identifier} creation: state is ${SNAPSHOT_STATE}, ${SNAPSHOT_PROGRESS}%..."

        aws --region "${region}" rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "${db_snapshot_identifier}"
        exit_status="$?"
    done

    db_snapshot=$(aws --region "${region}" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $?)
    info "Snapshot Created - $(echo "${db_snapshot}" | jq -r '.DBClusterSnapshots[0] | .DBSnapshotIdentifier + " " + .SnapshotCreateTime' )"

  else
    db_info=$(aws --region "${region}" rds describe-db-instances --db-instance-identifier ${db_identifier} )

    if [[ -n "${db_info}" ]]; then
      aws --region "${region}" rds create-db-snapshot --db-snapshot-identifier "${db_snapshot_identifier}"  --db-instance-identifier "${db_identifier}" 1> /dev/null || return $?
    else
      info "Could not find db ${db_identifier} - Skipping pre-deploy snapshot"
      return 0
    fi

    sleep 5
    while [ "${exit_status}" != "0" ]
    do
        SNAPSHOT_STATE="$(aws --region "${region}" rds describe-db-snapshots --db-snapshot-identifier "${db_snapshot_identifier}" --query 'DBSnapshots[0].Status' || return $? )"
        SNAPSHOT_PROGRESS="$(aws --region "${region}" rds describe-db-snapshots --db-snapshot-identifier "${db_snapshot_identifier}" --query 'DBSnapshots[0].PercentProgress' || return $? )"
        info "Snapshot id ${db_snapshot_identifier} creation: state is ${SNAPSHOT_STATE}, ${SNAPSHOT_PROGRESS}%..."

        aws --region "${region}" rds wait db-snapshot-available --db-snapshot-identifier "${db_snapshot_identifier}"
        exit_status="$?"
    done

    db_snapshot=$(aws --region "${region}" rds describe-db-snapshots --db-snapshot-identifier "${db_snapshot_identifier}" || return $?)
    info "Snapshot Created - $(echo "${db_snapshot}" | jq -r '.DBSnapshots[0] | .DBSnapshotIdentifier + " " + .SnapshotCreateTime' )"
  fi
}

function encrypt_snapshot() {
  local region="$1"; shift
  local db_type="$1"; shift
  local db_snapshot_identifier="$1"; shift
  local kms_key_id="$1"; shift

  if [[ "${db_type}" == "cluster" ]]; then
    # Check the snapshot status
    snapshot_info=$(aws --region "${region}" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $? )

    if [[ -n "${snapshot_info}" ]]; then
      if [[ $(echo "${snapshot_info}" | jq -r '.DBClusterSnapshots[0].Status == "available"') ]]; then

        if [[ $(echo "${snapshot_info}" | jq -r '.DBClusterSnapshots[0].StorageEncrypted') == false ]]; then

          info "Converting snapshot ${db_snapshot_identifier} to an encrypted snapshot"

          # create encrypted snapshot
          aws --region "${region}" rds copy-db-cluster-snapshot \
            --source-db-cluster-snapshot-identifier "${db_snapshot_identifier}" \
            --target-db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
            --kms-key-id "${kms_key_id}" 1> /dev/null || return $?

          info "Waiting for temp encrypted snapshot to become available..."
          sleep 2
          aws --region "${region}" rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" || return $?

          info "Removing plaintext snapshot..."
          # delete the original snapshot
          aws --region "${region}" rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  1> /dev/null || return $?
          aws --region "${region}" rds wait db-cluster-snapshot-deleted --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  || return $?

          # Copy snapshot back to original identifier
          info "Renaming encrypted snapshot..."
          aws --region "${region}" rds copy-db-cluster-snapshot \
            --source-db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
            --target-db-cluster-snapshot-identifier "${db_snapshot_identifier}" 1> /dev/null || return $?

          sleep 2
          aws --region "${region}" rds wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  || return $?

          # Remove the encrypted temp snapshot
          aws --region "${region}" rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}"  1> /dev/null || return $?
          aws --region "${region}" rds wait db-cluster-snapshot-deleted --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}"  || return $?

          db_snapshot=$(aws --region "${region}" rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $?)
          info "Snapshot Converted - $(echo "${db_snapshot}" | jq -r '.DBClusterSnapshots[0] | .DBClusterSnapshotIdentifier + " " + .SnapshotCreateTime + " Encrypted: " + (.StorageEncrypted|tostring)' )"

          return 0

        else

          echo "Snapshot ${db_snapshot_identifier} already encrypted"
          return 0

        fi

      else
        echo "Snapshot not in a usuable state $(echo "${snapshot_info}")"
        return 255
      fi
    fi

  else

    # Check the snapshot status
    snapshot_info=$(aws --region "${region}" rds describe-db-snapshots --db-snapshot-identifier "${db_snapshot_identifier}" || return $? )

    if [[ -n "${snapshot_info}" ]]; then
      if [[ $(echo "${snapshot_info}" | jq -r '.DBSnapshots[0].Status == "Available"') ]]; then

        if [[ $(echo "${snapshot_info}" | jq -r '.DBSnapshots[0].Encrypted') == false ]]; then

          info "Converting snapshot ${db_snapshot_identifier} to an encrypted snapshot"

          # create encrypted snapshot
          aws --region "${region}" rds copy-db-snapshot \
            --source-db-snapshot-identifier "${db_snapshot_identifier}" \
            --target-db-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
            --kms-key-id "${kms_key_id}" 1> /dev/null || return $?

          info "Waiting for temp encrypted snapshot to become available..."
          sleep 2
          aws --region "${region}" rds wait db-snapshot-available --db-snapshot-identifier "encrypted-${db_snapshot_identifier}" || return $?

          info "Removing plaintext snapshot..."
          # delete the original snapshot
          aws --region "${region}" rds delete-db-snapshot --db-snapshot-identifier "${db_snapshot_identifier}"  1> /dev/null || return $?
          aws --region "${region}" rds wait db-snapshot-deleted --db-snapshot-identifier "${db_snapshot_identifier}"  || return $?

          # Copy snapshot back to original identifier
          info "Renaming encrypted snapshot..."
          aws --region "${region}" rds copy-db-snapshot \
            --source-db-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
            --target-db-snapshot-identifier "${db_snapshot_identifier}" 1> /dev/null || return $?

          sleep 2
          aws --region "${region}" rds wait db-snapshot-available --db-snapshot-identifier "${db_snapshot_identifier}"  || return $?

          # Remove the encrypted temp snapshot
          aws --region "${region}" rds delete-db-snapshot --db-snapshot-identifier "encrypted-${db_snapshot_identifier}"  1> /dev/null || return $?
          aws --region "${region}" rds wait db-snapshot-deleted --db-snapshot-identifier "encrypted-${db_snapshot_identifier}"  || return $?

          db_snapshot=$(aws --region "${region}" rds describe-db-snapshots --db-snapshot-identifier "${db_snapshot_identifier}" || return $?)
          info "Snapshot Converted - $(echo "${db_snapshot}" | jq -r '.DBSnapshots[0] | .DBSnapshotIdentifier + " " + .SnapshotCreateTime + " Encrypted: " + (.Encrypted|tostring)' )"

          return 0

        else

          echo "Snapshot ${db_snapshot_identifier} already encrypted"
          return 0

        fi

      else
        echo "Snapshot not in a usuable state $(echo "${snapshot_info}")"
        return 255
      fi
    fi
  fi
}

function set_rds_master_password() {
  local region="$1"; shift
  local db_type="$1"; shift
  local db_identifier="$1"; shift
  local password="$1"; shift

  info "Resetting master password for RDS instance ${db_identifier}"
  if [[ "${db_type}" == "cluster" ]]; then
    aws --region "${region}" rds modify-db-cluster --db-cluster-identifier "${db_identifier}" --master-user-password "${password}" --apply-immediately 1> /dev/null
  else
    aws --region "${region}" rds modify-db-instance --db-instance-identifier ${db_identifier} --master-user-password "${password}" --apply-immediately 1> /dev/null
  fi
}

function get_rds_hostname() {
  local region="$1"; shift
  local db_type="$1"; shift
  local db_identifier="$1"; shift
  local db_endpoint_type="$1"; shift

  if [[ "${db_type}" == "cluster" ]]; then
    if [[ "${db_endpoint_type}" == "read" ]]; then
        hostname="$(aws --region "${region}" rds describe-db-clusters --db-cluster-identifier ${db_identifier} --query 'DBClusters[0].ReaderEndpoint' --output text)"
    else
        hostname="$(aws --region "${region}" rds describe-db-clusters --db-cluster-identifier ${db_identifier} --query 'DBClusters[0].Endpoint' --output text)"
    fi
  else
    hostname="$(aws --region "${region}" rds describe-db-instances --db-instance-identifier ${db_identifier} --query 'DBInstances[0].Endpoint.Address' --output text)"
  fi

  if [[ "${hostname}" != "None" ]]; then
    echo "${hostname}"
    return 0
  else
    fatal "hostname not found for rds instance ${db_identifier}"
    return 255
  fi
}

function check_rds_snapshot_username() {
  local region="$1"; shift
  local db_type="$1"; shift
  local db_snapshot_identifier="$1"; shift
  local expected_username="$1"; shift

  info "Checking snapshot username matches expected username"

  if [[ "${db_type}" == "cluster" ]]; then
    snapshot_username="$( aws --region ${region} rds describe-db-cluster-snapshots --include-shared --include-public --db-cluster-snapshot-identifier ${db_snapshot_identifier} --output text --query 'DBClusterSnapshots[0].MasterUsername || ``' || return $? )"
  else
    snapshot_username="$(aws --region ${region} rds describe-db-snapshots --include-shared --include-public --db-snapshot-identifier ${db_snapshot_identifier} --output text --query 'DBSnapshots[0].MasterUsername || ``' || return $? )"
  fi

  if [[ -n "${snapshot_info}" ]]; then

    if [[ "${snapshot_username}" != "${expected_username}" ]]; then

      error "Snapshot Username does not match the expected username"
      error "Update the RDS username configuration to match the snapshot username"
      error "    Snapshot username: ${snapshot_username}"
      error "    Configured username: ${expected_username}"
      return 128

    else

      info "Snapshot Username is the same as the expected username"
      return 0

    fi
  else

    error "Snapshot ${db_snapshot_identifier} - Not Found"
    return 255

  fi
}

function get_rds_url() {
  local scheme="$1"; shift
  local username="$1"; shift
  local password="$1"; shift
  local fqdn="$1"; shift
  local port="$1"; shift
  local database_name="$1"; shift

  echo "${scheme}://${username}:${password}@${fqdn}:${port}/${database_name}"
}

function update_rds_ca_identifier() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local ca_identifier="$1"; shift

  info "Updating CA for RDS instance ${db_identifier} to ${ca_identifier}"
  aws --region "${region}" rds wait db-instance-available --db-instance-identifier "${db_identifier}" || return $?
  aws --region "${region}" rds modify-db-instance --apply-immediately --db-instance-identifier ${db_identifier} --ca-certificate-identifier "${ca_identifier}" 1> /dev/null || return $?
}

function add_tag_dds_resource() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local key="${1}"; shift
  local value="${1}"; shift

  aws --region "${region}" docdb add-tags-to-resource --resource-name "${db_identifier}" --tags "Key=${key},Value=${value}" || return $?

}

function set_dds_master_password() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local password="$1"; shift

  info "Resetting master password for DocDB instance ${db_identifier}"
  aws --region "${region}" docdb modify-db-cluster --db-cluster-identifier "${db_identifier}" --master-user-password "${password}" --apply-immediately 1> /dev/null
}

function get_dds_hostname() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local db_endpoint_type="$1"; shift

  if [[ "${db_endpoint_type}" == "read" ]]; then
      hostname="$(aws --region "${region}" docdb describe-db-clusters --db-cluster-identifier ${db_identifier} --query 'DBClusters[0].ReaderEndpoint' --output text)"
  else
      hostname="$(aws --region "${region}" docdb describe-db-clusters --db-cluster-identifier ${db_identifier} --query 'DBClusters[0].Endpoint' --output text)"
  fi

  if [[ "${hostname}" != "None" ]]; then
    echo "${hostname}"
    return 0
  else
    fatal "hostname not found for docdb instance ${db_identifier}"
    return 255
  fi
}

function check_dds_snapshot_username() {
  local region="$1"; shift
  local db_snapshot_identifier="$1"; shift
  local expected_username="$1"; shift

  info "Checking snapshot username matches expected username"

  snapshot_info="$(aws --region ${region} docdb describe-db-cluster-snapshots --include-shared --include-public --db-snapshot-identifier ${db_snapshot_identifier} || return $? )"

  if [[ -n "${snapshot_info}" ]]; then
    snapshot_username="$( echo "${snapshot_info}" | jq -r '.DBSnapshots[0].MasterUsername' )"

    if [[ "${snapshot_username}" != "${expected_username}" ]]; then

      error "Snapshot Username does not match the expected username"
      error "Update the RDS username configuration to match the snapshot username"
      error "    Snapshot username: ${snapshot_username}"
      error "    Configured username: ${expected_username}"
      return 128

    else

      info "Snapshot Username is the same as the expected username"
      return 0

    fi
  else

    error "Snapshot ${db_snapshot_identifier} - Not Found"
    return 255

  fi
}

function get_dds_url() {
  local scheme="$1"; shift
  local username="$1"; shift
  local password="$1"; shift
  local fqdn="$1"; shift
  local port="$1"; shift

  echo "${scheme}://${username}:${password}@${fqdn}:${port}/"
}

function update_dds_ca_identifier() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local ca_identifier="$1"; shift

  info "Updating CA for RDS instance ${db_identifier} to ${ca_identifier}"
  aws --region "${region}" docdb wait db-instance-available --db-instance-identifier "${db_identifier}" || return $?
  aws --region "${region}" docdb modify-db-instance --apply-immediately --db-instance-identifier ${db_identifier} --ca-certificate-identifier "${ca_identifier}" 1> /dev/null || return $?
}

function create_dds_snapshot() {
  local region="$1"; shift
  local db_identifier="$1"; shift
  local db_snapshot_identifier="$1"; shift

  # Check that the database exists
  db_info=$(aws --region "${region}" docdb describe-db-clusters --db-cluster-identifier ${db_identifier} )

  if [[ -n "${db_info}" ]]; then
    aws --region "${region}" docdb create-db-cluster-snapshot --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  --db-cluster-identifier "${db_identifier}" 1> /dev/null || return $?
  else
    info "Could not find db ${db_identifier} - Skipping pre-deploy snapshot"
    return 0
  fi

  sleep 180
  while [ "${SNAPSHOT_PROGRESS}" != "100" ]
  do
      SNAPSHOT_STATE="$(aws --region "${region}" docdb describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" --query 'DBClusterSnapshots[0].Status' || return $? )"
      SNAPSHOT_PROGRESS="$(aws --region "${region}" docdb describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" --query 'DBClusterSnapshots[0].PercentProgress' || return $? )"
      info "Snapshot id ${db_snapshot_identifier} creation: state is ${SNAPSHOT_STATE}, ${SNAPSHOT_PROGRESS}%..."

      # not support for docdb: aws --region "${region}" docdb wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "${db_snapshot_identifier}"
      # exit_status="$?"
      sleep 20
  done

  db_snapshot=$(aws --region "${region}" docdb describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $?)
  info "Snapshot Created - $(echo "${db_snapshot}" | jq -r '.DBClusterSnapshots[0] | .DBSnapshotIdentifier + " " + .SnapshotCreateTime' )"
}

function encrypt_dds_snapshot() {
  local region="$1"; shift
  local db_snapshot_identifier="$1"; shift
  local kms_key_id="$1"; shift

  # Check the snapshot status
  snapshot_info=$(aws --region "${region}" docdb describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $? )

  if [[ -n "${snapshot_info}" ]]; then
    if [[ $(echo "${snapshot_info}" | jq -r '.DBClusterSnapshots[0].Status == "available"') ]]; then

      if [[ $(echo "${snapshot_info}" | jq -r '.DBClusterSnapshots[0].StorageEncrypted') == false ]]; then

        info "Converting snapshot ${db_snapshot_identifier} to an encrypted snapshot"

        # create encrypted snapshot
        aws --region "${region}" docdb copy-db-cluster-snapshot \
          --source-db-cluster-snapshot-identifier "${db_snapshot_identifier}" \
          --target-db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
          --kms-key-id "${kms_key_id}" 1> /dev/null || return $?

        info "Waiting for temp encrypted snapshot to become available..."
        sleep 2
        aws --region "${region}" docdb wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" || return $?

        info "Removing plaintext snapshot..."
        # delete the original snapshot
        aws --region "${region}" docdb delete-db-cluster-snapshot --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  1> /dev/null || return $?
        aws --region "${region}" docdb wait db-cluster-snapshot-deleted --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  || return $?

        # Copy snapshot back to original identifier
        info "Renaming encrypted snapshot..."
        aws --region "${region}" docdb copy-db-cluster-snapshot \
          --source-db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}" \
          --target-db-cluster-snapshot-identifier "${db_snapshot_identifier}" 1> /dev/null || return $?

        sleep 2
        aws --region "${region}" docdb wait db-cluster-snapshot-available --db-cluster-snapshot-identifier "${db_snapshot_identifier}"  || return $?

        # Remove the encrypted temp snapshot
        aws --region "${region}" docdb delete-db-cluster-snapshot --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}"  1> /dev/null || return $?
        aws --region "${region}" docdb wait db-cluster-snapshot-deleted --db-cluster-snapshot-identifier "encrypted-${db_snapshot_identifier}"  || return $?

        db_snapshot=$(aws --region "${region}" docdb describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${db_snapshot_identifier}" || return $?)
        info "Snapshot Converted - $(echo "${db_snapshot}" | jq -r '.DBClusterSnapshots[0] | .DBClusterSnapshotIdentifier + " " + .SnapshotCreateTime + " Encrypted: " + (.StorageEncrypted|tostring)' )"

        return 0

      else

        echo "Snapshot ${db_snapshot_identifier} already encrypted"
        return 0

      fi

    else
      echo "Snapshot not in a usuable state $(echo "${snapshot_info}")"
      return 255
    fi
  fi
}


# -- Git Repo Management --

function is_git_repo() {
  local local_dir="$1";

  git -C "${local_dir}" status >/dev/null 2>&1
}

function init_git_repo() {
  local local_dir="$1";

  is_git_repo "${local_dir}" || git init "${local_dir}"
}

function in_git_repo() {
  is_git_repo
}

function format_git_url() {
  local repo_provider="$1"; shift
  local repo_host="$1"; shift
  local repo_path="$1"; shift

  if [[  (-n "${repo_provider}") &&
      (-n "${repo_host}") &&
      (-n "${repo_path}") ]]; then
    local credentials_var="${repo_provider^^}_CREDENTIALS"
    printf "https://%s%s/%s" "${!credentials_var:+${!credentials_var}@}" "${repo_host}" "${repo_path}"
  else
    printf ""
  fi
}

function find_auth_for_git_url() {
  local repo_url="$1"; shift

  repo_provider="$( git_provider_from_host "${repo_url}" )"
  local credentials_var="${repo_provider^^}_CREDENTIALS"
  if [[ -n "${!credentials_var}" ]]; then
    echo "${repo_url/\/\////${!credentials_var}@}"
  else
    echo "${repo_url}"
  fi
}

function git_provider_from_host() {
  local repo_url="$1"; shift

  host="$( get_url_component "${repo_url}" "host" )"
  case $host in
    github.com)
      echo "github"
      ;;

    gitlab.com)
      echo "gitlab"
      ;;

    *)
      echo "git"
      ;;
  esac
}

function clone_git_repo() {
  local repo_url="$1"; shift
  local repo_branch="$1"; shift
  local local_dir="$1";

  check_for_invalid_environment_variables "repo_url" "repo_branch" "local_dir" || return $?

  debug "Cloning the ${repo_url} repo and checking out the ${repo_branch} branch ..."

  git clone -b "${repo_branch}" "${repo_url}" "${local_dir}"
  RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Can't clone ${repo_url} repo" && return 1

  return 0
}

function push_git_repo() {
  local repo_url="$1"; shift
  local repo_branch="$1"; shift
  local repo_remote="$1"; shift
  local commit_message="$1"; shift
  local git_user="$1"; shift
  local git_email="$1"; shift
  local local_dir="$1"; shift
  local tries="${1:-6}";

  check_for_invalid_environment_variables "repo_url" "repo_branch" "repo_remote" "commit_message" "git_user" "git_email" "local_dir" || return $?

  git  -C "${local_dir}" remote show "${repo_remote}" >/dev/null 2>&1
  RESULT=$? && [[ ${RESULT} -ne 0 ]] && fatal "Remote ${repo_remote} is not initialised" && return 1

  # Ensure git knows who we are
  git -C "${local_dir}" config user.name  "${git_user}"
  git -C "${local_dir}" config user.email "${git_email}"

  # Add anything that has been added/modified/deleted
  git  -C "${local_dir}" add -A

  if [[ -n "$(git status --porcelain)" ]]; then
    # Commit changes
    debug "Committing to the ${repo_url} repo..."
    git  -C "${local_dir}" commit -m "${commit_message}" ||
      (fatal "Can't commit to the ${repo_url} repo"; return 1; )

    # Update upstream repo
    for try in $( seq 1 ${tries} ); do
      # Check if remote branch exists
      local existing_branch=$(git  -C "${local_dir}" ls-remote --heads 2>/dev/null | grep "refs/heads/${repo_branch}$")
      if [[ -n "${existing_branch}" ]]; then
        debug "Rebasing from ${repo_url} in case of changes..."
        git  -C "${local_dir}" pull --rebase ${repo_remote} ${repo_branch} ||
          (fatal "Can't rebase the ${repo_url} repo from upstream ${repo_remote}"; return 1; )
      fi

      debug "Pushing the ${repo_url} repo upstream..."
      if git  -C "${local_dir}" push ${repo_remote} ${repo_branch}; then
        # Push succeeded
        return 0
      else
        # Take a breather
        info "Waiting to retry push to ${repo_url} repo ..."
        sleep 5
      fi
    done

    fatal "Can't push the ${repo_url} repo changes to upstream repo ${repo_remote}"
    return 1
  fi

  return 0
}

function git_mv() {
  in_git_repo && git mv "$@" || mv "$@"
}

function git_rm() {
  in_git_repo && git rm "$@" || rm "$@"
}

# -- conventional commits --
# https://www.conventionalcommits.org/

# Basic structure of conventional commit
# For a breaking commit with no footer, use "!" for the breaking comment
# Description is limited to 50 chars in alignment with git best practices
# Any description longer than that is split across the description and the
# first line of the body
function format_conventional_commit() {
  local type="${1,,}"; shift
  local scope="${1,,}"; shift
  local description="${1}"; shift
  local body="${1}"; shift
  local footer="${1}"; shift
  local breaking="${1}"; shift

  local result=""
  printf -v result "%s%s%s: %s\n" "${type}" "${scope:+(${scope})}" "${breaking:+!}" "${description}"

  # Need to allow for the LF at the end in deciding when to split
  if [[ "${#result}" -gt 51 ]]; then
    printf -v result "%s\n" "${result:0:50}"
  fi
  [[ -n "${body}" ]] && printf -v result "%s\n%s\n" "${result}" "${body}"
  [[ -n "${footer}" || -n "${breaking}" ]] && printf -v result "%s\n" "${result}"
  [[ -n "${footer}" ]] && printf -v result "%s%s\n" "${result}" "${footer}"
  [[ -n "${breaking}" && "${breaking}" != "!" ]] && printf -v result "%sBREAKING CHANGE: %s\n" "${result}" "${breaking}"

  echo -n "${result}"
}

# Name=value pairs converted to name: value on separate lines
# Multiple comma separated pairs can be included in one parameter or as individual parameters
# Any resulting leading or trailing spaces are removed
function format_conventional_commit_body() {
  local pairsList=("$@")

  local result=""
  local pairArray=()
  local trimRegex='^[[:blank:]]*(.+)[[:blank:]]*$'
  local pairRegex='^([^[:blank:]]+)[[:blank:]]*:[[:blank:]]*(.+)$'

  for pairsItem in "${pairsList[@]}"; do
    arrayFromList pairArray "${pairsItem}" ","

    for pair in "${pairArray[@]}"; do
      if [[ "${pair//=/: }" =~ $trimRegex ]]; then
        local trimmedPair="${BASH_REMATCH[1]}"
        if [[ "${trimmedPair}" =~ $pairRegex ]]; then
          printf -v result "%s%-15s: %s\n" "${result}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        else
          printf -v result "%s%s\n" "${result}" "${trimmedPair}"
        fi
      fi
    done
  done

  echo -n "${result}"
}

# Extract a subset of summary values
# If match=first, then the first match terminates the extract
format_conventional_commit_body_summary() {
  local body="$1"; shift
  local subset=($1); shift
  local match="${1:-all}"; shift

  local pairRegex='^([^[:blank:]]+)[[:blank:]]*:[[:blank:]]*(.+)$'

  declare -A valueArray

  # Collect the name/value pairs
  readarray -t pairArray <<< "${body}"
  for pair in "${pairArray[@]}"; do
    if [[ "${pair}" =~ $pairRegex ]]; then
      valueArray["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done

  local summary=
  # Construct the summary
  for part in "${subset[@]}"; do
    if [[ -n "${valueArray[${part}]}" ]]; then
      if [[ "${match}" == "first" ]]; then
        local summary="${valueArray[${part}]}"
        break
      else
        local summary="${summary}${summary:+-}${valueArray[${part}]}"
      fi
    fi
  done

  echo -n "${summary}"
}

# Exclude pairs from the body
format_conventional_commit_body_subset() {
  local body="$1"; shift
  local exclusions=($1); shift

  local pairRegex='^([^[:blank:]]+)[[:blank:]]*:[[:blank:]].*$'

  local subset=
  readarray -t pairArray <<< "${body}"
  for pair in "${pairArray[@]}"; do
    if [[ "${pair}" =~ $pairRegex ]]; then
      local pairName="${BASH_REMATCH[1]}"
      if ! inArray "exclusions" "${pairName}"; then
        printf -v subset "%s%s\n" "${subset}" "${pair}"
      fi
    fi
  done

  echo -n "${subset}"
}

# -- semver handling --
# Comparisons/naming roughly aligned to https://github.com/npm/node-semver
# in case we want to replace these routines with calls to this package via
# docker

function semver_valid {
  local version="$1"

  [[ "$version" =~ ^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\-([^+]+))?(\+(.*))?$ ]] ||
    { echo -n "?"; return 1; }

  local major=${BASH_REMATCH[1]}
  local minor=${BASH_REMATCH[2]}
  local patch=${BASH_REMATCH[3]}
  local prere=${BASH_REMATCH[5]}
  local build=${BASH_REMATCH[7]}

  echo -n ${major} ${minor} ${patch} ${prere} ${build}
  return 0
}

# Strip any leading "v" (note we handle leading = in semver_satisfies)
# Convert any range indicators ("x" or "X") to 0
# * not supported as substitute for x
function semver_clean {
  local version="$1"

  # Handle the full format
  if [[ "$version" =~ ^v?(0|[1-9][0-9]*|x|X)\.(0|[1-9][0-9]*|x|X)\.(0|[1-9][0-9]*|x|X)(\-([^+]+))?(\+(.*))?$ ]]; then

    local major="$(echo ${BASH_REMATCH[1]} | tr "xX" "0")"
    local minor="$(echo ${BASH_REMATCH[2]} | tr "xX" "0")"
    local patch="$(echo ${BASH_REMATCH[3]} | tr "xX" "0")"
    local prere=${BASH_REMATCH[5]}
    local build=${BASH_REMATCH[7]}

    echo -n "${major}.${minor}.${patch}${prere:+-}${prere}${build:++}${build}"
    return 0
  fi

  # Handle major.minor
  if [[ "$version" =~ ^v?(0|[1-9][0-9]*|x|X)\.(0|[1-9][0-9]*|x|X)$ ]]; then

    local major="$(echo ${BASH_REMATCH[1]} | tr "xX" "0")"
    local minor="$(echo ${BASH_REMATCH[2]} | tr "xX" "0")"

    echo -n "${major}.${minor}.0"
    return 0
  fi

  # Handle major
  if [[ "$version" =~ ^v?(0|[1-9][0-9]*|x|X)$ ]]; then

    local major="$(echo ${BASH_REMATCH[1]} | tr "xX" "0")"

    echo -n "${major}.0.0"
    return 0
  fi

  # Not valid
  echo -n "?"
  return 1
}

function semver_compare {
  local v1="$(semver_clean "$1")"; shift
  local v2="$(semver_clean "$1")"; shift

  semver_valid "${v1}" > /dev/null &&
      semver_valid "${v2}" > /dev/null ||
      { echo -n "?"; return 1; }

  local v1_components=($(semver_valid "${v1}"))
  local v2_components=($(semver_valid "${v2}"))

  # MAJOR, MINOR and PATCH should compare numericaly
  for i in 0 1 2; do
    local diff=$((${v1_components[$i]} - ${v2_components[$i]}))
    if [[ ${diff} -lt 0 ]]; then
      echo -n -1; return 0
    elif [[ ${diff} -gt 0 ]]; then
      echo -n 1; return 0
    fi
  done

  # PREREL should compare with the ASCII order.
  if [[ -z "${v1_components[3]}" ]] && [[ -n "${v2_components[3]}" ]]; then
    echo -n -1; return 0;
  elif [[ -n "${v1_components[3]}" ]] && [[ -z "${v2_components[3]}" ]]; then
    echo -n 1; return 0;
  elif [[ -n "${v1_components[3]}" ]] && [[ -n "${v2_components[3]}" ]]; then
    if [[ "${v1_components[3]}" > "${v2_components[3]}" ]]; then
      echo -n 1; return 0;
    elif [[ "${v1_components[3]}" < "${v2_components[3]}" ]]; then
      echo -n -1; return 0;
    fi
  fi

  echo -n 0
}

# a range is a list of comparator sets joined by "||"" or "|", true if one of sets is true
# a comparator set is a list of comparators, true if all comparators are true
# a comparator is an operator and a version
function semver_satisfies {
  local version="$1"; shift
  local range=$@

  # First determine the comparator sets
  # Standardise on single "|" as separator
  declare -a comparator_sets
  arrayFromList comparator_sets "${range//||/|}" "|"

  for comparator_set in "${comparator_sets[@]}"; do
    debug "Checking comparator set \"${comparator_set}\" ..."

    # Now determine the comparators for each set
    declare -a comparators
    arrayFromList comparators "${comparator_set}"

    # Assume all comparators will match
    local match=0

    for comparator in "${comparators[@]}"; do
      debug "Checking comparator \"${comparator}\" ..."

      # Split into operator and version
      [[ "$comparator" =~ ^(<|<=|>|>=|=)(.+)$ ]] || return 1
      local operator="${BASH_REMATCH[1]}"
      local comparator_version="$(semver_clean "${BASH_REMATCH[2]}")"

      # Do the version comparison
      comparator_result="$(semver_compare "${version}" "${comparator_version}")"
      [[ "${comparator_result}" == "?" ]] && return 1

      debug "Comparing \"${version}\" to \"${comparator_version}\", result=${comparator_result}"

      # Process the operator
      case "${operator}" in
        \<)
          [[ "${comparator_result}" -lt 0 ]] && continue
          ;;

        \<=)
          [[ "${comparator_result}" -le 0 ]] && continue
          ;;

        \>)
          [[ "${comparator_result}" -gt 0 ]] && continue
          ;;

        \>=)
          [[ "${comparator_result}" -ge 0 ]] && continue
          ;;

        =)
          [[ "${comparator_result}" -eq 0 ]] && continue
          ;;

        *)
          match=1
          ;;
      esac
      match=1
      break
    done

    # All comparators matched so success (this comparator set is true)
    [[ ${match} -eq 0 ]] && return 0

  done

  return 1
}

function semver_upgrade_list() {
  local upgrade_list=($1);shift
  local maximum_version="$1";shift

  local required_upgrades=()


  # assume upgrade list is ordered
  case "$(semver_compare "${maximum_version}" "${upgrade_list[-1]}")" in
    1|0)
      # Simple optimisation for the common case of all versions being required
      echo -n "${upgrade_list[*]}"
      ;;

    *)
      for upgrade_version in "${upgrade_list[@]}"; do
        if [[ "$(semver_compare "${upgrade_version}" "${maximum_version}")" == "1" ]]; then
          # Ignore all higher versions
          break
        else
          required_upgrades+=("${upgrade_version}")
          continue
        fi
      done

      echo -n "${required_upgrades[*]}"
      ;;
  esac

  return 0
}


# -- Cloudfront handling --
function invalidate_distribution() {
    local region="$1"; shift
    local distribution_id="$1"; shift

    local paths=("/*")
    [[ -n "$1" ]] && local paths=("$@")

    # Note paths is intentionally not escaped as each token needs to be separately parsed
    aws --region "${region}" cloudfront create-invalidation --distribution-id "${distribution_id}" --paths "${paths[@]}"
}

# -- ENI interface removal  --
function release_enis() {
    local region="$1"; shift
    local requester_id="$1"; shift

    eni_interfaces="$( aws --region "${region}" ec2 describe-network-interfaces --filters Name=requester-id,Values="*${requester_id}" || return $? )"

    if [[ -n "${eni_interfaces}" ]]; then
      for attachment_id in $( echo "${eni_interfaces}" | jq -r '.NetworkInterfaces[].Attachment.AttachmentId | select (.!=null)' ) ; do
        if [[ -n "${attachment_id}" ]]; then
            info "Detaching ${attachment_id} ..."
            aws --region "${region}" ec2 detach-network-interface --attachment-id "${attachment_id}"
        fi
      done
      for network_interface_id in $( echo "${eni_interfaces}" | jq -r '.NetworkInterfaces[].NetworkInterfaceId | select (.!=null)' ) ; do
        info "Deleting ${network_interface_id} ..."
        aws --region "${region}" ec2 wait network-interface-available --network-interface-id "${network_interface_id}"
        aws --region "${region}" ec2 delete-network-interface --network-interface-id "${network_interface_id}"
      done
    fi
}

# -- Formatting of openapi definition file  --
function get_openapi_definition_filename() {
  local name="$1"; shift
  local accountId="$1"; shift
  local region="$1"; shift

  echo -n "defn-${name}-${accountId}-${region}-definition.json"
}

# -- Evaluate Mandatory Environment Variables --
function validate_environment_variables(){
  local exit_on_fail="$1"; shift
  local parts=("$@")

  if [[ "${exit_on_fail}" == "true" ]]; then
    # Fail on the very first error.
    for i in "${parts[@]}"; do
      : "${!i:?Undefined mandatory environment variable: $i}"
    done
  else
    # Report missing variables from provided args.
    # Expected to be ||'d to its desired error handling
    return_status=0
    for i in ${exit_on_fail} "${parts[@]}"; do
      # assign a default value, so it doesn't halt
      # immediately on the indirection if missing
      if [[ ${!i:="MISSING_VAR"} == "MISSING_VAR" ]]; then
        fatalMandatory "$i"
        return_status=$(($return_status + 1))
      fi
    done
    return $return_status
  fi
}

function exit_on_invalid_environment_variables(){
  local parts=("$@")
  validate_environment_variables true "${parts[@]}"
}

function check_for_invalid_environment_variables(){
  local parts=("$@")
  validate_environment_variables "${parts[@]}"
}

#-- Container registry handling
function login_to_container_registry {
  local registry="$1"; shift
  local registry_provider="$1"; shift
  local ecr_region="$1"; shift

  case "${registry_provider}" in
    ecr)
      aws --region "${ecr_region}" ecr get-login-password \
        | docker login \
            --username AWS \
            --password-stdin "${registry}" || return $?
      ;;
  esac

  return 0
}

function create_containter_registry_repository {
  local repository="$1"; shift
  local registry="$1"; shift
  local registry_provider="$1"; shift
  local ecr_region="$1";

  case "${registry_provider}" in
    ecr)
      aws --region "${ecr_region}" ecr describe-repositories --repository-names "${repository}" --query 'repositories[0].repositoryName' > /dev/null 2>&1
      if [[ $? -ne 0 ]]; then
          # Not there yet so create it
          info "Creating repository - ${registry} ${repository}"
          aws --region "${ecr_region}" ecr create-repository --repository-name "${repository}" > /dev/null || return $?
      fi
      ## Double check that the registry was created
      info "Double checking repo"
      aws --region "${ecr_region}" ecr describe-repositories --repository-names "${repository}" --output text --query 'repositories[0].repositoryUri'
      ;;
  esac
}


#-- Image sourcing
function get_image_from_url() {
  local url="$1"; shift
  local local_dir="$1"; shift
  local registry_file_name="$1"; shift

  if [[ "$( fileExtension "${url}" )" != "zip" ]]; then
    local_file="${local_dir}/$(fileName "${url}")"
  else
    local_file="${local_dir}/${registry_file_name}"
  fi

  curl --fail --show-error -L -o "${local_file}" "${url}" || return $?
  sha1sum "${local_file}" | cut -d " " -f 1  > "${local_file}.sha1"

  info "* Url Source image details"
  info "  - url: ${url}"
  info "  - sha1: $(cat "${local_file}.sha1" )"
  info "  - local file: ${registry_file_name}"
  return 0
}

function get_url_image_to_registry() {
  local source_url="$1"; shift
  local expected_hash="$1"; shift
  local registry_location="${1}"; shift
  local image_file_name="$1"; shift
  local zip_image_content="${1}"; shift

  pushTempDir "hamlet_imageUrl_XXXXXX"
  local_dir="$(getTopTempDir)"

  get_image_from_url "${source_url}" "${local_dir}" "${image_file_name}"

  if [[ "${zip_image_content}" == "true" && "$(fileExtension "${source_url}")" != "zip" ]]; then
    image_hash="$(cat "${local_dir}/$(fileName "${source_url}").sha1" )"
    ( cd "${local_dir}" && zip -j "${local_dir}/${image_file_name}" "${local_dir}/$(fileName "${source_url}")")
    sha1sum "${local_dir}/${image_file_name}" | cut -d " " -f 1  > "${local_dir}/${image_file_name}.sha1"
  else
    image_hash="$(cat "${local_dir}/${image_file_name}.sha1" )"
  fi

  if [[ -n "${expected_hash}" ]]; then
    if [[ "${image_hash}" != "${expected_hash}" ]]; then
      fatal "Image from url: ${source_url} sha1: ${image_hash} does not match expected sha1 hash: ${expected_hash}"
      return 255
    fi
  fi

  popTempDir

  info "Uploading image to registry ${registry_location}/${expected_hash}"
  if [[ -f "${local_dir}/${image_file_name}" ]]; then
    aws s3 sync --no-progress --delete "${local_dir}" "${registry_location}/${expected_hash}"
  else
    fatal "Could not get image from ${source_url}"
  fi
  return 0
}

function get_image_from_container_registry() {
  local source_image="$1"; shift
  local registry_dns="$1"; shift
  local registry_provider="$1"; shift
  local ecr_region="$1"; shift
  local registry_image="$1"; shift

  image_tool=""

  if docker info &>/dev/null; then

    image_tool="docker"
    docker image pull "${source_image}"

    # Establish the hamlet registry image
    repository_name="${registry_image#*/}"
    repository_name="${repository_name%:*}"
    repository_name="${repository_name%@*}"
    create_containter_registry_repository "${repository_name}" "${registry_dns}" "${registry_provider}" "${ecr_region}" || return $?

    # Push into the hamlet registry
    login_to_container_registry "${registry_dns}" "${registry_provider}" "${ecr_region}" || return $?
    docker tag "${source_image}" "${registry_image}" || return $?
    docker image push "${registry_image}" || return $?

    # Update build references to use the new image
    docker image prune --force
  fi

  if [[ -z "${image_tool}" ]]; then
    warning "No image tools available to deploy the image - skipping pull"
  fi
}

# SES Rule Set Activation
function setActiveSESRuleSet {
  local region="$1"; shift
  local ruleset_name="$1"; shift

  aws --region "${region}" ses set-active-receipt-rule-set --rule-set-name "${ruleset_name}"
}



#----------- Azure --------

#!/usr/bin/env bash

# Utility Functions for the Azure provider
#
# This script is designed to be sourced into other scripts

# -- Storage --

function az_get_storage_connection_string(){
  local storageAccountName="$1"; shift
  local resourceGroup="$1"; shift

  args=(
    "name ${storageAccountName}"
  )

  if [[ -n "${resourceGroup}" ]]; then
    args=("${args[@]}" "resource-group ${resourceGroup}")
  fi

  az storage account show-connection-string \
    ${args[@]/#/--} | jq '.["connectionString"]' || return $?
}

function az_check_blob_container_access() {
  local storageAccountName="$1"; shift
  local containerName="$1"; shift

  az storage container show-permission \
    --name ${containerName} \
    --account-name ${storageAccountName} > /dev/null
}

function az_copy_to_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local blobName="$1"; shift
  local fileName="$1"; shift

  az storage blob upload \
    --account-name "${storageAccountName}" \
    --container-name "${containerName}" \
    --name "${blobName}" \
    --file "${file}" > /dev/null || return $?
}

function az_copy_from_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local blobName="$1"; shift
  local fileName="$1"; shift
  local resourceGroup="$1"; shift

  DEFAULT_RESOURCE_GROUP=""

  connectionString=$(az_get_storage_connection_string "${storageAccountName}" "${resourceGroup:DEFAULT_RESOURCE_GROUP}")

  az storage blob download \
    --connection-string "${connectionString}" \
    --container-name "${containerName}" \
    --name "${blobName}" \
    --file "${fileName}" \
    --no-progress \
    --output none || return $?
}

function az_interact_storage_queue(){
  local storageAccountName="$1"; shift
  local queueName="$1"; shift
  local action="$1"; shift

  connectionString=$(az_get_storage_connection_string "${storageAccountName}")
  az storage queue ${action} --name "${queueName}" --connection-string "${connectionString}"  || return $?
}

# sync is in public preview as of Jan 2020.
function az_sync_with_blob(){
  local storageAccountName="$1"; shift
  local containerName="$1"; shift
  local destinationSuffix="$1"; shift
  if namedef_supported; then
    local -n syncFiles="$1"; shift
  else
    eval "local syncFiles=(\"\${${1}[@]}\")"; shift
  fi

  pushTempDir "${FUNCNAME[0]}_XXXXXX"
  local tmp_dir="$(getTopTempDir)"

  # Copy files locally so we can sync with Blog Storage
  for file in "${syncFiles[@]}" ; do
    if [[ -f "${file}" ]]; then
      case "$(fileExtension "${file}")" in
        zip)
          unzip -DD -q "${file}" -d "${tmp_dir}"
          ;;
        *)
          cp "${file}" "${tmp_dir}"
          ;;
      esac
    fi
  done

  connectionString=$(az_get_storage_connection_string "${storageAccountName}")

  args=(
    "connection-string ${connectionString}"
    "account-name ${storageAccountName}"
    "container ${containerName}"
    "source ${tmp_dir}"
  )

  # -- Only show errors unless debugging --
  if [[ ! $(willLog "${LOG_LEVEL_DEBUG}") ]]; then
    args=("${args[@]}" "only-show-errors" )
  fi

  if [[ -n "${destinationSuffix}" ]]; then
    args=("${args[@]}" "destination ${destinationSuffix}")
  fi

  az storage blob sync ${args[@]/#/--} || return $?
}

function az_delete_blob_dir(){
  local storageAccountName="$1"; shift
  local sourcePath="$1"; shift
  local pattern="$1"; shift

  args=(
    "auth-mode login"
    "account-name ${storageAccountName}"
    "source ${sourcePath}"
  )

  # -- Only show errors unless debugging --
  if [[ ! $(willLog "${LOG_LEVEL_DEBUG}")  ]]; then
    args=("${args[@]}" "only-show-errors" )
  fi

  if [[ -n "${pattern}" ]]; then
    args=("${args[@]}" "pattern ${pattern}")
  fi

  az storage blob delete-batch ${args[@]/#/--} > /dev/null || return $?
}

# -- Keys --
function az_create_pki_credentials() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift
  local keytype="$1"; shift

  if [[ ! -f "${dir}/.azure-${account}-${region}-${keytype}-crt.pem" ]]; then
      openssl genrsa -out "${dir}/.azure-${account}-${region}-${keytype}-prv.pem.plaintext" 2048 || return $?
      openssl rsa -in "${dir}/.azure-${account}-${region}-${keytype}-prv.pem.plaintext" -pubout > "${dir}/.azure-${account}-${region}-${keytype}-crt.pem" || return $?
  fi

  if [[ ! -f "${dir}/.gitignore" ]]; then
    cat << EOF > "${dir}/.gitignore"
*.plaintext
*.decrypted
*.ppk
EOF
  fi

  return 0
}

function az_create_ssh_keypair() {
  local dir="$1"; shift
  local region="$1"; shift
  local account="$1"; shift

  file="${dir}/.azure-${account}-${region}-ssh.plaintext"

  if [[ ! -e "${file}" ]]; then
    ssh-keygen -m PEM -t rsa -b 2048 -f "${file}" -q -N ""
  fi

  if [[ ! -f "${dir}/.gitignore" ]]; then
    cat << EOF > "${dir}/.gitignore"
*.plaintext
*.decrypted
*.ppk
EOF
  fi

}

function az_show_key_credentials() {
  local vaultName="$1"; shift
  local keyName="$1"; shift

  local keyId="https://${vaultName}.azure.net/keys/${keyName}"

  az keyvault key show --id "${keyId}"
}

# -- Secrets --
function az_add_secret() {
  local vaultName="$1"; shift
  local keyName="$1"; shift
  local secret="$1"; shift

  info "Adding secret ${keyName} to vault ${vaultName} ..."
  if [[ -f ${secret} ]]; then
    az keyvault secret set --vault-name "${vaultName}" --name "${keyName}" --file "${secret}" 2>&1 > /dev/null
  else
    az keyvault secret set --vault-name "${vaultName}" --name "${keyName}" --value "${secret}" 2>&1 > /dev/null
  fi
}

function az_check_secret() {
  local vaultName="$1"; shift
  local secretName="$1"; shift

  local secretId="https://${vaultName}.vault.azure.net/secrets/${secretName}"

  az keyvault secret show --id "${secretId}" 2>&1 > /dev/null
}

function az_delete_secret() {
  local vaultName="$1"; shift
  local keyName="$1"; shift

  local keyId="https://${vaultName}.vault.azure.net/keys/${keyName}"

  #azure returns a large object upon successful deletion, so we redirect that.
  az keyvault key show --id "${keyId}" 2>&1 > /dev/null && \
  { az keyvault secret delete --id "${keyId}" > /dev/null || return $?; }

  return 0
}

# -- CDN --

function az_purge_frontdoor_endpoint() {
  local resourceGroup="$1"; shift
  local frontDoorName="$1"; shift

  local paths=("/*")
  [[ -n "$1" ]] && local paths=("$@")

  az network front-door purge-endpoint \
    --resource-group "${resourceGroup}" \
    --name "${frontDoorName}" \
    --content-paths "${paths[@]}"
}

# -- Lambda --

# downloads project files from .zip into a Function App.
# This will restart the app automatically.
# TODO(rossmurr4y): https://github.com/Azure/azure-cli/issues/10773
# remove requirement for subscription param when resolved
function az_functionapp_deploy() {
  local subscription="$1"; shift
  local resourceGroup="$1"; shift
  local function="$1"; shift
  local file="$1"; shift
  local action="$1"; shift

  cat <<EOF
"${action^}"ing FunctionApp:
Subscription:  "${subscription}"
ResourceGroup: "${resourceGroup}"
Function Name: "${function}"
File:          "${file:-"n/a"}"
EOF

  case ${action} in
    delete)
      az functionapp delete \
        --subscription "${subscription}" \
        --resource-group "${resourceGroup}" \
        --name "${function}" \
        --output none || return $?
        ;;
    *)
      az functionapp deployment source config-zip \
        --subscription "${subscription}" \
        --resource-group "${resourceGroup}" \
        --name "${function}" \
        --src "${file}" --verbose --debug || return $?
        ;;
  esac
}
