#!/usr/bin/env bash

set -e

# The version of Istio to install.
ISTIO_VERSION=${ISTIO_VERSION:-"1.23.1"}

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

# Function to compare Istio version
check_istio_version() {
  local installed_version
  installed_version=$(istioctl version --remote=false 2>/dev/null | grep "client version" | awk '{print $3}')

  if [ -z "$installed_version" ]; then
    echo "Unable to determine istioctl client version."
    exit 1
  fi

  if [ "$installed_version" != "$ISTIO_VERSION" ]; then
    echo "Installed istioctl version ($installed_version) does not match the required version ($ISTIO_VERSION)."
    exit 1
  else
    echo "istioctl version is correct: $installed_version"
  fi
}
