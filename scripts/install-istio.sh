#!/usr/bin/env bash

set -e

# The repo to use for pulling Istio container images.
ISTIO_REPO=${ISTIO_REPO:-"docker.io/istio"}
# A time unit, e.g. 1s, 2m, 3h, to wait for Istio control-plane component deployment rollout to complete.
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-"5m"}

# Source the utility functions.
source ./scripts/utils.sh

# Check if the installation profile argument is provided.
if [ -z "$1" ]; then
    echo "Usage: $0 <installation_profile>"
    exit 1
fi

profile=$1

# Supported install profile values.
valid_profiles=("ambient" "sidecar")

# Check if NUM_NS is valid.
if [[ ! " ${valid_profiles[*]} " =~ " $profile " ]]; then
  echo "Invalid value for profile. Supported values are 'ambient' and 'sidecar'"
  exit 1
fi

# Supported Itio version values are 1.22.1 and newer.
minor_version=$(echo $ISTIO_VERSION | cut -d. -f2)
patch_version=$(echo $ISTIO_VERSION | cut -d. -f3 | cut -d- -f1)

if [[ "$minor_version" -lt 22 ]] || [[ "$minor_version" -eq 22 && "$patch_version" -lt 1 ]]; then
  echo "Invalid value for ISTIO_VERSION. Supported versions are 1.22.1 and newer."
  exit 1
fi

# Check if required CLI tools are installed.
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Add Istio helm repo.
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

# Install istio-base.
helm upgrade --install istio-base istio/base -n istio-system --version $ISTIO_VERSION --create-namespace

# Install Kubernetes Gateway CRDs.
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | kubectl apply -f -; }

# Create the istio cni config file.
if [[ "$profile" == "ambient" ]]; then
  cat << EOF > istio-cni-config.yaml
global:
  hub: $ISTIO_REPO
  tag: $ISTIO_VERSION
profile: ambient
EOF

  # Echo the contents of the config file.
  echo "Generated istio-cni-node configuration:"
  cat istio-cni-config.yaml

  # Install istio cni.
  helm upgrade --install istio-cni istio/cni \
  -n istio-system \
  --version=$ISTIO_VERSION \
  -f istio-cni-config.yaml

  # Wait for the istio cni daemonset rollout to complete.
  ds_rollout_status "istio-cni-node" "istio-system"
fi

# Create the istiod config file.
if [[ "$profile" == "ambient" ]]; then
  cat << EOF > istiod-config.yaml
global:
  hub: $ISTIO_REPO
  tag: $ISTIO_VERSION
meshConfig:
  defaultConfig:
    proxyStatsMatcher:
      inclusionRegexps:
        - "listener.0.0.0.0_15008.*"
profile: ambient
EOF
else
  cat << EOF > istiod-config.yaml
global:
  hub: $ISTIO_REPO
  tag: $ISTIO_VERSION
meshConfig:
  accessLogFile: /dev/stdout
  enableAutoMtls: true
  defaultConfig:
    holdApplicationUntilProxyStarts: true
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  outboundTrafficPolicy:
    mode: ALLOW_ANY
EOF
fi

# Echo the contents of the istiod config file.
echo "Generated istiod configuration:"
cat istiod-config.yaml

# Install Istiod.
helm upgrade --install istiod istio/istiod \
-n istio-system \
--version=$ISTIO_VERSION \
-f istiod-config.yaml

# Wait for the istiod deployment rollout to complete.
deploy_rollout_status "istiod" "istio-system"

# TODO: Update the sidecar injector configmap for ambient waypoint anti-affinity.

# Create the ztunnel config file.
if [[ "$profile" == "ambient" ]]; then
  cat << EOF > istio-ztunnel-config.yaml
variant: distroless
hub: $ISTIO_REPO
tag: $ISTIO_VERSION
EOF

  # Echo the contents of the config file.
  echo "Generated istio-ztunnel configuration:"
  cat istio-ztunnel-config.yaml

  # Install ztunnel
  helm upgrade --install ztunnel istio/ztunnel \
  -n istio-system \
  --version=$ISTIO_VERSION \
  -f istio-ztunnel-config.yaml

  # Wait for the ztunnel daemonset rollout to complete.
  ds_rollout_status "ztunnel" "istio-system"

  # Remove the ambient installation configuration file
  rm -rf istio-cni-config.yaml istio-ztunnel-config.yaml

  echo "Removed ambient installation configuration files."
fi

# Remove the Istiod installation configuration file
rm -rf istiod-config.yaml

echo "Removed Istiod installation configuration file."

echo "Istio successfully installed!"
