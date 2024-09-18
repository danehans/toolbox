#!/usr/bin/env bash

set -euo pipefail

# Setup default values
METALLB_VERSION=${METALLB_VERSION:-"v0.13.7"}

# Source the utility functions.
source ./scripts/utils.sh

# Check if required CLI tools are installed.
for cmd in kubectl kind docker; do
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

# Apply or delete the waypoint
manage_metallb() {
  if [ "$action" = "apply" ]; then
    # Install metallb resources
    echo "Applying MetalLB resources..."
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/"${METALLB_VERSION}"/config/manifests/metallb-native.yaml

    # Create the memberlist secret
    needCreate="$(kubectl get secret -n metallb-system memberlist --no-headers --ignore-not-found -o custom-columns=NAME:.metadata.name)"
    if [ -z "$needCreate" ]; then
        kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
    fi

    # Wait for MetalLB to become available
    kubectl rollout status -n metallb-system deployment/controller --timeout 5m
    kubectl rollout status -n metallb-system daemonset/speaker --timeout 5m

    # Apply config with addresses based on docker network IPAM
    subnet=$(docker network inspect kind | jq -r '.[].IPAM.Config[].Subnet | select(contains(":") | not)')

    # Assume default kind network subnet prefix of 16, and choose addresses in that range
    address_first_octets=$(echo "${subnet}" | awk -F. '{printf "%s.%s",$1,$2}')
    address_range="${address_first_octets}.255.200-${address_first_octets}.255.250"
    kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  namespace: metallb-system
  name: kube-services
spec:
  addresses:
  - ${address_range}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kube-services
  namespace: metallb-system
spec:
  ipAddressPools:
  - kube-services
EOF
  elif [ "$action" = "delete" ]; then
    echo "Deleting MetalLB resources..."
    kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/"${METALLB_VERSION}"/config/manifests/metallb-native.yaml
  fi
}

main() {
  # Validate inputs
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  # Set action and validate
  set_action "$1"

  # Manage metallb
  manage_metallb
}

# Execute main function
main "$@"
