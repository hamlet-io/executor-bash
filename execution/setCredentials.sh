#!/usr/bin/env bash

# Set up access to cloud providers
# This script is designed to be sourced into other scripts

# $1 = account to be accessed
# this is used to hanlde sourcing or invoking of this script
(return 0 2>/dev/null) && CRED_ACCOUNT="${ACCOUNT}" || CRED_ACCOUNT="${1^^}"

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}

# -- AWS - config helper functions
function set_aws_profile_role_arn {
    account_id="${1}"; shift
    role="${1}"; shift

    if [[ -n "${role}" ]]; then
        if [[ "${role}" == arn:*:* ]]; then
            aws configure set "profile.${account_id}.role_arn" "${role}"
        else
            aws configure set "profile.${account_id}.role_arn" "arn:aws:iam::${account_id}:role/${role}"
        fi
    fi
}

function set_aws_mfa_token_serial {
    account_id="${1}"; shift
    token_serial="${1}"; shift

    if [[ -n "${token_serial}" ]]; then
        aws configure set "profile.${account_id}.mfa_serial" "${token_serial}"
    fi
}


case "${ACCOUNT_PROVIDER}" in
    aws)

        # Overrides for other auth sources
        if [[ "${AWS_AUTOMATION_USER}" == "ROLE" ]]; then
            HAMLET_AWS_AUTH_SOURCE="INSTANCE"
        fi

        if [[ -n "${AWS_AUTOMATION_USER}" && "${AWS_AUTOMATION_USER}" != "ROLE" ]]; then
            HAMLET_AWS_AUTH_SOURCE="USER"
            HAMLET_AWS_AUTH_USER="${AWS_AUTOMATION_USER}"
        fi

        if [[ -n "${PROVIDERID}" ]]; then
            HAMLET_AWS_ACCOUNT_ID="${PROVIDERID}"
        fi

        if [[ -n "${AWS_AUTOMATION_ROLE}" ]]; then
            HAMLET_AWS_AUTH_ROLE="${AWS_AUTOMATION_ROLE}"
        fi

        if [[ ( -f "${HOME}/.aws/config" || -n "${AWS_CONFIG_FILE}" ) && -z "${HAMLET_AWS_AUTH_SOURCE}" ]]; then
            HAMLET_AWS_AUTH_SOURCE="CONFIG"
        fi

        ## Allow the older methods to set the source and then use default
        if [[ -z "${HAMLET_AWS_AUTH_SOURCE}" ]]; then
            find_env_config "HAMLET" "AWS_AUTH_SOURCE" "${CRED_ACCOUNT}"
            HAMLET_AWS_AUTH_SOURCE="${HAMLET_AWS_AUTH_SOURCE:-"ENV"}"
        fi

        if [[ -z "${HAMLET_AWS_ACCOUNT_ID}" ]]; then
            find_env_config "HAMLET" "AWS_ACCOUNT_ID" "${CRED_ACCOUNT}"
        fi

        if [[ -z "${HAMET_AWS_AUTH_ROLE}" ]]; then
            find_env_config "HAMLET" "AWS_AUTH_ROLE" "${CRED_ACCOUNT}"
        fi

        find_env_config "HAMLET" "AWS_AUTH_MFA_SERIAL" "${CRED_ACCOUNT}"

        hamlet_aws_config="${HAMLET_HOME_DIR}/.aws/config"
        hamlet_aws_credentials="${HAMLET_HOME_DIR}/.aws/credentials"

        # Set the session name for auditing
        export AWS_ROLE_SESSION_NAME="hamlet_${GIT_USER:-"${CRED_ACCOUNT}"}"

        info "using AWS auth source: ${HAMLET_AWS_AUTH_SOURCE}"

        hamlet_aws_profile=""
        profile_name="${HAMLET_AWS_AUTH_SOURCE,,}:${HAMLET_AWS_ACCOUNT_ID}"

        case "${HAMLET_AWS_AUTH_SOURCE^^}" in

            "ENV")
                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                aws configure set "profile.source:env.aws_access_key_id" "${AWS_ACCESS_KEY_ID}"
                aws configure set "profile.source:env.aws_secret_access_key" "${AWS_SECRET_ACCESS_KEY}"

                if [[ -n "${AWS_SESSION_TOKEN}" ]]; then
                    aws configure set "profile.source:env.aws_session_token" "${AWS_SESSION_TOKEN}"
                fi

                aws configure set "profile.${profile_name}.source_profile" "source:env"
                set_aws_profile_role_arn "${profile_name}" "${HAMLET_AWS_AUTH_ROLE}"
                set_aws_mfa_token_serial "${profile_name}" "${HAMLET_AWS_AUTH_MFA_SERIAL}"

                hamlet_aws_profile="${profile_name}"
                ;;

            "USER")
                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                find_env_config "HAMLET" "AWS_AUTH_USER" "${CRED_ACCOUNT}"

                user_access_key_id_var="${HAMLET_AWS_AUTH_USER^^}_AWS_ACCESS_KEY_ID"
                user_secret_access_key_var="${HAMLET_AWS_AUTH_USER^^}_AWS_SECRET_ACCESS_KEY"
                user_session_token_var="${HAMLET_AWS_AUTH_USER^^}_AWS_SESSION_TOKEN"

                aws configure set "profile.source:user:${HAMLET_AWS_AUTH_USER}.aws_access_key_id" "${!user_access_key_id_var}"
                aws configure set "profile.source:user:${HAMLET_AWS_AUTH_USER}.aws_secret_access_key" "${!user_secret_access_key_var}"

                if [[ -n "${!user_session_token_var}" ]]; then
                    aws configure set "profile.source:user:${HAMLET_AWS_AUTH_USER}.session_token" "${!user_access_key_id_var}"
                fi

                aws configure set "profile.${profile_name}.source_profile" "source:user:${HAMLET_AWS_AUTH_USER}"

                set_aws_profile_role_arn "${profile_name}" "${HAMLET_AWS_AUTH_ROLE}"
                set_aws_mfa_token_serial "${profile_name}" "${HAMLET_AWS_AUTH_MFA_SERIAL}"

                hamlet_aws_profile="${profile_name}"
                ;;

            "INSTANCE"|"INSTANCE:EC2"|"INSTANCE:ECS")

                export AWS_CONFIG_FILE="${hamlet_aws_config}"
                export AWS_SHARED_CREDENTIALS_FILE="${hamlet_aws_credentials}"

                if [[ "${HAMLET_AWS_AUTH_SOURCE^^}" == "INSTANCE" ]]; then

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
                elif [[ "${HAMLET_AWS_AUTH_SOURCE^^}" == "INSTANCE:ECS" ]]; then
                    aws configure set "profile.${profile_name}.credential_source" "EcsContainer"

                elif [[ "${HAMLET_AWS_AUTH_SOURCE^^}" == "INSTANCE:EC2" ]]; then
                    aws configure set "profile.${profile_name}.credential_source" "Ec2InstanceMetadata"
                fi

                set_aws_profile_role_arn "${profile_name}" "${HAMLET_AWS_AUTH_ROLE}"
                hamlet_aws_profile="${profile_name}"
                ;;

            "CONFIG")

                if [[ -n "${HAMLET_AWS_ACCOUNT_ID}" ]]; then
                    aws configure list --profile "${HAMLET_AWS_ACCOUNT_ID}" > /dev/null 2>&1
                    if [[ $? -eq 0 ]]; then
                        hamlet_aws_profile="${HAMLET_AWS_ACCOUNT_ID}"
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
                    warn "  - ${HAMLET_AWS_ACCOUNT_ID}"
                    warn "  - ${CRED_ACCOUNT}"
                    warn "using default profile or AWS_PROFILE if set"
                fi
                ;;

            *)
                fatal "Invalid HAMLET_AWS_AUTH_SOURCE - ${HAMLET_AWS_AUTH_SOURCE}"
                fatal "Possible sources are - ENV | USER | INSTANCE | CONFIG"
                exit 128
                ;;
        esac

        if [[ -n "${hamlet_aws_profile}" ]]; then
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

        # Validate that the determined configuration will provide access to the account
        profile_account="$(aws sts get-caller-identity --query 'Account' --output text)"
        if [[ -n "${HAMLET_AWS_ACCOUNT_ID}" ]]; then
            if [[ "${profile_account}" != "${HAMLET_AWS_ACCOUNT_ID}" ]]; then
                fatal "The provided credentials don't provide access to the account requested - ${CRED_ACCOUNT} ${HAMLET_AWS_ACCOUNT_ID}"
                fatal "Check your aws credentials configuration  and try again"
                exit 128
            fi
        fi
        ;;

    azure)

        az_login_args=()

        # -- Only show output unless debugging --
        if willLog "${LOG_LEVEL_DEBUG}"  ]]; then
            az_login_args+=("--output" "json" )
        else
            az_login_args+=("--output" "none" )
        fi

        # find the method - default to prompt based login
        AZ_AUTOMATION_AUTH_METHOD_VAR="${CRED_ACCOUNT}_AZ_AUTH_METHOD"
        if [[ -z "${!AZ_AUTOMATION_AUTH_METHOD_VAR}" ]]; then AZ_AUTOMATION_AUTH_METHOD_VAR="AZ_AUTH_METHOD"; fi
        AZ_AUTH_METHOD="${!AZ_AUTOMATION_AUTH_METHOD_VAR:-interactive}"

        # lookup the AZ Account
        AZ_ACCOUNT_ID_VAR="${CRED_ACCOUNT}_AZ_ACCOUNT_ID"
        if [[ -n "${!AZ_ACCOUNT_ID_VAR}" ]]; then
            AZ_ACCOUNT_ID="${!AZ_ACCOUNT_ID_VAR}"
        fi

        # Set the tenant if required - By defeault it uses the Tenant Id
        AZ_ACCOUNT_TENANT_OVERRIDE_VAR="${CRED_ACCOUNT}_AZ_TENANT_ID"
        if [[ -n "${!AZ_ACCOUNT_TENANT_OVERRIDE_VAR}" ]]; then
            AZ_TENANT_ID="${!AZ_ACCOUNT_TENANT_OVERRIDE_VAR}"
        fi

        if [[ -n "${AZ_TENANT_ID}" ]]; then
            az_login_args+=("--tenant" "${AZ_TENANT_ID}")
        fi

        case "${AZ_AUTH_METHOD}" in
            service)

                #Account specific creds
                AZ_CRED_OVERRIDE_USERNAME_VAR="${CRED_ACCOUNT}_AZ_USERNAME"
                AZ_CRED_OVERRIDE_PASS_VAR="${CRED_ACCOUNT}_AZ_PASS"

                if [[ ( -n "${!AZ_CRED_OVERRIDE_USERNAME_VAR}") ]]; then
                    AZ_CRED_USERNAME="${!AZ_CRED_OVERRIDE_USERNAME_VAR}"
                    AZ_CRED_PASS="${!AZ_CRED_OVERRIDE_PASS_VAR}"
                else
                    # Tenant wide credentials
                    AZ_CRED_AUTOMATION_USERNAME_VAR="AZ_USERNAME"
                    AZ_CRED_AUTOTMATION_PASS_VAR="AZ_PASS"
                    if [[ -n "${!AZ_CRED_AUTOMATION_USERNAME_VAR}" ]]; then
                        AZ_CRED_USERNAME="${!AZ_CRED_AUTOMATION_USERNAME_VAR}"
                        AZ_CRED_PASS="${!AZ_CRED_AUTOTMATION_PASS_VAR}"
                    fi
                fi

                if [[ (-z "${AZ_CRED_USERNAME}") || ( -z "${AZ_CRED_PASS}") || ( -z "${AZ_TENANT_ID}") ]]; then
                    fatal "Azure Service prinicpal login missing information - requires environment - AZ_USERNAME | AZ_PASS | AZ_TENANT_ID"
                    exit 255
                fi

                az login --service-principal --username "${AZ_CRED_USERNAME}" --password "${AZ_CRED_PASS}" ${az_login_args[@]}
                ;;

            managed)
                az login --identity "${az_login_args[@]}"
                ;;

            interactive)
                az login "${az_login_args[@]}"
                ;;

            none)
                info "Skipping Login to Azure - AZ_AUTH_METHOD = ${AZ_AUTH_METHOD}"
                ;;
        esac
        ;;
esac
