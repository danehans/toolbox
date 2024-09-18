#!/usr/bin/env bash

set -e

# Source the utility functions
source ./scripts/utils.sh

# Check if the installation profile argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <installation_profile>"
    exit 1
fi

profile=$1

# Supportedinstall profile values.
valid_profiles=("ambient" "sidecar")

# Check if profile argument is valid
if [[ ! " ${valid_profiles[*]} " =~ " $profile " ]]; then
  echo "Invalid value for profile. Supported values are 'ambient' and 'sidecar'"
  exit 1
fi

# Check if required CLI tools are installed
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Uninstall ambient components
if [[ "$profile" == "ambient" ]]; then
  helm uninstall ztunnel -n istio-system
  helm uninstall istio-cni -n istio-system
fi

# Uninstall Istiod
helm uninstall istiod -n istio-system

# Unininstall istio-base
helm uninstall istio-base -n istio-system

# Uninstall Kubernetes Gateway CRDs
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | kubectl delete -f -; }

echo "Gateway API CRDs deleted."

# Delete the Istio namespace
kubectl delete ns/istio-system

echo "Istio successfully uninstalled!"
