#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${GENERATION_BASE_DIR}/execution/common.sh"

# Defaults

function usage() {
    cat <<EOF

Generate a document using the Freemarker template engine

Usage: $(basename $0) -t TEMPLATE (-d TEMPLATEDIR)+ -o OUTPUT (-v VARIABLE=VALUE)* (-g CMDB=PATH)* -b CMDB (-c CMDB)* -l LOGLEVEL

where

(o) -b CMDB           base cmdb
(o) -c CMDB           cmdb to be included
(m) -d TEMPLATEDIR    is a directory containing templates
(o) -g CMDB=PATH      defines a cmdb and the corresponding path
(o) -g PATH           finds all cmdbs under PATH based on a .cmdb marker file or directory
    -h                shows this text
(o) -l LOGLEVEL       required log level
(m) -o OUTPUT         is the path of the resulting document
(o) -r VARIABLE=VALUE defines a variable and corresponding value to be made available in the template
(m) -t TEMPLATE       is the filename of the Freemarker template to use
(o) -v VARIABLE=VALUE defines a variable and corresponding value to be made available in the template

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

NOTES:

1. If the value of a variable defines a path to an existing file, the contents of the file are provided to the engine
2. Values that do not correspond to existing files are provided as is to the engine
3. Values containing spaces need to be quoted to ensure they are passed in as a single argument
4. -r and -v are equivalent except that -r will not check if the provided value
   is a valid filename
5. For a cmdb located via a .cmdb marker file or directory, cmdb name = the containing directory name

EOF
    exit
}

TEMPLATEDIRS=()
RAW_VARIABLES=()
VARIABLES=()
CMDBS=()
CMDB_MAPPINGS=()

# Parse options
while getopts ":b:c:d:g:hl:o:r:t:v:" opt; do
    case $opt in
        b)
            BASE_CMDB="${OPTARG}"
            ;;
        c)
            CMDBS+=("${OPTARG}")
            ;;
        d)
            TEMPLATEDIRS+=("${OPTARG}")
            ;;
        g)
            CMDB_MAPPINGS+=("${OPTARG}")
            ;;
        h)
            usage
            ;;
        l)
            LOGLEVEL="${OPTARG}"
            ;;
        o)
            OUTPUT="${OPTARG}"
            ;;
        r)
            RAW_VARIABLES+=("${OPTARG}")
            ;;
        t)
            TEMPLATE="${OPTARG}"
            ;;
        v)
            VARIABLES+=("${OPTARG}")
            ;;
        \?)
            fatalOption
            ;;
        :)
            fatalOptionArgument
            ;;
    esac
done

# Defaults


# Ensure mandatory arguments have been provided
exit_on_invalid_environment_variables "TEMPLATE" "OUTPUT"
[[ ("${#TEMPLATEDIRS[@]}" -eq 0) ]] && fatalMandatory "TEMPLATEDIRS" && exit 1

if [[ "${#TEMPLATEDIRS[@]}" -gt 0 ]]; then
  TEMPLATEDIRS=("-d" "${TEMPLATEDIRS[@]}")
fi

if [[ "${#VARIABLES[@]}" -gt 0 ]]; then
  VARIABLES=("-v" "${VARIABLES[@]}")
fi

if [[ "${#RAW_VARIABLES[@]}" -gt 0 ]]; then
  RAW_VARIABLES=("-r" "${RAW_VARIABLES[@]}")
fi

if [[ "${#CMDBS[@]}" -gt 0 ]]; then
  CMDBS=("-c" "${CMDBS[@]}")
fi

if [[ "${#CMDB_MAPPINGS[@]}" -gt 0 ]]; then
  CMDB_MAPPINGS=("-g" "${CMDB_MAPPINGS[@]}")
fi

# Migration to a bundled version of the freemarker-wrapper
# The bundled version removes the need to have a local java installation and ensures compatability
# Defaulting to the current state but will eventually move away from it
GENERATION_WRAPPER_LOCAL_JAVA="${GENERATION_WRAPPER_LOCAL_JAVA:-"true"}"

if [[ "${GENERATION_WRAPPER_LOCAL_JAVA,,}" == "true" ]]; then
    if [[ ! -f "${GENERATION_WRAPPER_JAR_FILE}" ]]; then
        fatal "Could not find engine core jar file - GENERATION_WRAPPER_JAR_FILE: ${GENERATION_WRAPPER_JAR_FILE}"
        exit 128
    fi
    GENERATION_WRAPPER_COMMAND="java -jar ${GENERATION_WRAPPER_JAR_FILE}"
else
    if [[ ! -f "${GENERATION_WRAPPER_SCRIPT_FILE}" ]]; then
        fatal "Could not find engine core script file - GENERATION_WRAPPER_SCRIPT_FILE: ${GENERATION_WRAPPER_SCRIPT_FILE}"
        exit 128
    fi
    GENERATION_WRAPPER_COMMAND="${GENERATION_WRAPPER_SCRIPT_FILE}"
fi

${GENERATION_WRAPPER_COMMAND} \
    -i $TEMPLATE "${TEMPLATEDIRS[@]}" \
    -o $OUTPUT \
    "${VARIABLES[@]}" \
    "${RAW_VARIABLES[@]}" \
    "${CMDB_MAPPINGS[@]}" \
    ${BASE_CMDB:+-b "${BASE_CMDB}"} \
    ${LOGLEVEL:+--${LOGLEVEL}} \
    "${CMDBS[@]}"
RESULT=$?
