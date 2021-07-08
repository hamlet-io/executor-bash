#!/usr/bin/env bash

# A Wrapper for setCredentialsSource.sh for generation based commands
# sources the account argument required by setCredentials through the ACCOUNT var

# Backwards compatbility with existing usage of setCredentials in the cli commands
. ${GENERATION_BASE_DIR}/execution/setCredentialsSource.sh "${ACCOUNT}"
