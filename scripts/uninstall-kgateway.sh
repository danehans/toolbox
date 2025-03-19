#!/usr/bin/env bash

set -e

# Source the utility functions
source ./scripts/utils.sh

# Check if required CLI tools are installed
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

echo "Uninstalling Kgateway..."

# Uninstall Kgateway
helm uninstall kgateway -n kgateway-system

# Uninstall Kgateway CRDs
helm uninstall kgateway-crds -n kgateway-system

# Delete the Kgateway namespace
kubectl delete ns/kgateway-system

# Uninstall Kubernetes Gateway CRDs if UNINSTALL_CRDS is set to true
if [[ "$UNINSTALL_CRDS" == true ]]; then
  # Check if the required Gateway API CRDs exist
  REQUIRED_CRDS=(
    "gatewayclasses.gateway.networking.k8s.io"
    "gateways.gateway.networking.k8s.io"
    "httproutes.gateway.networking.k8s.io"
    "referencegrants.gateway.networking.k8s.io"
    "inferencepools.inference.networking.x-k8s.io"
    "inferencemodels.inference.networking.x-k8s.io"
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
    echo "Uninstalling missing $INF_EXT_VERSION Kubernetes Inference Extension CRDs ..."
    kubectl delete -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$INF_EXT_VERSION/manifests.yaml
  else
    echo "No Gateway API and Inference Extension CRDs are present."
  fi
fi

echo "Kgateway successfully uninstalled!"
