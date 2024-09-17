#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# Function to display usage information
usage() {
  echo "Usage: $0 [create|delete]"
  exit 1
}

# Check if kind is installed
if ! command_exists kind; then
  echo "kind is not installed. Please install kind before running this script."
  exit 1
fi

# Check the argument
if [ $# -ne 1 ]; then
  usage
fi

ACTION=$1

# Validate input argument
if [ "$ACTION" != "create" ] && [ "$ACTION" != "delete" ]; then
  echo "Invalid argument. Please use 'create' or 'delete'."
  usage
fi

# Cluster name (modify if you want a different name)
CLUSTER_NAME="kind"

# Check if the cluster already exists
CLUSTER_EXISTS=$(kind get clusters)

# Handle the case where no clusters are found
if [[ "$CLUSTER_EXISTS" == "No kind clusters found." ]]; then
  CLUSTER_EXISTS=""
fi

if [ "$ACTION" == "create" ]; then
  if echo "$CLUSTER_EXISTS" | grep -qw "$CLUSTER_NAME"; then
    echo "Cluster '$CLUSTER_NAME' already exists. Exiting."
    exit 1
  fi

  # Cluster configuration YAML
  cat <<EOF > kind-cluster-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
EOF

  # Create the kind cluster
  echo "Creating kind cluster..."
  kind create cluster --name "$CLUSTER_NAME" --config kind-cluster-config.yaml

  # Cleanup
  rm kind-cluster-config.yaml

  echo "Kind cluster created successfully."

elif [ "$ACTION" == "delete" ]; then
  if [ -z "$CLUSTER_EXISTS" ]; then
    echo "Cluster '$CLUSTER_NAME' does not exist. Exiting."
    exit 1
  fi

  # Delete the kind cluster
  echo "Deleting kind cluster..."
  kind delete cluster --name "$CLUSTER_NAME"

  echo "Kind cluster deleted successfully."
fi

