#!/usr/bin/env bash

# Set up credentials to interact with cloud providers when running engine processes

# Set default AWS credentials if available (hook from Jenkins framework)
CHECK_AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-${ACCOUNT_TEMP_AWS_ACCESS_KEY_ID}}"
CHECK_AWS_ACCESS_KEY_ID="${CHECK_AWS_ACCESS_KEY_ID:-${!ACCOUNT_AWS_ACCESS_KEY_ID_VAR}}"
if [[ -n "${CHECK_AWS_ACCESS_KEY_ID}" ]]; then export AWS_ACCESS_KEY_ID="${CHECK_AWS_ACCESS_KEY_ID}"; fi

CHECK_AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-${ACCOUNT_TEMP_AWS_SECRET_ACCESS_KEY}}"
CHECK_AWS_SECRET_ACCESS_KEY="${CHECK_AWS_SECRET_ACCESS_KEY:-${!ACCOUNT_AWS_SECRET_ACCESS_KEY_VAR}}"
if [[ -n "${CHECK_AWS_SECRET_ACCESS_KEY}" ]]; then export AWS_SECRET_ACCESS_KEY="${CHECK_AWS_SECRET_ACCESS_KEY}"; fi

CHECK_AWS_SESSION_TOKEN="${AWS_SESSION_TOKEN:-${ACCOUNT_TEMP_AWS_SESSION_TOKEN}}"
if [[ -n "${CHECK_AWS_SESSION_TOKEN}" ]]; then export AWS_SESSION_TOKEN="${CHECK_AWS_SESSION_TOKEN}"; fi

# Set the profile for IAM access if AWS credentials not in the environment
# We would normally redirect to /dev/null but this triggers an "unknown encoding"
# bug in python
if [[ ((-z "${AWS_ACCESS_KEY_ID}") || (-z "${AWS_SECRET_ACCESS_KEY}")) ]]; then
    if [[ -n "${ACCOUNT}" ]]; then
        aws configure list --profile "${ACCOUNT}" > $(getTempFile "account_profile_status_XXXXXX.txt") 2>&1
        if [[ $? -eq 0 ]]; then
            export AWS_DEFAULT_PROFILE="${ACCOUNT}"
        fi
    fi
    if [[ -n "${AID}" ]]; then
        aws configure list --profile "${AID}" > $(getTempFile "id_profile_status_XXXXXX.txt") 2>&1
        if [[ $? -eq 0 ]]; then
            export AWS_DEFAULT_PROFILE="${AID}"
        fi
    fi
    if [[ $ACCOUNT_PROVIDER == 'aws' ]]; then
        aws configure list --profile "${PROVIDERID}" > $(getTempFile "awsid_profile_status_XXXXXX.txt") 2>&1
        if [[ $? -eq 0 ]]; then
            export AWS_DEFAULT_PROFILE="${PROVIDERID}"
        fi
    fi
fi

# Set the Azure subscription and login if we haven't already
if [[ "${ACCOUNT_PROVIDER}" == "azure" ]]; then
    if [[ "${AZ_AUTH_METHOD}" == "none" ]]; then
        info "Skipping azure authentication - AZ_AUTH_METHOD=${AZ_AUTH_METHOD}"
    else
        if [[ -z "$(az account list --output tsv)" ]]; then
            info "Logging in to Azure..."
            . ${AUTOMATION_DIR}/setCredentials.sh "${ACCOUNT}"

        fi

        if [[ "${AZ_AUTH_METHOD}" != "none" ]]; then
            az_cli_args=()
            # -- Only show errors unless debugging --
            if willLog "${LOG_LEVEL_DEBUG}"; then
                az_cli_args+=("--output" "json" )
            else
                az_cli_args+=("--output" "none" )
            fi

            az account set --subscription "${PROVIDERID}" "${az_cli_args[@]}"
        fi
    fi
fi
