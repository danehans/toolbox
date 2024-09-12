# Istio Testing Scripts

This repository contains a collection of scripts to automate various tasks related to testing Istio in Kubernetes environments.
Each script provides functionality to streamline the deployment, management, and testing of Istio features such as ambient mesh,
waypoints, and connectivity testing.

## Prerequisites

Ensure the following tools are installed:

- [kubectl](https://kubernetes.io/docs/tasks/tools/): The Kubernetes command-line tool.
- [istioctl](https://istio.io/latest/docs/setup/additional-setup/download-istio-release/): The Istio command-line tool.
- [helm](https://helm.sh/docs/intro/install/): A package manager for Kubernetes.

## Overview of Scripts

### Create a Kind Cluster

The `kind-cluster.sh` script creates or deletes a Kubernetes kind cluster based on the provided argument. The cluster consists of 1 control-plane and 2 worker nodes.

#### Usage

```bash
./scripts/kind-cluster.sh [create|delete]
```

#### Arguments

- `create`: Create the kind cluster.
- `delete`: Delete the cluster.

### Install Istio

The `install-istio.sh` script automates the installation of Istio on a Kubernetes cluster. It handles the installation of the Istio control plane, ambient mesh configuration, and enables various Istio features such as gateways, telemetry, and ingress.

#### Usage

```bash
./scripts/install-istio.sh [ambient|sidecar]
```

#### Arguments

- `ambient`: Install Istio in ambient mode.
- `sidecar`: Install Istio in sidecar mode.

#### User-Facing Variables

- `ISTIO_VERSION` (default: 1.23.0): The version of Istio to install.
- `ISTIO_REPO` (default: docker.io/istio): The Docker repository to pull Istio control plane images from.
- `ROLLOUT_TIMEOUT` (default: 5m): A time unit, e.g. 1s, 2m, 3h, to wait for Istio control-plane component deployment rollout to complete.

Example:

```bash
ISTIO_VERSION=1.22.1 ROLLOUT_TIMEOUT=15m ./scripts/install-istio.sh ambient
```

The example installs Istio in ambient mode and waits up to 15-minutes for each control plane component deployment to report a ready status.

### Ambient Testing

The `test-ambient.sh` script script automates the setup and testing of Istio's ambient mode in a Kubernetes cluster. It handles the deployment of Istio
waypoints, services, and other resources, and performs connectivity checks between pods.

#### Usage

```bash
./scripts/test-ambient.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS` (default: default): Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist.
- `BACKOFF_TIME` (default: 5): Specifies the time in seconds to wait between retries during connectivity and waypoint stats checks.
- `MAX_RETRIES` (default: 12): The maximum number of retry attempts for connectivity and waypoint stats checks.
- `WAYPOINT_STATS_KEY` (default: http.inbound_0.0.0.0_80;.rbac.allowed): The specific Istio waypoint stats key to monitor during waypoint connectivity testing.

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-ambient.sh apply
```

This command applies the resources in the 'test' namespace with a 10-second backoff time between retries.

### Uninstall Istio

The `uninstall-istio.sh` script automates the removal of Istio on a Kubernetes cluster. It uninstalls the Istio control plane, ambient mesh configuration, etc.

#### Usage

```bash
./scripts/uninstall-istio.sh [ambient|sidecar]
```

#### Arguments

- `ambient`: Uninstall Istio in ambient mode.
- `sidecar`: Uninstall Istio in sidecar mode.

## Contributing

Feel free to open issues or submit pull requests if you'd like to contribute to improving the scripts.
