#!/usr/bin/env bash

set -e

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to handle rollout status of a daemonset
ds_rollout_status() {
  local ds=$1
  local ns=$2
  kubectl rollout status ds/$ds -n $ns --timeout=$ROLLOUT_TIMEOUT || {
    echo "Rollout status check failed for daemonset $ds/$ns: ${PIPESTATUS[0]}"
    exit 1
  }
}

# Function to handle rollout status of a deployment
deploy_rollout_status() {
  local deploy=$1
  local ns=$2
  kubectl rollout status deploy/$deploy -n $ns --timeout=$ROLLOUT_TIMEOUT || {
    echo "Rollout status check failed for deployment $deploy/$ns: ${PIPESTATUS[0]}"
    exit 1
  }
}
