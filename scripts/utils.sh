#!/usr/bin/env bash

set -e

# NS is the namespace to use for testing.
NS=${NS:-default}
# Set default back-off time, max retries, and namespace.
BACKOFF_TIME=${BACKOFF_TIME:-3}
MAX_RETRIES=${MAX_RETRIES:-15}
# The version of Gateway API Inference Extension to use.
INF_EXT_VERSION=${INF_EXT_VERSION:-"v0.3.0"}
# The version of Gateway API CRDs to install/uninstall.
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-"v1.3.0"}
# The channel of Gateway API CRDs to install
GATEWAY_API_CHANNEL=${GATEWAY_API_CHANNEL:-"experimental"}
# Control Gateway API CRD installation
INSTALL_CRDS=${INSTALL_CRDS:-true}
# Control Gateway API CRD uninstall
UNINSTALL_CRDS=${UNINSTALL_CRDS:-true}
# The version of Istio to install.
ISTIO_VERSION=${ISTIO_VERSION:-"1.23.1"}
# The version of Kgateway to install.
# Use "v2.0.0-main" for upstream
KGTW_VERSION=${KGTW_VERSION:-"v2.0.2"}
# The version of Gloo Gateway to install.
GLOO_GTW_VERSION=${GLOO_GTW_VERSION:-"v1.18.0"}
# A time unit, e.g. 1s, 2m, 3h, to wait for a daemonset/deployment rollout to complete.
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-"10m"}
# METAL_LB defines whether or not to use MetalLB for LoadBalancer type services.
METAL_LB=${METAL_LB:-false}
# CURL_POD defines whether to install a cURL client pod and use it to test connectivity.
CURL_POD=${CURL_POD:-true}
# INF_EXT defines whether to enable gateway API inference extensions.
INF_EXT=${INF_EXT:-true}

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
  local name=$1
  local ns=$2
  kubectl rollout status deploy/$name -n $ns --timeout=$ROLLOUT_TIMEOUT || {
    echo "Rollout status check failed for deployment $ns/$name: ${PIPESTATUS[0]}"
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

# Function to check the status of a GatewayClass resource with retries
check_gatewayclass_status() {
  local name=$1
  local retries=0

  echo "Checking status of GatewayClass $name..."

  while [ $retries -lt $MAX_RETRIES ]; do
    # Check if GatewayClass exists before accessing its status
    if kubectl get gatewayclass "$name" >/dev/null 2>&1; then
      accepted_status=$(kubectl get gatewayclass "$name" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}')

      if [ "$accepted_status" == "True" ]; then
        echo "GatewayClass $name is accepted."
        return 0
      else
        echo "Attempt $((retries + 1)): GatewayClass $name exists but not accepted yet. Retrying in $BACKOFF_TIME seconds..."
      fi
    else
      echo "Attempt $((retries + 1)): GatewayClass $name not found yet. Retrying in $BACKOFF_TIME seconds..."
    fi

    retries=$((retries + 1))
    sleep $BACKOFF_TIME
  done

  echo "GatewayClass $name was not accepted after $MAX_RETRIES retries."
  exit 1
}

# Function to check the status of a Gateway resource with retries
check_gateway_status() {
  local name=$1
  local ns=$2
  local retries=0

  echo "Checking status of Gateway $ns/$name..."

  while [ $retries -lt $MAX_RETRIES ]; do
    # Fetch the status of the Gateway
    programmed_status=$(kubectl get -n $ns gateway/$name -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')

    if [ "$programmed_status" == "True" ] ; then
      echo "Gateway $ns/$name is ready."
      return 0
    else
      echo "Attempt $((retries + 1)): Gateway $ns/$name is not ready yet. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    fi
  done

  echo "Gateway $ns/$name was not ready after $MAX_RETRIES retries."
  exit 1
}

# Function to check the status of an HTTPRoute resource with retries
check_httproute_status() {
  local name=$1
  local ns=$2
  local retries=0

  echo "Checking status of HTTPRoute $ns/$name..."

  while [ $retries -lt $MAX_RETRIES ]; do
    # Fetch the Accepted condition status for the HTTPRoute
    accepted_status=$(kubectl get -n $ns httproute/$name -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')

    if [ "$accepted_status" == "True" ] ; then
      echo "HTTPRoute $ns/$name is accepted."
      return 0
    else
      echo "Attempt $((retries + 1)): HTTPRoute $ns/$name is not accepted yet. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    fi
  done

  echo "HTTPRoute $ns/$name was not accepted and refs were resolved after $MAX_RETRIES retries."
  exit 1
}

# Function to check the status of an TCPRoute resource with retries
check_tcproute_status() {
  local name=$1
  local ns=$2
  local retries=0

  echo "Checking status of TCPRoute $ns/$name..."

  while [ $retries -lt $MAX_RETRIES ]; do
    # Fetch the Accepted condition status for the TCPRoute
    accepted_status=$(kubectl get -n $ns tcproute/$name -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')

    if [ "$accepted_status" == "True" ] ; then
      echo "TCPRoute $ns/$name is accepted."
      return 0
    else
      echo "Attempt $((retries + 1)): TCPRoute $ns/$name is not accepted yet. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    fi
  done

  echo "TCPRoute $ns/$name was not accepted and refs were resolved after $MAX_RETRIES retries."
  exit 1
}
