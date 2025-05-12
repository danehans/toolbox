#!/usr/bin/env bash

set -e

COMMIT_SHA=${COMMIT_SHA:-"ddc488f033"}
# The location of the Kgateway Helm chart. Specify the full path to the tarball for local charts.
# Use "oci://ghcr.io/kgateway-dev/charts/kgateway" for upstream.
# Use https://github.com/danehans/toolbox/raw/refs/heads/main/charts/$COMMIT_SHA-kgateway-1.0.1-dev.tgz for local dev.
HELM_CHART=${HELM_CHART:-"oci://ghcr.io/kgateway-dev/charts/kgateway"}
# The location of the Kgateway CRDs Helm chart. Specify the full path to the tarball for local charts.
# Use "oci://ghcr.io/kgateway-dev/charts/kgateway-crds" for upstream.
# Use "https://github.com/danehans/toolbox/raw/refs/heads/main/charts/$COMMIT_SHA-kgateway-crds-1.0.1-dev.tgz" for local dev.
HELM_CRD_CHART=${HELM_CRD_CHART:-"oci://ghcr.io/kgateway-dev/charts/kgateway-crds"}
# IMAGE_REGISTRY is the registry to use for the Kgateway images. Note: This is the same env var as Kgateway.
# Use "ghcr.io/kgateway-dev" for upstream.
# Use "danehans" for local dev.
IMAGE_REGISTRY=${IMAGE_REGISTRY:-"ghcr.io/kgateway-dev"}
# PULL_POLICY defines the pull policy for the Kgateway container image.
PULL_POLICY=${PULL_POLICY:-"IfNotPresent"}

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

echo "Installing Kgateway CRDs (version $KGTW_VERSION)..."

# Install Kgateway CRDs.
helm upgrade --install kgateway-crds "$HELM_CRD_CHART" \
  -n kgateway-system \
  --create-namespace \
  --version "$KGTW_VERSION"

echo "Installing Kgateway (version $KGTW_VERSION) in namespace 'kgateway-system'..."

# Install Kgateway.
helm upgrade --install kgateway "$HELM_CHART" \
  -n kgateway-system \
  --set image.registry="$IMAGE_REGISTRY" \
  --set controller.image.pullPolicy="$PULL_POLICY" \
  --set inferenceExtension.enabled="$INF_EXT" \
  --version "$KGTW_VERSION"

# Wait for the gloo deployment rollout to complete.
check_gatewayclass_status "kgateway"

echo "Kgateway successfully installed!"
