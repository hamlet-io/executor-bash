#!/usr/bin/env bash

[[ -n "${AUTOMATION_DEBUG}" ]] && set ${AUTOMATION_DEBUG}
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM
. "${AUTOMATION_BASE_DIR}/common.sh"

REFERENCE_MASTER="master"

# Defaults
PRODUCT_CONFIG_REFERENCE_DEFAULT="${REFERENCE_MASTER}"
PRODUCT_INFRASTRUCTURE_REFERENCE_DEFAULT="${REFERENCE_MASTER}"
ACCOUNT_CONFIG_REFERENCE_DEFAULT="${REFERENCE_MASTER}"
ACCOUNT_INFRASTRUCTURE_REFERENCE_DEFAULT="${REFERENCE_MASTER}"

function usage() {
    cat <<EOF

Construct the account directory tree

Usage: $(basename $0)

where

(o) -a                                      if the account directories should not be included
(o) -c PRODUCT_CONFIG_REFERENCE             is the git reference for the config repo
(o) -e USE_EXISTING_TREE                    use an existing CMDB tree
    -h                                      shows this text
(o) -i PRODUCT_INFRASTRUCTURE_REFERENCE     is the git reference for the config repo
(o) -r                                      if the product directories should not be included
(o) -x ACCOUNT_CONFIG_REFERENCE             is the git ref for the acccount config repo
(o) -y ACCOUNT_INFRASTRUCTURE_REFERENCE     is the git ref for the acccount infrastructure repo
(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

PRODUCT_CONFIG_REFERENCE = ${PRODUCT_CONFIG_REFERENCE_DEFAULT}
PRODUCT_INFRASTRUCTURE_REFERENCE = ${PRODUCT_INFRASTRUCTURE_REFERENCE_DEFAULT}
ACCOUNT_CONFIG_REFERENCE = ${ACCOUNT_CONFIG_REFERENCE_DEFAULT}
ACCOUNT_INFRASTRUCTURE_REFERENCE = ${ACCOUNT_INFRASTRUCTURE_REFERENCE_DEFAULT}

NOTES:

1. ACCOUNT/PRODUCT details are assumed to be already defined via environment variables

EOF
    exit
}

# Parse options
while getopts ":ac:ehi:rx:" opt; do
    case $opt in
        a)
            EXCLUDE_ACCOUNT_DIRECTORIES="true"
            ;;
        c)
            PRODUCT_CONFIG_REFERENCE="${OPTARG}"
            ;;
        e)
            USE_EXISTING_TREE="true"
            ;;
        h)
            usage
            ;;
        i)
            PRODUCT_INFRASTRUCTURE_REFERENCE="${OPTARG}"
            ;;
        r)
            EXCLUDE_PRODUCT_DIRECTORIES="true"
            ;;
        x)
            ACCOUNT_CONFIG_REFERENCE="${OPTARG}"
            ;;
        y)
            ACCOUNT_INFRASTRUCTURE_REFERENCE="${OPTARG}"
            ;;
        \?)
            fatalOption
            ;;
        :)
            fatalOptionArgument
            ;;
     esac
done

# Apply defaults
PRODUCT_CONFIG_REFERENCE="${PRODUCT_CONFIG_REFERENCE:-$PRODUCT_CONFIG_REFERENCE_DEFAULT}"
PRODUCT_INFRASTRUCTURE_REFERENCE="${PRODUCT_INFRASTRUCTURE_REFERENCE:-$PRODUCT_INFRASTRUCTURE_REFERENCE_DEFAULT}"
ACCOUNT_CONFIG_REFERENCE="${ACCOUNT_CONFIG_REFERENCE:-$ACCOUNT_CONFIG_REFERENCE_DEFAULT}"
ACCOUNT_INFRASTRUCTURE_REFERENCE="${ACCOUNT_INFRASTRUCTURE_REFERENCE:-$ACCOUNT_INFRASTRUCTURE_REFERENCE_DEFAULT}"
EXCLUDE_ACCOUNT_DIRECTORIES="${EXCLUDE_ACCOUNT_DIRECTORIES:-false}"
EXCLUDE_PRODUCT_DIRECTORIES="${EXCLUDE_PRODUCT_DIRECTORIES:-false}"
USE_EXISTING_TREE="${USE_EXISTING_TREE:-false}"

# Check for required context
[[ -z "${ACCOUNT}" ]] && fatal "ACCOUNT not defined" && exit

if [[ "${USE_EXISTING_TREE}" == "false" ]]; then

    # Save for later steps
    save_context_property PRODUCT_CONFIG_REFERENCE "${PRODUCT_CONFIG_REFERENCE}"
    save_context_property PRODUCT_INFRASTRUCTURE_REFERENCE "${PRODUCT_INFRASTRUCTURE_REFERENCE}"
    save_context_property ACCOUNT_CONFIG_REFERENCE "${ACCOUNT_CONFIG_REFERENCE}"
    save_context_property ACCOUNT_INFRASTRUCTURE_REFERENCE "${ACCOUNT_INFRASTRUCTURE_REFERENCE}"

    # Record what is happening
    info "Creating the context directory tree"

    # Define the top level directory representing the account
    BASE_DIR="${AUTOMATION_DATA_DIR}/${ACCOUNT}"
    mkdir -p "${BASE_DIR}"
    touch ${BASE_DIR}/root.json

    # Pull repos into a temporary directory so the contents can be examined
    BASE_DIR_TEMP="${BASE_DIR}/temp"

    if [[ !("${EXCLUDE_PRODUCT_DIRECTORIES}" == "true") ]]; then

        # Multiple products in the product config repo
        MULTI_PRODUCT_REPO=false

        # Pull in the product config repo
        ${AUTOMATION_DIR}/manageRepo.sh -c -l "product config" \
            -n "${PRODUCT_CONFIG_REPO}" -v "${PRODUCT_GIT_PROVIDER}" \
            -d "${BASE_DIR_TEMP}" -b "${PRODUCT_CONFIG_REFERENCE}"
        RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

        # Ensure temporary files are ignored
        [[ (! -f "${BASE_DIR_TEMP}/.gitignore") || ($(grep -q "temp_\*" "${BASE_DIR_TEMP}/.gitignore") -ne 0) ]] && \
        echo "temp_*" >> "${BASE_DIR_TEMP}/.gitignore"

        # The config repo may contain
        # - config +/- infrastructure
        # - product(s) +/- account(s)
        if [[ -n $(findDir "${BASE_DIR_TEMP}" "infrastructure") ]]; then
            # Mix of infrastructure and config
            ACCOUNT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${ACCOUNT}")"
            # Ensure we definitely have an account
            if [[ ( -n "${ACCOUNT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/account.json" ) ||
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/config/account.json" )
                    ) ]]; then
                # Everything in one repo
                PRODUCT_CONFIG_DIR="${BASE_DIR}/cmdb"
            else
                PRODUCT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${PRODUCT}")"
                # Ensure we definitely have a product
                if [[ ( -n "${PRODUCT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${PRODUCT_CANDIDATE_DIR}/product.json" ) ||
                        ( -d "${PRODUCT_CANDIDATE_DIR}/config/product.json" )
                    ) ]]; then
                    # Multi-product repo
                    PRODUCT_CONFIG_DIR="${BASE_DIR}/products"
                    MULTI_PRODUCT_REPO=true
                else
                    # Single product repo
                    PRODUCT_CONFIG_DIR="${BASE_DIR}/${PRODUCT}"
                fi
            fi
        else
            # Just config
            ACCOUNT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${ACCOUNT}")"
            # Ensure we definitely have an account
            if [[ ( -n "${ACCOUNT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/account.json" ) ||
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/config/account.json" )
                    ) ]]; then
                # products and accounts
                PRODUCT_CONFIG_DIR="${BASE_DIR}/config"
            else
                PRODUCT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${PRODUCT}")"
                # Ensure we definitely have a product
                if [[ ( -n "${PRODUCT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${PRODUCT_CANDIDATE_DIR}/product.json" ) ||
                        ( -d "${PRODUCT_CANDIDATE_DIR}/config/product.json" )
                    ) ]]; then
                    # Multi-product repo
                    PRODUCT_CONFIG_DIR="${BASE_DIR}/config/products"
                    MULTI_PRODUCT_REPO=true
                else
                    # Single product repo
                    PRODUCT_CONFIG_DIR="${BASE_DIR}/config/${PRODUCT}"
                fi
            fi
        fi

        mkdir -p $(filePath "${PRODUCT_CONFIG_DIR}")
        mv "${BASE_DIR_TEMP}" "${PRODUCT_CONFIG_DIR}"
        save_context_property PRODUCT_CONFIG_COMMIT "$(git -C "${PRODUCT_CONFIG_DIR}" rev-parse HEAD)"

        PRODUCT_INFRASTRUCTURE_DIR=$(findGen3ProductInfrastructureDir "${BASE_DIR}" "${PRODUCT}")
        if [[ -z "${PRODUCT_INFRASTRUCTURE_DIR}" ]]; then
            # Pull in the infrastructure repo
            ${AUTOMATION_DIR}/manageRepo.sh -c -l "product infrastructure" \
                -n "${PRODUCT_INFRASTRUCTURE_REPO}" -v "${PRODUCT_GIT_PROVIDER}" \
                -d "${BASE_DIR_TEMP}" -b "${PRODUCT_INFRASTRUCTURE_REFERENCE}"
            RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

            # Ensure temporary files are ignored
            [[ (! -f "${BASE_DIR_TEMP}/.gitignore") || ($(grep -q "temp_\*" "${BASE_DIR_TEMP}/.gitignore") -ne 0) ]] && \
            echo "temp_*" >> "${BASE_DIR_TEMP}/.gitignore"

            ACCOUNT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${ACCOUNT}")"
            # Ensure we definitely have an account
            if [[ ( -n "${ACCOUNT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/account.json" ) ||
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/config/account.json" )
                    ) ]]; then
                # products and accounts
                PRODUCT_INFRASTRUCTURE_DIR="${BASE_DIR}/infrastructure"
            else
                # Is product repo contains multiple products, assume the infrastructure repo does too
                if [[ "${MULTI_PRODUCT_REPO}" == "true" ]]; then
                    # Multi-product repo
                    PRODUCT_INFRASTRUCTURE_DIR="${BASE_DIR}/infrastructure/products"
                else
                    # Single product repo
                    PRODUCT_INFRASTRUCTURE_DIR="${BASE_DIR}/infrastructure/${PRODUCT}"
                fi
            fi
            mkdir -p $(filePath "${PRODUCT_INFRASTRUCTURE_DIR}")
            mv "${BASE_DIR_TEMP}" "${PRODUCT_INFRASTRUCTURE_DIR}"
        fi

        save_context_property PRODUCT_INFRASTRUCTURE_COMMIT "$(git -C "${PRODUCT_INFRASTRUCTURE_DIR}" rev-parse HEAD)"
    fi

    if [[ !("${EXCLUDE_ACCOUNT_DIRECTORIES}" == "true") ]]; then

        # Multiple accounts in the account config repo
        MULTI_ACCOUNT_REPO=false

        # Pull in the account config repo
        ACCOUNT_CONFIG_DIR=$(findGen3AccountDir "${BASE_DIR}" "${ACCOUNT}")
        if [[ -z "${ACCOUNT_CONFIG_DIR}" ]]; then
            ${AUTOMATION_DIR}/manageRepo.sh -c -l "account config" \
                -n "${ACCOUNT_CONFIG_REPO}" -v "${ACCOUNT_GIT_PROVIDER}" \
                -d "${BASE_DIR_TEMP}" -b "${ACCOUNT_CONFIG_REFERENCE}"
            RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

            # Ensure temporary files are ignored
            [[ (! -f "${BASE_DIR_TEMP}/.gitignore") || ($(grep -q "temp_\*" "${BASE_DIR_TEMP}/.gitignore") -ne 0) ]] && \
            echo "temp_*" >> "${BASE_DIR_TEMP}/.gitignore"

            if [[ -n $(findDir "${BASE_DIR_TEMP}" "infrastructure") ]]; then
                # Mix of infrastructure and config
                ACCOUNT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${ACCOUNT}")"
                # Ensure we definitely have an account
                if [[ ( -n "${ACCOUNT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/account.json" ) ||
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/config/account.json" )
                    ) ]]; then
                    # Multi-account repo
                    ACCOUNT_CONFIG_DIR="${BASE_DIR}/accounts"
                    MULTI_ACCOUNT_REPO=true
                else
                    # Single account repo
                    ACCOUNT_CONFIG_DIR="${BASE_DIR}/${ACCOUNT}"
                fi
            else
                ACCOUNT_CANDIDATE_DIR="$(findDir "${BASE_DIR_TEMP}" "${ACCOUNT}")"
                # Ensure we definitely have an account
                if [[ ( -n "${ACCOUNT_CANDIDATE_DIR}" ) &&
                    (
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/account.json" ) ||
                        ( -d "${ACCOUNT_CANDIDATE_DIR}/config/account.json" )
                    ) ]]; then
                    # Multi-account repo
                    ACCOUNT_CONFIG_DIR="${BASE_DIR}/config/accounts"
                    MULTI_ACCOUNT_REPO=true
                else
                    # Single account repo
                    ACCOUNT_CONFIG_DIR="${BASE_DIR}/config/${ACCOUNT}"
                fi
            fi
            mkdir -p $(filePath "${ACCOUNT_CONFIG_DIR}")
            mv "${BASE_DIR_TEMP}" "${ACCOUNT_CONFIG_DIR}"
            save_context_property ACCOUNT_CONFIG_COMMIT "$(git -C "${ACCOUNT_CONFIG_DIR}" rev-parse HEAD)"
        fi

        ACCOUNT_INFRASTRUCTURE_DIR=$(findGen3AccountInfrastructureDir "${BASE_DIR}" "${ACCOUNT}")
        if [[ -z "${ACCOUNT_INFRASTRUCTURE_DIR}" ]]; then
            # Pull in the account infrastructure repo
            ${AUTOMATION_DIR}/manageRepo.sh -c -l "account infrastructure" \
                -n "${ACCOUNT_INFRASTRUCTURE_REPO}" -v "${ACCOUNT_GIT_PROVIDER}" \
                -d "${BASE_DIR_TEMP}" -b "${ACCOUNT_INFRASTRUCTURE_REFERENCE}"
            RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

            # Ensure temporary files are ignored
            [[ (! -f "${BASE_DIR_TEMP}/.gitignore") || ($(grep -q "temp_\*" "${BASE_DIR_TEMP}/.gitignore") -ne 0) ]] && \
            echo "temp_*" >> "${BASE_DIR_TEMP}/.gitignore"

            # Is account repo contains multiple accounts, assume the infrastructure repo does too
            if [[ "${MULTI_ACCOUNT_REPO}" == "true" ]]; then
                # Multi-account repo
                ACCOUNT_INFRASTRUCTURE_DIR="${BASE_DIR}/infrastructure/accounts"
            else
                # Single account repo
                ACCOUNT_INFRASTRUCTURE_DIR="${BASE_DIR}/infrastructure/${ACCOUNT}"
            fi
            mkdir -p $(filePath "${ACCOUNT_INFRASTRUCTURE_DIR}")
            mv "${BASE_DIR_TEMP}" "${ACCOUNT_INFRASTRUCTURE_DIR}"
        fi

    # TODO(mfl): 03/02/2020 Remove the following code once its confirmed its redundant
    # From the Jenkins logs it throws errors when TENANT is non-empty which makes sense
    # as BASE_DIR_TEMP has been cleared by processing of the ACCOUNT. However sometimes
    # it doesn't which suggests that it either is blank or contains a directory with an
    # infrastructure subdirectory.
    # Either way, without a temp dir to move, it seems unnecessary.
    #    TENANT_INFRASTRUCTURE_DIR=$(findGen3TenantInfrastructureDir "${BASE_DIR}" "${TENANT}")
    #    if [[ -z "${TENANT_INFRASTRUCTURE_DIR}" ]]; then
    #
    #        TENANT_INFRASTRUCTURE_DIR="${BASE_DIR}/${TENANT}"
    #        mkdir -p $(filePath "${TENANT_INFRASTRUCTURE_DIR}")
    #        mv "${BASE_DIR_TEMP}" "${TENANT_INFRASTRUCTURE_DIR}"
    #    fi

    fi
fi

if [[ "${USE_EXISTING_TREE}" == "true" ]]; then
    if [[ -z "${ROOT_DIR}" || ! (-d "${ROOT_DIR}") ]]; then
        fatal "ROOT_DIR: ${ROOT_DIR} - could not be found for existing tree"
        exit
    fi
    BASE_DIR="${ROOT_DIR}"
fi

# Examine the structure and define key directories

findGen3Dirs "${BASE_DIR}"
RESULT=$? && [[ ${RESULT} -ne 0 ]] && exit

# A couple of the older upgrades need GENERATION_DATA_DIR set to
# locate the AWS account number to account id mappings
export GENERATION_DATA_DIR="${BASE_DIR}"

# Remember directories for future steps
save_gen3_dirs_in_context
