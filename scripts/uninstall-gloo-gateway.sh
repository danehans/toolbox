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

# Uninstall Istiod
helm uninstall gloo-gateway -n gloo-system

# Uninstall Kubernetes Gateway CRDs
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

echo "Gateway API CRDs deleted."

# Delete the gGloo Gateway namespace
kubectl delete ns/gloo-system

echo "Gloo Gateway successfully uninstalled!"
