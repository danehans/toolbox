#!/usr/bin/env bash

set -e

# The repo to use for pulling Istio container images.
ISTIO_REPO=${ISTIO_REPO:-"docker.io/istio"}
# A time unit, e.g. 1s, 2m, 3h, to wait for Istio control-plane component deployment rollout to complete.
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-"5m"}
# The localation of the Helm chart. Specify the full path to the tarball for local charts.
HELM_CHART=${HELM_CHART:-"gloo/gloo"}
# Control Gateway API CRD installation
INSTALL_CRDS=${INSTALL_CRDS:-true}
# The version of Gateway API CRDs to install
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-"v1.1.0"}

# Source the utility functions.
source ./scripts/utils.sh

# Check if required CLI tools are installed.
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Supported version values are 1.17.7 and newer.
minor_version=$(echo $GLOO_GTW_VERSION | cut -d. -f2)
patch_version=$(echo $GLOO_GTW_VERSION | cut -d. -f3 | cut -d- -f1)

if [[ "$minor_version" -lt 17 ]] || [[ "$minor_version" -eq 17 && "$patch_version" -lt 7 ]]; then
  echo "Invalid value for GLOO_GTW_VERSION. Supported versions are 1.17.7 and newer."
  exit 1
fi

# Install Kubernetes Gateway CRDs if INSTALL_CRDS is set to true
if [[ "$INSTALL_CRDS" == true ]]; then
  # Check if the required Gateway API CRDs exist
  REQUIRED_CRDS=(
    "gatewayclasses.gateway.networking.k8s.io"
    "gateways.gateway.networking.k8s.io"
    "httproutes.gateway.networking.k8s.io"
    "referencegrants.gateway.networking.k8s.io"
  )

  CRDS_MISSING=false
  for crd in "${REQUIRED_CRDS[@]}"; do
    if ! kubectl get crd "$crd" &>/dev/null; then
      echo "CRD '$crd' is missing."
      CRDS_MISSING=true
    fi
  done

  # Install the Gateway API CRDs if any are missing
  if [ "$CRDS_MISSING" = true ]; then
    echo "Installing missing Kubernetes Gateway API CRDs..."
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml
  else
    echo "All required Gateway API CRDs are already present."
  fi
fi

echo "Installing Gloo Gateway..."

if [[ $HELM_CHART == "gloo/gloo" ]]; then
  # Add Gloo Gateway helm repo.
  helm repo add gloo https://storage.googleapis.com/solo-public-helm
  helm repo update
fi

# Install Gloo Gateway.
helm upgrade --install gloo-gateway $HELM_CHART \
-n gloo-system \
--create-namespace \
--version=$GLOO_GTW_VERSION \
--set kubeGateway.enabled=true \
--set gloo.disableLeaderElection=true \
--set discovery.enabled=false \
--set gatewayProxies.gatewayProxy.disabled=true

# Wait for the gloo deployment rollout to complete.
check_gatewayclass_status "gloo-gateway"

echo "Gloo Gateway successfully installed!"
