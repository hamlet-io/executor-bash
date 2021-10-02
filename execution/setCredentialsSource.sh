#!/usr/bin/env bash

# Set up access to cloud providers
# This script is designed to be sourced into other scripts

# CRED_ACCOUNT is the input parameter to this script
# The script must be called with an argument of the CRED_ACCOUNT
CRED_ACCOUNT="${1^^}"

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}

# Make sure we have utilities available
. ${GENERATION_BASE_DIR}/execution/utility.sh

# -- AWS - config helper functions
function set_aws_profile_role_arn {
    local profile_name="${1}"; shift
    local account_id="${1}"; shift
    local role="${1}"; shift

    if [[ -n "${role}" ]]; then
        if [[ "${role}" == arn:*:* ]]; then
            aws configure set "profile.${profile_name}.role_arn" "${role}"
        else
            aws configure set "profile.${profile_name}.role_arn" "arn:aws:iam::${account_id}:role/${role}"
        fi
    fi
}

function set_aws_mfa_token_serial {
    local profile_name="${1}"; shift
    local token_serial="${1}"; shift

    if [[ -n "${token_serial}" ]]; then
        aws configure set "profile.${profile_name}.mfa_serial" "${token_serial}"
    fi
}


case "${ACCOUNT_PROVIDER}" in
    aws)

        # Capture settings that have been set by the user
        # Then we can use them if required
        local_aws_user_profile="${local_aws_user_profile:-${AWS_PROFILE:-"__"}}"
        local_aws_user_config="${local_aws_user_config:-${AWS_CONFIG_FILE:-"__"}}"
        local_aws_user_creds="${local_aws_user_creds:-${AWS_SHARED_CREDENTIALS_FILE:-"__"}}"

        # Overrides for other auth configuration
        if [[ "${AWS_AUTOMATION_USER}" == "ROLE" ]]; then
            HAMLET_AWS_AUTH_SOURCE="INSTANCE"
        fi

        if [[ -n "${AWS_AUTOMATION_USER}" && "${AWS_AUTOMATION_USER}" != "ROLE" ]]; then
            HAMLET_AWS_AUTH_SOURCE="USER"
            HAMLET_AWS_AUTH_USER="${AWS_AUTOMATION_USER}"
        fi

        if [[ -n "${AWS_AUTOMATION_ROLE}" ]]; then
            HAMLET_AWS_AUTH_ROLE="${AWS_AUTOMATION_ROLE}"
        fi

        if [[ ( -f "${HOME}/.aws/config" || -n "${AWS_CONFIG_FILE}" ) && -z "${HAMLET_AWS_AUTH_SOURCE}" ]]; then
            HAMLET_AWS_AUTH_SOURCE="CONFIG"
        fi

        find_env_config "local_aws_auth_source" "HAMLET" "AWS_AUTH_SOURCE" "${CRED_ACCOUNT}"
        local_aws_auth_source="${local_aws_auth_source:-"ENV"}"

        find_env_config "local_aws_account_id" "HAMLET" "AWS_ACCOUNT_ID" "${CRED_ACCOUNT}"
        find_env_config "local_legacy_aws_account_id" "" "AWS_ACCOUNT_ID" "${CRED_ACCOUNT}"

        local_aws_account_id="${local_aws_account_id:-${local_legacy_aws_account_id:-${PROVIDERID}}}"

        if [[ -z "${HAMET_AWS_AUTH_ROLE}" ]]; then
            find_env_config "local_aws_auth_role" "HAMLET" "AWS_AUTH_ROLE" "${CRED_ACCOUNT}"
        fi

        find_env_config "local_aws_auth_mfa_serial" "HAMLET" "AWS_AUTH_MFA_SERIAL" "${CRED_ACCOUNT}"

        hamlet_aws_config="${HAMLET_HOME_DIR}/.aws/config"
        hamlet_aws_credentials="${HAMLET_HOME_DIR}/.aws/credentials"

        # Set the session name for auditing
        export AWS_ROLE_SESSION_NAME="hamlet_${GIT_USER:-"${CRED_ACCOUNT}"}"

        debug "Using AWS auth source: ${local_aws_auth_source} - ${CRED_ACCOUNT} - ${local_aws_account_id}"

        hamlet_aws_profile=""
        profile_name="${local_aws_auth_source,,}:${local_aws_account_id}"

        case "${local_aws_auth_source^^}" in

            "ENV")
                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                hamlet_aws_profile="source:env"

                if [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" ]]; then

                    aws configure set "profile.${hamlet_aws_profile}.aws_access_key_id" "${AWS_ACCESS_KEY_ID}"
                    aws configure set "profile.${hamlet_aws_profile}.aws_secret_access_key" "${AWS_SECRET_ACCESS_KEY}"

                    if [[ -n "${AWS_SESSION_TOKEN}" ]]; then
                        aws configure set "profile.${hamlet_aws_profile}.aws_session_token" "${AWS_SESSION_TOKEN}"
                    fi
                fi

                set_aws_mfa_token_serial "${hamlet_aws_profile}" "${local_aws_auth_mfa_serial}"

                if [[ -n "${local_aws_auth_role}" ]]; then
                    aws configure set "profile.${profile_name}.source_profile" "${hamlet_aws_profile}"
                    set_aws_profile_role_arn "${profile_name}" "${local_aws_account_id}" "${local_aws_auth_role}"
                    set_aws_mfa_token_serial "${profile_name}" "${local_aws_auth_mfa_serial}"

                    hamlet_aws_profile="${profile_name}"
                fi
                ;;

            "USER")
                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                find_env_config "local_aws_auth_user" "HAMLET" "AWS_AUTH_USER" "${CRED_ACCOUNT}"

                hamlet_aws_profile="source:user:${local_aws_auth_user}"

                user_access_key_id_var="${local_aws_auth_user^^}_AWS_ACCESS_KEY_ID"
                user_secret_access_key_var="${local_aws_auth_user^^}_AWS_SECRET_ACCESS_KEY"
                user_session_token_var="${local_aws_auth_user^^}_AWS_SESSION_TOKEN"

                aws configure set "profile.${hamlet_aws_profile}.aws_access_key_id" "${!user_access_key_id_var}"
                aws configure set "profile.${hamlet_aws_profile}.aws_secret_access_key" "${!user_secret_access_key_var}"

                if [[ -n "${!user_session_token_var}" ]]; then
                    aws configure set "profile.${hamlet_aws_profile}.session_token" "${!user_access_key_id_var}"
                fi

                set_aws_mfa_token_serial "${hamlet_aws_profile}" "${local_aws_auth_mfa_serial}"

                if [[ -n "${local_aws_auth_role}" ]]; then
                    aws configure set "profile.${profile_name}.source_profile" "${hamlet_aws_profile}"

                    set_aws_profile_role_arn "${profile_name}" "${local_aws_account_id}" "${local_aws_auth_role}"
                    set_aws_mfa_token_serial "${profile_name}" "${local_aws_auth_mfa_serial}"

                    hamlet_aws_profile="${profile_name}"
                fi
                ;;

            "INSTANCE"|"INSTANCE:EC2"|"INSTANCE:ECS")

                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                if [[ "${local_aws_auth_source^^}" == "INSTANCE" ]]; then

                    ## ECS metadata uri potential endpoints
                    if [[ -n "${ECS_CONTAINER_METADATA_URI_V4}" || -n "${ECS_CONTAINER_METADATA_URI}"
                            || -n "$(curl -m 1 --silent http://169.254.170.2/v2/metadata )" ]]; then

                        aws configure set "profile.${profile_name}.credential_source" "EcsContainer"
                    else
                        # EC2 metadata endpoint
                        metadata_token="$(curl -m 1 --silent -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)"
                        if [[ -n "$( curl -m 1 --silent -H "X-aws-ec2-metadata-token: $metadata_token" -v http://169.254.169.254/latest/meta-data/ 2>/dev/null )" ]]; then

                            aws configure set "profile.${profile_name}.credential_source" "Ec2InstanceMetadata"

                        fi
                    fi

                    if [[ -z "$(aws configure get "profile.${profile_name}.credential_source")" ]]; then
                        fatal "Could not determine an instance credential source to use"
                        fatal "Check that you are running on AWS or explicitly set the Instance type ( INSTANCE:ECS or INSTANCE:EC2)"
                        exit 128
                    fi

                # Explicit overrides instead of discovery
                elif [[ "${local_aws_auth_source^^}" == "INSTANCE:ECS" ]]; then
                    aws configure set "profile.${profile_name}.credential_source" "EcsContainer"

                elif [[ "${local_aws_auth_source^^}" == "INSTANCE:EC2" ]]; then
                    aws configure set "profile.${profile_name}.credential_source" "Ec2InstanceMetadata"
                fi

                if [[ -n "${local_aws_auth_role}" ]]; then
                    set_aws_profile_role_arn "${profile_name}" "${local_aws_account_id}" "${local_aws_auth_role}"
                fi

                hamlet_aws_profile="${profile_name}"
                ;;

            "CONFIG")

                if [[ "${local_aws_user_config}" != "__" ]]; then
                    export AWS_CONFIG_FILE="${local_aws_user_config}"
                fi

                if [[ "${local_aws_user_creds}" != "__" ]]; then
                    export AWS_SHARED_CREDENTIALS_FILE="${local_aws_user_creds}"
                fi

                if [[ -n "${local_aws_account_id}" ]]; then
                    aws configure list --profile "${local_aws_account_id}" > /dev/null 2>&1
                    if [[ $? -eq 0 ]]; then
                        hamlet_aws_profile="${local_aws_account_id}"
                    fi
                else
                    if [[ -n "${CRED_ACCOUNT}" ]]; then
                        aws configure list --profile "${CRED_ACCOUNT}" > /dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            hamlet_aws_profile="${CRED_ACCOUNT}"
                        fi
                    fi
                fi

                if [[ -z "${hamlet_aws_profile}" ]]; then
                    warn "Could not find a profile in local aws config"
                    warn "Excepted one of these profiles:"
                    warn "  - ${local_aws_account_id}"
                    warn "  - ${CRED_ACCOUNT}"
                    warn "using default profile or AWS_PROFILE if set"

                    if [[ "${local_aws_user_profile}" != "__" ]]; then
                        hamlet_aws_profile="${local_aws_user_profile}"
                    fi
                fi
                ;;

            "NONE")
                unset AWS_CONFIG_FILE
                unset AWS_SHARED_CREDENTIALS_FILE
                warn "Skipping login to AWS this won't allow you to access AWS but will continue"
                ;;

            *)
                fatal "Invalid HAMLET_AWS_AUTH_SOURCE - ${local_aws_auth_source}"
                fatal "Possible sources are - ENV | USER | INSTANCE | CONFIG | NONE"
                exit 128
                ;;
        esac

        # Unset to allow for default handling and will be reset as required
        unset AWS_PROFILE

        if [[ -n "${hamlet_aws_profile}"  ]]; then
            export AWS_PROFILE="${hamlet_aws_profile}"

            if [[ -n "${AUTOMATION_PROVIDER}" ]]; then
                save_context_property AWS_PROFILE "${hamlet_aws_profile}"
            fi

            # workaround for https://github.com/aws/aws-cli/issues/3304
            unset AWS_ACCESS_KEY_ID
            unset AWS_SECRET_ACCESS_KEY
            unset AWS_SESSION_TOKEN

            if [[ -n "${AUTOMATION_PROVIDER}" ]]; then
                save_context_property AWS_ACCESS_KEY_ID ""
                save_context_property AWS_SECRET_ACCESS_KEY ""
                save_context_property AWS_SESSION_TOKEN ""
            fi
        fi

        if [[ -n "${AWS_CONFIG_FILE}" ]]; then
            if [[ -n "${AUTOMATION_PROVIDER}" ]]; then
                save_context_property AWS_CONFIG_FILE "${AWS_CONFIG_FILE}"
            fi
        fi

        if [[ -n "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
            if [[ -n "${AUTOMATION_PROVIDER}" ]]; then
                save_context_property AWS_SHARED_CREDENTIALS_FILE "${AWS_SHARED_CREDENTIALS_FILE}"
            fi
        fi

        if [[ "${local_aws_auth_source}" != "NONE" ]]; then
            profile_account="$(aws sts get-caller-identity --query 'Account' --output text || exit $?)"
            if [[ -n "${local_aws_account_id}" ]]; then
                if [[ "${profile_account}" != "${local_aws_account_id}" ]]; then
                    fatal "The provided credentials don't provide access to the account requested"
                    fatal "  - Hamlet Account Id: ${CRED_ACCOUNT}"
                    fatal "  - AWS Account Id: ${local_aws_account_id}"
                    fatal "  - HAMLET_AWS_AUTH_SOURCE: ${local_aws_auth_source}"
                    fatal "  - HAMLET_AWS_AUTH_ROLE: ${local_aws_auth_role}"
                    fatal "Check your aws credentials configuration and try again"
                    fatal "Make sure to set HAMLET_AWS_AUTH_ROLE if you need to switch role to access the account"
                    exit 128
                fi
            fi
        fi
        ;;

    azure)

        az_login_args=()
        # -- Only show errors unless debugging --
        if willLog "${LOG_LEVEL_DEBUG}"; then
            az_login_args+=("--output" "json" )
        else
            az_login_args+=("--output" "none" )
        fi

        find_env_config "local_az_auth_method" "HAMLET" "AZ_AUTH_METHOD" "${CRED_ACCOUNT}"
        find_env_config "local_legacy_az_auth_method" "" "AZ_AUTOMATION_AUTH_METHOD" "${CRED_ACCOUNT}"

        local_az_auth_method="${local_az_auth_method:-${local_legacy_az_auth_method:-"INTERACTIVE"}}"

        find_env_config "local_az_account_id" "HAMLET" "AZ_ACCOUNT_ID" "${CRED_ACCOUNT}"
        find_env_config "local_legacy_az_accound_id" "" "AZ_ACCOUNT_ID" "${CRED_ACCOUNT}"

        local_az_account_id="${local_az_account_id:-${local_legacy_az_accound_id:-${PROVIDERID}}}"


        find_env_config "local_az_tenant_id" "HAMLET" "AZ_TENANT_ID" "${CRED_ACCOUNT}"
        find_env_config "local_legacy_az_tentant_id" "" "AZ_TENANT_ID" "${CRED_ACCOUNT}"

        local_az_tenant_id="${local_az_tenant_id:-${local_legacy_az_tentant_id}}"

        if [[ -n "${local_az_tenant_id}" ]]; then
            az_login_args+=("--tenant" "${local_az_tenant_id}")
        fi

        debug "Using Azure auth method: ${local_az_auth_method} - ${CRED_ACCOUNT} - ${local_az_account_id}"
        case "${local_az_auth_method^^}" in
            SERVICE)

                find_env_config "local_az_username" "HAMLET" "AZ_USERNAME" "${CRED_ACCOUNT}"
                find_env_config "local_legacy_az_username" "" "AZ_USERNAME" "${CRED_ACCOUNT}"

                local_az_username="${local_az_username:-${local_legacy_az_username}}"

                find_env_config "local_az_pass" "HAMLET" "AZ_PASS" "${CRED_ACCOUNT}"
                find_env_config "local_legacy_az_pass" "" "AZ_PASS" "${CRED_ACCOUNT}"

                local_az_pass="${local_az_pass:-${local_legacy_az_pass}}"

                if [[ (-z "${local_az_username}") || ( -z "${local_az_pass}") || ( -z "${local_az_tenant_id}") ]]; then
                    fatal "Azure Service prinicpal login missing information - requires environment - HAMLET_AZ_USERNAME | HAMLET_AZ_PASS | HAMLET_AZ_TENANT_ID"
                    exit 255
                fi

                az login --service-principal --username "${local_az_username}" --password "${local_az_pass}" ${az_login_args[@]}
                ;;

            MANAGED)
                az login --identity "${az_login_args[@]}"
                ;;

            INTERACTIVE)
                if [[ -n "$(az account list --query '[*].id' --output tsv 2> /dev/null )" ]]; then
                    username="$( az account list --query '[0].user.name' --output tsv)"

                    info "Already logged in as ${username:-"unkown"}"
                    info "   - To use a different user run az logout"
                else
                    az login "${az_login_args[@]}"
                fi
                ;;

            NONE)
                warn "Skipping Login to Azure this won't allow you to access Azure"
                ;;

            *)
                fatal "Invalid HAMLET_AZ_AUTH_METHOD - ${local_az_auth_method}"
                fatal "Possible methods are - SERVICE | MANAGED | INTERACTIVE | NONE"
                exit 128
                ;;
        esac

        if [[ "${local_az_auth_method^^}" != "NONE" ]]; then
            # Set the current subscription to use
            az account set --subscription "${local_az_account_id}" "${az_login_args[@]}" > /dev/null || { fatal "Could not login to subscription ${CRED_ACCOUNT} ${local_az_auth_method}"; exit 128; }
        fi

        ;;
    *)
        fatal "Unkown account provider ${ACCOUNT_PROVIDER}"
        exit 128
        ;;
esac
