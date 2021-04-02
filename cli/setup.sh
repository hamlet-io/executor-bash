#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${GENERATION_BASE_DIR}/execution/common.sh"


function update_plugin_state() {
    local state="$1"; shift
    local plugin_id="$1"; shift
    local plugin_type="$1"; shift
    local plugin_ref="$1"; shift
    local plugin_dir="$1"; shift

    plugin_ref="${plugin_type}:${plugin_ref}"
    echo "${state}" | jq -r --arg id "${plugin_id}" --arg type "${plugin_type}" --arg ref "${plugin_ref}" --arg plugin_dir "${plugin_dir}" \
                          '.Plugins[$id] = { type: $type, ref: $ref, plugin_dir: $plugin_dir }'
}

function options() {

  # Parse options
  while getopts ":hi:p:" option; do
      case "${option}" in
          i|p) TEMPLATE_ARGS="${TEMPLATE_ARGS} -${option} ${OPTARG}" ;;
          h) usage; return 1 ;;
          \?) fatalOption; return 1 ;;
      esac
  done

  return 0
}

function usage() {
  cat <<EOF

DESCRIPTION:
  sets up your hamlet tenant ready for output generation

USAGE:
  $(basename $0)

PARAMETERS:

    -h                         shows this text
(o) -i GENERATION_INPUT_SOURCE is the source of input data to use when generating the template - "composite", "mock"
(o) -p GENERATION_PROVIDER     is an addittional provider which is forced to load from a dir in GENERATION_PLUGIN_DIRS


  (m) mandatory, (o) optional, (d) deprecated

DEFAULTS:


NOTES:


EOF
}

function main() {

  options "$@" || return $?

  # Defaults
  LOADER_DIR="${PLUGIN_CACHE_DIR}/_loader"
  GIT_CLONE_DIR="${PLUGIN_CACHE_DIR}/_git"
  PLUGIN_STATE_FILE="${PLUGIN_CACHE_DIR}/plugin-state.json"

  ${GENERATION_DIR}/createTemplate.sh -p "shared" -e loader -y missingPluginAction=ignore -o "${LOADER_DIR}" ${TEMPLATE_ARGS} || return $?

  # check for a plugin contract
  if [[ -f "${LOADER_DIR}/loader-plugincontract.json" &&  -s "${LOADER_DIR}/loader-plugincontract.json" ]]; then

    PLUGIN_CONTRACT="$( cat "${LOADER_DIR}/loader-plugincontract.json" | jq '.' || return $? )"

    # Find all steps for install_plugin
    readarray -t plugin_sources_json <<< "$( echo "${PLUGIN_CONTRACT}" | jq -c -r '.Stages[].Steps[] | select(.Type == "install_plugin" )')"

    if [[ -f "${PLUGIN_STATE_FILE}" ]]; then
      plugin_state="$( cat "${PLUGIN_STATE_FILE}" | jq . )"
    else
      plugin_state='{}'
    fi

    # Add the shared plugin state since that is fixed
    if git -C "${GENERATION_ENGINE_DIR}" rev-parse --is-inside-work-tree &>/dev/null; then
      engine_ref="$(git -C "${GENERATION_ENGINE_DIR}" rev-parse --abbrev-ref HEAD)"
      engine_hash="$(git -C "${GENERATION_ENGINE_DIR}" show-ref --heads --tags --hash "${engine_ref}" )"
      engine_short_hash="$(git -C "${GENERATION_ENGINE_DIR}" rev-parse --short "${engine_hash}" )"

      engine_remote="$( git -C "${GENERATION_ENGINE_DIR}" rev-parse --symbolic-full-name --abbrev-ref @{u} )"
      engine_remote_url="$( git -C "${GENERATION_ENGINE_DIR}" remote get-url "${engine_remote%%"/${engine_ref}"}" )"

      plugin_state="$( update_plugin_state "${plugin_state}" "_engine" "git" "${engine_remote_url}:${engine_short_hash}" "${GENERATION_ENGINE_DIR}" )"

    else
      plugin_state="$( update_plugin_state "${plugin_state}" "_engine" "local" "${GENERATION_ENGINE_DIR}" "${GENERATION_ENGINE_DIR}" )"
    fi

    info "Loading plugins from contract..."

    for plugin_source in "${plugin_sources_json[@]}"; do
      plugin_instance_id="$( echo "${plugin_source}" | jq -c -r '.Id' )"
      plugin_name="$( echo "${plugin_source}" | jq -c -r '.Parameters.Name' )"
      source_type="$( echo "${plugin_source}" | jq -c -r '.Parameters.Source')"

      plugin_instance_dir="${PLUGIN_CACHE_DIR}/${plugin_name}"
      info "[*] id:${plugin_instance_id} - name:${plugin_name}"

      case "${source_type}" in
        git)
          git_url="$( echo "${plugin_source}" | jq -c -r '.Parameters["Source:git"].Url | select (.!=null)' )"
          git_ref="$( echo "${plugin_source}" | jq -c -r '.Parameters["Source:git"].Ref | select (.!=null)' )"
          git_plugin_dir="$( echo "${plugin_source}" | jq -c -r '.Parameters["Source:git"].Path | select (.!=null)' )"

          if [[ -z "${git_url}" && -z "${git_ref}" ]]; then
            error "Git Source missing details  url:${git_url} - ref:${git_ref}"
            continue
          fi

          # repo auth
          git_auth_url="$( find_auth_for_git_url "${git_url}" )"
          git_plugin_clone_dir="$( get_url_component "${git_url}" "host")_$(get_url_component "${git_url}" "path" )_${git_ref}"
          git_plugin_clone_dir="${GIT_CLONE_DIR}/${git_plugin_clone_dir/"/"/""}"

          # Git validation
          git_ref="$( git check-ref-format --allow-onelevel --normalize "${git_ref}" || fatal "Invalid ref ${git_ref}" >&2 ; return $? )"
          remote_ref="$( git ls-remote -q "${git_auth_url}" "${git_ref}" || fatal "Could not find remote plugin - id: ${plugin_instance_id} - Url: ${git_url} - Ref: ${git_ref}"; return $? )"
          remote_hash="$( echo "${remote_ref}" | cut -f 1 )"

          update_existing="false"

          if [[ -d "${git_plugin_clone_dir}" ]]; then
            update_existing="true"

            if [[ "${git_auth_url}" != "$(git -C "${git_plugin_clone_dir}" remote get-url origin)" ]]; then
              rm -rf "${git_plugin_clone_dir}"
              update_existing="false"
            fi
          fi

          if [[ "${update_existing}" == "true" ]]; then
            current_hash="$(git -C "${git_plugin_clone_dir}" show-ref --heads --tags --hash "${git_ref}" )"

            if [[ "${current_hash}" != "${remote_hash}" ]]; then
              git -C "${git_plugin_clone_dir}" pull origin --update-shallow +"${git_ref}":"${git_ref}"
            fi

            git -C "${git_plugin_clone_dir}" checkout -q "${git_ref}"

          else
            git clone --branch "${git_ref}" --depth 1 --single-branch "${git_auth_url}" "${git_plugin_clone_dir}"
          fi

          local_path="${git_plugin_clone_dir}"
          if [[ -n "${git_plugin_dir}" ]]; then
            local_path="${git_plugin_clone_dir}/${git_plugin_dir}"
          fi

          if [[ ! -d "${local_path}" ]]; then
            error "could not find plugin dir ${git_plugin_dir} in plugin repo ${git_url} - skipping plugin state update"
            continue
          fi

          if [[ -L "${plugin_instance_dir}" ]]; then
            ln -sfn "${local_path}" "${plugin_instance_dir}"
          else
            ln -s "${local_path}" "${plugin_instance_dir}"
          fi

          short_hash="$(git -C "${plugin_instance_dir}" rev-parse --short "${remote_hash}" )"
          plugin_state="$( update_plugin_state "${plugin_state}" "${plugin_instance_id}" "${source_type}" "${git_url}:${short_hash}" "${plugin_instance_dir}" )"
          ;;

      esac
    done

    echo "${plugin_state}" > "${PLUGIN_CACHE_DIR}/plugin-state.json"
  fi

  RESULT=$?
  return "${RESULT}"
}

main "$@"
