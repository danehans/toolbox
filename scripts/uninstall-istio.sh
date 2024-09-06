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

# Check if NUM_NS is valid
if [[ ! " ${valid_profiles[*]} " =~ " $profile " ]]; then
  echo "Invalid value for profile. Supported values are 'ambient' and 'sidecar'"
  exit 1
fi

# Check if required CLI tools are installed
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$CMD is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Create the ztunnel config file
if [[ "$profile" == "ambient" ]]; then
  helm uninstall ztunnel -n istio-system
  helm uninstall istio-cni -n istio-system
fi

# Uninstall Istiod
helm uninstall istiod -n istio-system

# Ininstall istio-base
helm uninstall istio-base -n istio-system

# Uninstall Kubernetes Gateway CRDs
kubectl get crd gateways.gateway.networking.k8s.io &> /dev/null || \
  { kubectl kustomize "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.0.0" | kubectl delete -f -; }

echo "Gateway API CRDs deleted."

# Delete the Istio namespace
kubectl delete ns/istio-system

echo "istio-system namespace deleted."

# Remove the configuration files
rm -rf istio-cni-config.yaml istio-ztunnel-config.yaml istiod-config.yaml

echo "Removed Istio configuration files."

echo "Istio successfully uninstalled!"
