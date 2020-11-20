#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${GENERATION_BASE_DIR}/execution/common.sh"


function update_provider_state() {
    local state="$1"; shift
    local provider_id="$1"; shift
    local provider_type="$1"; shift
    local provider_ref="$1"; shift
    local plugin_dir="$1"; shift

    provider_ref="${provider_type}:${provider_ref}"
    echo "${state}" | jq -r --arg id "${provider_id}" --arg type "${provider_type}" --arg ref "${provider_ref}" --arg plugin_dir "${plugin_dir}" \
                          '.Providers[$id] = { type: $type, ref: $ref, plugin_dir: $plugin_dir }'
}

function options() {

  # Parse options
  while getopts ":hi:" option; do
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
  LOADER_DIR="${PROVIDER_CACHE_DIR}/_loader"
  ${GENERATION_DIR}/createTemplate.sh -p "shared" -e loader -o "${LOADER_DIR}" ${TEMPLATE_ARGS} || return $?

  # check for a provider contract
  if [[ -f "${LOADER_DIR}/loader-providercontract.json" &&  -s "${LOADER_DIR}/loader-providercontract.json" ]]; then

    PROVIDER_CONTRACT="$( cat "${LOADER_DIR}/loader-providercontract.json" | jq '.' || return $? )"

    # Find all steps for install_provider
    readarray -t provider_sources_json <<< "$( echo "${PROVIDER_CONTRACT}" | jq -c -r '.Stages[].Steps[] | select(.Type == "install_provider" )')"

    provider_state='{}'

    # Add the shared provider state since that is fixed
    if git -C "${GENERATION_ENGINE_DIR}" rev-parse --is-inside-work-tree &>/dev/null; then
      engine_ref="$(git -C "${GENERATION_ENGINE_DIR}" rev-parse --abbrev-ref HEAD)"
      engine_hash="$(git -C "${GENERATION_ENGINE_DIR}" show-ref --heads --tags --hash "${engine_ref}" )"
      engine_short_hash="$(git -C "${GENERATION_ENGINE_DIR}" rev-parse --short "${engine_hash}" )"

      engine_remote="$( git -C "${GENERATION_ENGINE_DIR}" rev-parse --symbolic-full-name --abbrev-ref @{u} )"
      engine_remote_url="$( git -C "${GENERATION_ENGINE_DIR}" remote get-url "${engine_remote%%"/${engine_ref}"}" )"

      provider_state="$( update_provider_state "${provider_state}" "_engine" "git" "${engine_short_hash}:${engine_remote_url}" "${GENERATION_ENGINE_DIR}" )"

    else
      provider_state="$( update_provider_state "${provider_state}" "_engine" "local" "${GENERATION_ENGINE_DIR}" "${GENERATION_ENGINE_DIR}" )"
    fi

    info "Loading providers from contract..."

    for provider_source in "${provider_sources_json[@]}"; do
      provider_instance_id="$( echo "${provider_source}" | jq -c -r '.Id' )"
      provider_name="$( echo "${provider_source}" | jq -c -r '.Parameters.ProviderName' )"
      source_type="$( echo "${provider_source}" | jq -c -r '.Parameters.Source')"
      priority="$( echo "${provider_source}" | jq -c -r '.Parameters.Priority')"=

      provider_instance_dir="${PROVIDER_CACHE_DIR}/${provider_instance_id}"

      info "[*] id:${provider_instance_id} - type:${source_type}"

      # handle source type changes for a given id
      existing_source="false"
      existing_source_type="unkown"

      if [[ -d "${provider_instance_dir}" ]]; then
        existing_source="true"

        if [[ "${existing_source_type}" == "unkown" && -L "${provider_instance_dir}" ]]; then
          existing_source_type="local"
        fi

        if [[ "${existing_source_type}" == "unkown" ]]; then
          if git -C "${provider_instance_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
            existing_source_type="git"
          fi
        fi

        if [[ "${source_type}" != "${existing_source_type}" ]]; then
          rm -rf "${provider_instance_dir}"
        fi
      fi

      case "${source_type}" in
        git)
          git_url="$( echo "${provider_source}" | jq -c -r '.Parameters.git.Url | select (.!=null)' )"
          git_ref="$( echo "${provider_source}" | jq -c -r '.Parameters.git.Ref | select (.!=null)' )"
          git_plugin_dir="$( echo "${provider_source}" | jq -c -r '.Parameters.git.Directory | select (.!=null)' )"

          if [[ -z "${git_url}" && -z "${git_ref}" ]]; then
            error "Git Source missing details  url:${git_url} - ref:${git_ref}"
            continue
          fi

          # repo auth
          git_auth_url="$( find_auth_for_git_url "${git_url}" )"

          # Git validation
          git_ref="$( git check-ref-format --allow-onelevel --normalize "${git_ref}" || fatal "Invalid ref ${git_ref}" >&2 ; return $? )"
          remote_ref="$( git ls-remote -q "${git_auth_url}" "${git_ref}" || fatal "Could not find remote provider - id: ${provider_instance_id} - Url: ${git_url} - Ref: ${git_ref}"; return $? )"
          remote_hash="$( echo "${remote_ref}" | cut -f 1 )"

          update_existing="false"

          if [[ "${existing_source}" == "true" && "${existing_source_type}" == "git" ]]; then
            update_existing="true"

            if [[ "${git_auth_url}" != "$(git -C "${provider_instance_dir}" remote get-url origin)" ]]; then
              rm -rf "${provider_instance_dir}"
              update_existing="false"
            fi
          fi

          if [[ "${update_existing}" == "true" ]]; then
            current_hash="$(git -C "${provider_instance_dir}" show-ref --heads --tags --hash "${git_ref}" )"

            if [[ "${current_hash}" != "${remote_hash}" ]]; then
              git -C "${provider_instance_dir}" pull origin --update-shallow +"${git_ref}":"${git_ref}"
            fi

            git -C "${provider_instance_dir}" checkout -q "${git_ref}"

          else
            git clone --branch "${git_ref}" --depth 1 --single-branch "${git_auth_url}" "${provider_instance_dir}"
          fi

          if [[ -n "${git_plugin_dir}" ]]; then
            provider_instance_dir="${provider_instance_dir}/${git_plugin_dir}"
          fi

          short_hash="$(git -C "${provider_instance_dir}" rev-parse --short "${remote_hash}" )"
          provider_state="$( update_provider_state "${provider_state}" "${provider_instance_id}" "${source_type}" "${short_hash}:${git_url}" "${provider_instance_dir}" )"
          ;;

        local)
          local_path="$( echo "${provider_source}" | jq -c -r '.Parameters.local.Path | select (.!=null)' )"

          if [[ -z "${local_path}" ]]; then
            error "Local Source missing details  path:${local_path}"
            continue
          fi

          if [[ -d "${local_path}" ]]; then
            if [[ "${existing_source}" == "true" && "${existing_source_type}" == "local" ]]; then
              ln -sfn "${local_path}" "${provider_instance_dir}"
            else
              ln -s "${local_path}" "${provider_instance_dir}"
            fi

            provider_state="$( update_provider_state "${provider_state}" "${provider_instance_id}" "${source_type}" "${local_path}" "${provider_instance_dir}" )"
          else
            warning "[!] id:${provider_instance_id} - type:${source_type} - not found - skipped"
            rm -rf "${provider_instance_dir}"
          fi
          ;;

      esac
    done

    echo "${provider_state}" > "${PROVIDER_CACHE_DIR}/provider-state.json"
  fi

  RESULT=$?
  return "${RESULT}"
}

main "$@"
