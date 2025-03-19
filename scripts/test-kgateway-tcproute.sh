#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# Set default back-off time, max retries, and namespace
BACKOFF_TIME=${BACKOFF_TIME:-5}
MAX_RETRIES=${MAX_RETRIES:-12}
NS=${NS:-default}  # User-facing namespace variable, defaults to "default"

# Check if required CLI tools are installed.
for cmd in kubectl helm nc; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Validate input argument
set_action() {
  if [ "$1" != "apply" ] && [ "$1" != "delete" ]; then
    echo "Invalid action. Use 'apply' or 'delete'."
    exit 1
  fi
  action=$1
}

# Check if the namespace "metallb-system" exists and handle accordingly
check_and_manage_metallb() {
  if [ "$METAL_LB" == "true" ]; then
    if [ "$action" == "apply" ]; then
      if ! kubectl get namespace metallb-system >/dev/null 2>&1; then
        echo "Namespace 'metallb-system' does not exist. Applying MetalLB configuration..."
        if ! ./scripts/metallb.sh apply; then
          echo "Error: Failed to apply MetalLB configuration."
          exit 1
        fi
        echo "MetalLB configuration applied successfully."
      else
        echo "Namespace 'metallb-system' exists. Checking the status of resources."

        # Check if the Deployment "controller" exists
        if kubectl get deployment -n metallb-system controller >/dev/null 2>&1; then
          available_status=$(kubectl get deployment -n metallb-system controller -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')

          if [[ "$available_status" != "True" ]]; then
            echo "Error: Deployment 'controller' is not in 'Available' status."
            exit 1
          fi
          echo "Deployment 'controller' is available."
        else
          echo "Error: Deployment 'controller' does not exist in 'metallb-system'."
          exit 1
        fi

        # Check if the DaemonSet "speaker" exists
        if kubectl get daemonset -n metallb-system speaker >/dev/null 2>&1; then
          number_ready=$(kubectl get daemonset -n metallb-system speaker -o jsonpath='{.status.numberReady}')

          if [[ "$number_ready" -lt 1 ]]; then
            echo "Error: DaemonSet 'speaker' has insufficient ready pods (numberReady < 1)."
            exit 1
          fi
          echo "DaemonSet 'speaker' has $number_ready ready pods."
        else
          echo "Error: DaemonSet 'speaker' does not exist in 'metallb-system'."
          exit 1
        fi
      fi
    elif [ "$action" == "delete" ]; then
      if kubectl get namespace metallb-system >/dev/null 2>&1; then
        echo "Namespace 'metallb-system' exists. Deleting MetalLB configuration..."
        if ! ./scripts/metallb.sh delete; then
          echo "Error: Failed to delete MetalLB configuration."
          exit 1
        fi
        echo "MetalLB configuration deleted successfully."
      else
        echo "Namespace 'metallb-system' does not exist. Nothing to delete."
      fi
    fi
  fi
}

# Create or delete the Kubernetes gateway resource
manage_gtw_resource() {
  echo "Managing Kubernetes Gateway resource with action: $action"
  kubectl $action -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: tcp
  namespace: kgateway-system
spec:
  gatewayClassName: kgateway
  listeners:
  - protocol: TCP
    port: 8000
    name: tcp
    allowedRoutes:
      namespaces:
        from: All
      kinds:
      - kind: TCPRoute
EOF
}

# Create or delete the Kubernetes example tcp echo app resources
manage_tcp_echo_resources() {
  echo "Managing Kubernetes resources for the example tcp-echo app with action: $action"

  if [ "$action" == "apply" ]; then
    # Check if namespace $NS exists, and create it if it does not
    if ! kubectl get namespace $NS >/dev/null 2>&1; then
      echo "Namespace $NS does not exist. Creating namespace $NS..."
      kubectl create namespace $NS
    else
      echo "Namespace $NS already exists."
    fi

    # Apply the httpbin resources
    kubectl -n $NS apply -f https://gist.githubusercontent.com/danehans/8081ade20ac03153c5d4625e64c419bf/raw/5404e2ad11d8bdd6e34b1d18effa1fb98401e1e1/tcp_echo.yaml

  else
    # Delete the httpbin resources
    kubectl -n $NS delete -f https://gist.githubusercontent.com/danehans/8081ade20ac03153c5d4625e64c419bf/raw/5404e2ad11d8bdd6e34b1d18effa1fb98401e1e1/tcp_echo.yaml --force

    # Only delete the namespace if it is not "default"
    if [ "$NS" != "default" ]; then
      if kubectl get namespace $NS >/dev/null 2>&1; then
        echo "Deleting namespace $NS..."
        kubectl delete namespace $NS
      else
        echo "Namespace $NS does not exist."
      fi
    else
      echo "Namespace $NS is 'default', not deleting."
    fi
  fi
}

# Create or delete the Kubernetes tcproute resource
manage_tcproute_resource() {
  if [ "$action" == "apply" ]; then
    echo "Applying Kubernetes TCPRoute resource..."
    kubectl apply -n $NS -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: tcp-echo
spec:
  parentRefs:
    - name: tcp
      namespace: kgateway-system
      sectionName: tcp
  rules:
    - backendRefs:
        - name: tcp-echo
          port: 1025
EOF
  fi
}

# Test connectivity through the Kgateway
test_kgtw_connectivity() {
  echo "Testing TCP connectivity through Kgateway..."

  retries=0
  gtw_ip=""

  while [ $retries -lt $MAX_RETRIES ]; do
    # Fetch the gateway IP
    echo "Fetching the IP for gateway/tcp ..."
    gtw_ip=$(kubectl get gateway/tcp -n kgateway-system -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$gtw_ip" ]; then
      echo "Attempt $((retries + 1)): Failed to get gateway/tcp IP. Gateway might not be ready yet. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    else
      echo "Gateway IP: $gtw_ip"
      break
    fi
  done

  if [ -z "$gtw_ip" ]; then
    echo "Failed to get gateway/tcp IP after $retries retries."
    return 1
  fi

  retries=0
  sleep $BACKOFF_TIME
  while [ $retries -lt $MAX_RETRIES ]; do
    # Test TCP connectivity using nc
    echo "Sending test message to $gtw_ip:8000..."
    response=$(echo "Hello, TCP!" | nc -w 5 $gtw_ip 8000)

    # Check if the response echoes back the test message
    if [ "$response" == "Hello, TCP!" ]; then
      echo "Connection successful! Received expected response: '$response'."
      return 0
    else
      echo "Attempt $((retries + 1)): Response mismatch or no response. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    fi
  done

  echo "Failed to connect after $retries retries."
  return 1
}

main() {
  # Validate inputs
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  # Set action and validate
  set_action "$1"

  # Check for and apply or delete MetalLB configuration
  check_and_manage_metallb

  # Create or delete the k8s gateway resource
  manage_gtw_resource

  # Create or delete the example tcp app k8s resources
  manage_tcp_echo_resources

  # Create or delete the k8s tcproute resources
  manage_tcproute_resource

  if [ "$action" = "apply" ]; then
    # Wait for the gateway name/ns to be ready
    check_gateway_status "tcp" "kgateway-system"

    # Check the status of the tcp echo deployment
    deploy_rollout_status "tcp-echo" $NS

    # Check the status of the tcproute
    check_tcproute_status "tcp-echo" $NS

    # Test connectivity through the Kgateway
    test_kgtw_connectivity
  fi
}

# Execute main function
main "$@"
