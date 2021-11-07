#!/usr/bin/env bash

[[ -n "${GENERATION_DEBUG}" ]] && set ${GENERATION_DEBUG}
trap '. ${GENERATION_BASE_DIR}/execution/cleanupContext.sh' EXIT SIGHUP SIGINT SIGTERM
. "${GENERATION_BASE_DIR}/execution/common.sh"

# Defaults
STACK_OPERATION_DEFAULT="update"
STACK_WAIT_DEFAULT=15
QUIET_MODE_DEFAULT="false"

function usage() {
  cat <<EOF

Manage a CloudFormation stack

Usage: $(basename $0) -l LEVEL -u DEPLOYMENT_UNIT -i -m -w STACK_WAIT -r REGION -n STACK_NAME -y -d

where

(o) -d (STACK_OPERATION=delete) to delete the stack
    -h                          shows this text
(m) -l LEVEL                    is the stack level - "account", "product", "segment", "solution", "application" or "multiple"
(o) -n STACK_NAME               to override standard stack naming
(o) -o OUTPUT_DIR               is an override for the deployment output directory
(o) -q (QUIET_MODE=true)        minimise output generated
(o) -r REGION                   is the AWS region identifier for the region in which the stack should be managed
(m) -u DEPLOYMENT_UNIT          is the deployment unit used to determine the stack template
(o) -w STACK_WAIT               is the interval between checking the progress of the stack operation
(o) -y (DRYRUN=(Dryrun))        for a dryrun - show what will happen without actually updating the stack
(o) -z DEPLOYMENT_UNIT_SUBSET  is the subset of the deployment unit required

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

STACK_OPERATION = ${STACK_OPERATION_DEFAULT}
STACK_WAIT      = ${STACK_WAIT_DEFAULT} seconds
QUIET_MODE      = ${QUIET_MODE_DEFAULT}

NOTES:
1. You must be in the correct directory corresponding to the requested stack level
2. REGION is only relevant for the "product" level, where multiple product stacks are necessary
   if the product uses resources in multiple regions
3. "segment" is now used in preference to "container" to avoid confusion with docker
4. If stack doesn't exist in AWS, the update operation will create the stack
5. Overriding the stack name is not recommended except where legacy naming has to be maintained
6. A dryrun creates a change set, then provides the expected changes

EOF
}

function options() {
  # Parse options
  while getopts ":dhil:mn:o:qr:t:u:w:yz:" option; do
    case "${option}" in
      d) STACK_OPERATION=delete ;;
      h) usage; return 1 ;;
      l) LEVEL="${OPTARG}" ;;
      n) STACK_NAME="${OPTARG}" ;;
      o) OUTPUT_DIR="${OPTARG}" ;;
      q) QUIET_MODE=true ;;
      r) REGION="${OPTARG}" ;;
      u) DEPLOYMENT_UNIT="${OPTARG}" ;;
      w) STACK_WAIT="${OPTARG}" ;;
      y) DRYRUN="(Dryrun) " ;;
      z) DEPLOYMENT_UNIT_SUBSET="${OPTARG}" ;;
      \?) fatalOption; return 1 ;;
      :) fatalOptionArgument; return 1  ;;
    esac
  done

  # Apply defaults
  STACK_OPERATION=${STACK_OPERATION:-${STACK_OPERATION_DEFAULT}}
  STACK_WAIT=${STACK_WAIT:-${STACK_WAIT_DEFAULT}}
  QUIET_MODE=${QUIET_MODE:-${QUIET_MODE_DEFAULT}}

  # Set up the context
  info "${DRYRUN}Preparing the context..."
  . "${GENERATION_BASE_DIR}/execution/setStackContext.sh"
  . "${GENERATION_BASE_DIR}/execution/setCredentials.sh"

  return 0
}

function submit_change_set {
  local region="$1"; shift
  local change_set_name="$1"; shift
  local stack_name="$1"; shift
  local stack_operation="$1"; shift
  local template_file="$1"; shift

  aws --region "${region}" cloudformation create-change-set \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" \
      --client-token "${change_set_name}" \
      --template-body "file://${template_file}" \
      --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM --change-set-type "${stack_operation^^}" > /dev/null || return $?

  #Wait for change set to be processed
  aws --region "${region}" cloudformation wait change-set-create-complete \
      --stack-name "${stack_name}" --change-set-name "${change_set_name}" &>/dev/null
}

function get_stack_status_details {
  local stack_name="$1"; shift
  local stack_state="$1"; shift
  local client_token="$1"; shift

  info "Stack Details"

  info " - Status: $( echo "${stack_state}" | jq -r '.Stacks[0].StackStatus | select (.!=null)')"
  info " - Status Reason: $( echo "${stack_state}" | jq -r '.Stacks[0].StackStatusReason | select (.!=null)')"

  if [[ -n "${client_token}" ]]; then
    stack_events="$(aws --region "${REGION}" cloudformation describe-stack-events \
      --stack-name "${stack_name}" \
      --query "StackEvents[?ClientRequestToken == '${client_token}'].{ResourceId:LogicalResourceId,ResourceType:ResourceType,Status:ResourceStatus,Reason:ResourceStatusReason}" \
      --output json || return $?)"
    if [[ -n "${stack_events}" ]]; then
      info " - Stack Events:"
      echo "${stack_events}" | jq '.'
    fi
  fi
}

function wait_for_stack_execution() {
  local client_token="${1}"; shift
  local stack_op="${1}"; shift
  local change_set_state="${1}"; shift

  local stack_status_file="${tmp_dir}/stack_status"
  local stack_state=""

  monitor_header="0"

  while true; do

    stack_state="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" --max-items 1 2> /dev/null)"
    exit_status=$?

    if [[ ("${stack_op}" == "delete") &&
          ( -z "$(aws --region "${REGION}" cloudformation list-stacks --query "StackSummaries[?StackName == '${STACK_NAME}' && StackStatus != 'DELETE_COMPLETE'].StackStatus" --output text )" ) ]]; then
      echo ""
      info "Delete completed for ${STACK_NAME}"
      exit_status=0
      break
    fi

    if [[ "${monitor_header}" == "0" ]]; then
      echo -n " Status: "
      monitor_header="1"
    fi

    # Check the latest status
    stack_status="$( echo "${stack_state}" | jq -r '.Stacks[0].StackStatus')"

    case "${stack_status}" in
      *ROLLBACK*)
        echo -n "<ROLLBACK"
        ;;
      *DELETE*)
        echo -n "-"
        ;;
      *)
        echo -n ">"
        ;;
    esac

    # Watch for roll backs
    if [[ "${stack_status}" == *ROLLBACK_COMPLETE ]]; then
      echo ""
      warning "Stack ${STACK_NAME} could not complete and a rollback was performed"
      get_stack_status_details "${STACK_NAME}" "${stack_state}" "${client_token}"
      [[ -n "${stack_state}" ]] && echo "${stack_state}" > "${STACK}"
      exit_status=1
      break
    fi

    # Watch for failures
    if [[ "${stack_status}" == *FAILED ]]; then
      echo ""
      fatal "Stack ${STACK_NAME} failed, fix stack before retrying"
      get_stack_status_details "${STACK_NAME}" "${stack_state}" "${client_token}"
      exit_status=255
      break
    fi

    if [[ "${stack_status}" == "DELETE_COMPLETE" ]]; then
      echo ""
      info "Stack ${STACK_NAME} delete completed with status ${stack_status}"
      break
    fi

    # Update State and break if the stack operation was completed
    if [[ "${stack_status}" =~ ^(CREATE|UPDATE)_COMPLETE$ ]]; then
      echo ""
      info "Stack ${STACK_NAME} completed with status ${stack_status}"
      [[ -n "${change_set_state}" ]] && echo "${change_set_state}" > "${CHANGE}"
      [[ -n "${stack_state}" ]] && echo "${stack_state}" > "${STACK}"
      break
    fi

    # Abort if not still in progress
    if [[ ! "${stack_status}" == *_IN_PROGRESS ]]; then
      echo ""
      info "Stack ${STACK_NAME} in an unexpected state with status ${stack_status}"
      get_stack_status_details "${STACK_NAME}" "${stack_state}" "${client_token}"
      break
    fi

    # All good, wait a while longer
    sleep ${STACK_WAIT}

    # Check to see if the work has already been completed
    case ${exit_status} in
      0) ;;
      *)
        return ${exit_status}
        ;;
    esac

  done
}

function process_stack() {

  local stripped_primary_template_file="${tmp_dir}/stripped_primary_template"
  local change_set_id="$(date +'%s')"

  local exit_status=0

  echo ""
  info "Running stack operation for ${STACK_NAME}"

  case ${STACK_OPERATION} in
    delete)
      [[ -n "${DRYRUN}" ]] && \
        fatal "Dryrun not applicable when deleting a stack" && return 1

      info "Deleting the "${STACK_NAME}" stack"
      DELETE_CLIENT_TOKEN="delete-${change_set_id}"

      aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" \
          --client-request-token "${DELETE_CLIENT_TOKEN}" 2>/dev/null

      # For delete, we don't check result as stack may not exist
      wait_for_stack_execution "${DELETE_CLIENT_TOKEN}" "${STACK_OPERATION}" || return $?
      ;;

    update|create)
      # Compress the template to minimise the impact of aws cli size limitations
      jq -c '.' < ${TEMPLATE} > "${stripped_primary_template_file}"

      existing_stack_status="$(aws --region "${REGION}" cloudformation list-stacks --query "StackSummaries[?StackName == '${STACK_NAME}' && StackStatus != 'DELETE_COMPLETE'].StackStatus" --output text || return $? )"

      # Handle stack which has rolled back on creation and hasn't been removed
      if [[ "${existing_stack_status}" =~ ^.*ROLLBACK_COMPLETE$ || "${existing_stack_status}" =~ ^.*ROLLBACK_FAILED$ ]]; then
        if [[ -z "$(aws --region "${REGION}" cloudformation list-stack-resources --stack-name "${STACK_NAME}" --query "StackResourceSummaries[?ResourceStatus != 'DELETE_COMPLETE' && ResourceStatus != 'DELETE_SKIPPED'].LogicalResourceId" --output text || return $?)" ]]; then

          CLEANUP_CLIENT_TOKEN="cleanup-${change_set_id}"

          info "Cleaning up failed create"
          aws --region "${REGION}" cloudformation delete-stack --stack-name "${STACK_NAME}" \
              --client-request-token "${CLEANUP_CLIENT_TOKEN}" 2>/dev/null

          wait_for_stack_execution "${CLEANUP_CLIENT_TOKEN}" "delete" || { exit_status=$?; break; }
          existing_stack_status="$(aws --region "${REGION}" cloudformation list-stacks --query "StackSummaries[?StackName == '${STACK_NAME}' && StackStatus != 'DELETE_COMPLETE'].StackStatus" --output text || return $? )"
        fi
      fi

      # Handle stacks that are already running so we don't fail in subsequent operations
      if [[ "${existing_stack_status}" == *"_IN_PROGRESS" ]]; then
        warning "Stack ${STACK_NAME} is currently running an operation. Will watch the state and continue once completed"
        wait_for_stack_execution "" "${STACK_OPERATION}" || { exit_status=$?; break; }
      fi

      # Check if stack needs to be created
      # List state returns stacks that have been deleted as well
      if [[ -z "${existing_stack_status}"
            || "${existing_stack_status}" == "REVIEW_IN_PROGRESS"
            || "${existing_stack_status}" == "DELETE_COMPLETE" ]]; then

        STACK_OPERATION="create"
      fi

      PRIMARY_CHANGE_SET="$(fileBase "${TEMPLATE}")-${change_set_id}"

      # This will return a non zero exit code if there is no change to the change set - so we want to ignore the exit status here
      submit_change_set "${REGION}" "${PRIMARY_CHANGE_SET}" "${STACK_NAME}" "${STACK_OPERATION}" "${stripped_primary_template_file}"

      change_set_state="$(aws --region "${REGION}" cloudformation describe-change-set \
            --stack-name "${STACK_NAME}" --change-set-name "${PRIMARY_CHANGE_SET}" || return $?)"

      if [[ -n "${DRYRUN}" ]]; then

        if [[ "${QUIET_MODE}" == "true" ]]; then
          echo "${change_set_state}" > "${PLANNED_CHANGE}"
        else
          info "${DRYRUN}Results for ${STACK_NAME}"
          echo "${change_set_state}" | jq '.'
        fi
        return 0

      else

        if [[ "$( echo "${change_set_state}" | jq -r '.Status')" == "FAILED" ]]; then
          if [[ "$( echo "${change_set_state}" | jq -r '.StatusReason')" == \
                "The submitted information didn't contain changes. Submit different information to create a change set." ]]; then

            # Refresh the state to make sure everything is up to date
            wait_for_stack_execution "" "${STACK_OPERATON}"> /dev/null

            info "No updates needed for existing stack ${STACK_NAME}"
            return 0
          else
            echo "An unexpected failure occurred in change set"
            echo "${change_set_state}" | jq .
            return 128
          fi

        else

          replacement="$( echo "${change_set_state}" | jq -r '[.Changes[].ResourceChange.Replacement] | contains(["True"])' )"
          REPLACE_TEMPLATES=$( for i in ${ALTERNATIVE_TEMPLATES} ; do echo $i | awk '/-replace[0-9]-template\.json$/'; done  | sort  )

          if [[ "${replacement}" == "true" && -n "${REPLACE_TEMPLATES}" ]]; then

              info "Replacement operation required"

              for REPLACE_TEMPLATE in ${REPLACE_TEMPLATES}; do
                info " - replace template : $(fileBase "${REPLACE_TEMPLATE}")"

                local stripped_replace_template_file="${tmp_dir}/stripped_replace_template"
                jq -c '.' < ${REPLACE_TEMPLATE} > "${stripped_replace_template_file}"

                REPLACE_CHANGE_SET="$( fileBase "${REPLACE_TEMPLATE}")-${change_set_id}"
                submit_change_set "${REGION}" "${REPLACE_CHANGE_SET}" "${STACK_NAME}" "${STACK_OPERATION}" "${stripped_replace_template_file}"

                # Check ChangeSet for results
                change_set_state="$(aws --region "${REGION}" cloudformation describe-change-set \
                    --stack-name "${STACK_NAME}" --change-set-name "${REPLACE_CHANGE_SET}" || exit_status=$?)"

                if [[ "$( echo "${change_set_state}" | jq -r '.Status')" == "FAILED" ]]; then

                  echo "${change_set_state}" | jq -r '.StatusReason' | grep -q "The submitted information didn't contain changes."; no_change=$?
                  if [[ ${no_change} == 0 ]]; then
                    info "No updates needed for replacement stack ${STACK_NAME}. Treating as successful"
                    break
                  else
                    fatal "An unexpected failure occurrend creating the change set"
                    echo "${change_set_state}" | jq '.'
                    return ${exit_status}
                  fi
                else
                  # Running
                  aws --region "${REGION}" cloudformation execute-change-set \
                      --stack-name "${STACK_NAME}" --change-set-name "${REPLACE_CHANGE_SET}" \
                      --client-request-token "${REPLACE_CHANGE_SET}" > /dev/null || return $?

                  wait_for_stack_execution "${REPLACE_CHANGE_SET}" "${STACK_OPERATION}" "${change_set_state}" || { exit_status=$?; break; }
                fi
              done

              # catch loop failures
              [[ "${exit_status}" -ne 0 ]] && { fatal "An issue occurred during replace template processing"; return "${exit_status}"; }

          else
            # Execute the primary template change
            aws --region "${REGION}" cloudformation execute-change-set \
                  --stack-name "${STACK_NAME}" --change-set-name "${PRIMARY_CHANGE_SET}" \
                  --client-request-token "${PRIMARY_CHANGE_SET}" > /dev/null || return $?

            wait_for_stack_execution "${PRIMARY_CHANGE_SET}" "${STACK_OPERATION}" "${change_set_state}" || return $?

          fi
        fi
      fi
      ;;

    *)
      fatal "\"${STACK_OPERATION}\" is not one of the known stack operations"
      return 1
      ;;
  esac

  # Clean up the stack if required
  if [[ "${STACK_OPERATION}" == "delete" ]]; then
    for i in ${PSEUDO_STACK_WILDCARD}; do
      rm "${i}"
    done

    if [[ -f "${STACK}" ]]; then
      rm "${STACK}"
    fi
    if [[ -f "${CHANGE}" ]]; then
      rm "${CHANGE}"
    fi
  fi

  return "${exit_status}"
}

function main() {

  options "$@" || return $?

  pushTempDir "manage_stack_XXXXXX"
  tmp_dir="$(getTopTempDir)"
  tmpdir="${tmp_dir}"

  pushd ${CF_DIR} > /dev/null 2>&1

  # Run the prologue script if present
  if [[ -s "${PROLOGUE}" ]]; then
    echo ""
    info "${DRYRUN}Processing prologue script"
    if [[ -z "${DRYRUN}" ]]; then
      . "${PROLOGUE}" || return $?
    fi
  fi

  process_stack_status=0
  # Process the stack
  if [[ -f "${TEMPLATE}" ]]; then
     process_stack || return $?
  fi

  # Run the epilogue script if present
  # by the epilogue script
  if [[ -s "${EPILOGUE}" ]]; then
    echo ""
    info "${DRYRUN}Processing epilogue script"
    if [[ -z "${DRYRUN}" ]]; then
      . "${EPILOGUE}" || return $?
    fi
  fi

  return 0
}

main "$@"
