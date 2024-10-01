#!/usr/bin/env bash

set -e

# The version of Gateway API CRDs to uninstall
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-"v1.1.0"}

# Source the utility functions
source ./scripts/utils.sh

# Check if required CLI tools are installed
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Uninstall Istiod
helm uninstall gloo-gateway -n gloo-system

# Check if the required Gateway API CRDs exist
REQUIRED_CRDS=(
  "gatewayclasses.gateway.networking.k8s.io"
  "gateways.gateway.networking.k8s.io"
  "httproutes.gateway.networking.k8s.io"
  "referencegrants.gateway.networking.k8s.io"
)

CRDS_EXISTS=false
for crd in "${REQUIRED_CRDS[@]}"; do
  if kubectl get crd "$crd" &>/dev/null; then
    echo "CRD '$crd' exists."
    CRDS_EXISTS=true
  fi
done

# Uninstall the Gateway API CRDs if any exist
if [ "$CRDS_EXISTS" = true ]; then
  echo "Uninstalling Kubernetes Gateway API CRDs..."
  kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml
else
  echo "No Gateway API CRDs are present."
fi

# Delete the gGloo Gateway namespace
kubectl delete ns/gloo-system

echo "Gloo Gateway successfully uninstalled!"
