#!/usr/bin/env bash

set -e

# The location of the Helm chart. Specify the full path to the tarball for local charts.
HELM_CHART=${HELM_CHART:-"oci://ghcr.io/kgateway-dev/charts/kgateway"}
KGTW_REGISTRY=${KGTW_REGISTRY:-"ghcr.io/kgateway-dev"}

# Source the utility functions.
source ./scripts/utils.sh

# Check if required CLI tools are installed.
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Verify access to the Kubernetes cluster
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "Error: Unable to connect to the Kubernetes cluster (kubectl get nodes failed)."
  exit 1
fi

# Install Kubernetes Gateway CRDs if INSTALL_CRDS is set to true
if [[ "$INSTALL_CRDS" == true ]]; then
  # Check if the required Gateway API CRDs exist
  REQUIRED_CRDS=(
    "gatewayclasses.gateway.networking.k8s.io"
    "gateways.gateway.networking.k8s.io"
    "httproutes.gateway.networking.k8s.io"
    "tcproutes.gateway.networking.k8s.io"
    "referencegrants.gateway.networking.k8s.io"
    "inferencepools.inference.networking.x-k8s.io"
    "inferencemodels.inference.networking.x-k8s.io"
  )

  CRDS_MISSING=false
  for crd in "${REQUIRED_CRDS[@]}"; do
    if ! kubectl get crd "$crd" &>/dev/null; then
      echo "CRD '$crd' is missing."
      CRDS_MISSING=true
    fi
  done

  # Install the Gateway API and Inference Extension CRDs if any are missing.
  if [ "$CRDS_MISSING" = true ]; then
    echo "Installing missing $GATEWAY_API_VERSION Kubernetes Gateway API CRDs from the $GATEWAY_API_CHANNEL channel ..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/$GATEWAY_API_CHANNEL-install.yaml
    echo "Installing missing $INF_EXT_VERSION Kubernetes Inference Extension CRDs ..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/$INF_EXT_VERSION/manifests.yaml
  else
    echo "All required Gateway API and Inference Extension CRDs are already present."
  fi
fi

# Ensure KGTW_VERSION is set
if [[ -z "${KGTW_VERSION:-}" ]]; then
  echo "Error: KGTW_VERSION environment variable is not set. Please export it to the desired version."
  exit 1
fi

echo "Installing Kgateway (version $KGTW_VERSION) in namespace 'kgateway-system'..."

# Install Kgateway.
helm upgrade --install kgateway "$HELM_CHART" \
  -n kgateway-system \
  --create-namespace \
  --set image.registry="$KGTW_REGISTRY" \
  --set inferenceExtension.enabled=true \
  --version "$KGTW_VERSION"

# Wait for the gloo deployment rollout to complete.
check_gatewayclass_status "kgateway"

echo "Kgateway successfully installed!"
