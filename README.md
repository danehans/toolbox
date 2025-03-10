# Toolbox

This repository contains a collection of scripts to automate various tasks related to installation and end-to-end testing.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Utility Scripts](#utility-scripts)
  - [Create a Kind Cluster](#create-a-kind-cluster)
    - [Usage](#usage)
    - [Arguments](#arguments)
  - [Install MetalLB](#install-metallb)
    - [Usage](#usage-1)
    - [Arguments](#arguments-1)
- [Kgateway](#kgateway)
  - [Install Kgateway](#install-kgateway)
    - [Usage](#usage-2)
    - [User-Facing Variables](#user-facing-variables)
  - [Inference Extension Testing](#inference-extension-testing)
    - [Usage](#usage-2)
    - [Arguments](#arguments-2)
    - [User-Facing Variables](#user-facing-variables)
  - [HTTPRoute Testing](#httproute-testing)
    - [Usage](#usage-3)
    - [Arguments](#arguments-3)
    - [User-Facing Variables](#user-facing-variables-1)
  - [TCPRoute Testing](#tcproute-testing)
    - [Usage](#usage-4)
    - [Arguments](#arguments-4)
    - [User-Facing Variables](#user-facing-variables-1)
  - [Uninstall Kgateway](#uninstall-kgateway)
    - [Usage](#usage-4)
- [Gloo Gateway](#gloo-gateway)
  - [Install Gloo Gateway](#install-gloo-gateway)
    - [Usage](#usage-5)
    - [User-Facing Variables](#user-facing-variables-1)
  - [HTTPRoute Testing](#httproute-testing-1)
    - [Usage](#usage-6)
    - [Arguments](#arguments-4)
    - [User-Facing Variables](#user-facing-variables-1)
  - [TCPRoute Testing](#tcproute-testing-1)
    - [Usage](#usage-6)
    - [Arguments](#arguments-5)
    - [User-Facing Variables](#user-facing-variables-1)
  - [Uninstall Gloo Gateway](#uninstall-gloo-gateway)
    - [Usage](#usage-7)
- [Istio](#istio)
  - [Install Istio](#install-istio)
    - [Usage](#usage-7)
    - [Arguments](#arguments-6)
    - [User-Facing Variables](#user-facing-variables-2)
  - [Ambient Testing](#ambient-testing)
    - [Usage](#usage-7)
    - [Arguments](#arguments-6)
    - [User-Facing Variables](#user-facing-variables-3)
  - [Uninstall Istio](#uninstall-istio)
    - [Usage](#usage-8)
    - [Arguments](#arguments-7)"}

## Prerequisites

Ensure the following tools are installed:

- [kubectl](https://kubernetes.io/docs/tasks/tools/): The Kubernetes command-line tool.
- [istioctl](https://istio.io/latest/docs/setup/additional-setup/download-istio-release/): The Istio command-line tool.
- [helm](https://helm.sh/docs/intro/install/): A package manager for Kubernetes.

## Utility Scripts

### Create a Kind Cluster

The `kind-cluster.sh` script creates or deletes a Kubernetes kind cluster based on the provided argument. The cluster consists of 1 control-plane and 2 worker nodes.

#### Usage

```bash
./scripts/kind-cluster.sh [create|delete]
```

#### Arguments

- `create`: Create the kind cluster.
- `delete`: Delete the cluster.

### Install MetalLB

The `metallb.sh` script installs or uninstalls [MetalLB](https://metallb.io/) in the Kubernetes cluster configured in the current kubectl context.

__NOte:__ Mac users must run [docker-mac-net-connect](https://github.com/chipmk/docker-mac-net-connect) to get LoadBalancer services to work
(required by testing scripts).

#### Usage

```bash
./scripts/metallb.sh [apply|delete]
```

#### Arguments

- `apply`: Install MetalLB in the Kubernetes cluster.
- `delete`: Uninstall MetalLB in the Kubernetes cluster.

## Kgateway

[Kgateway](https://kgateway.dev/) is a feature-rich, fast, and flexible Kubernetes-native ingress controller and next-generation API gateway that is built on top of Envoy proxy
and [Gateway API](https://gateway-api.sigs.k8s.io/).

### Install Kgateway

The `install-kgateway.sh` script automates the installation of Kgateway on a Kubernetes cluster.

#### Usage

```bash
./scripts/install-kgateway.sh
```

#### User-Facing Variables

- `KGTW_VERSION`: The version of Kgateway to install. Defaults to "v2.0.0-main".
- `KGTW_REGISTRY`: The name of the image registry to pull the Kgateway image from. Defaults to "ghcr.io/kgateway-dev".
- `HELM_CHART`: The location of the Kgateway Helm chart. Specify the full path to the tarball for local charts. Defaults to "oci://ghcr.io/kgateway-dev/charts/kgateway".
- `INSTALL_CRDS`: Install the Gateway API CRDs. Defaults to true.
- `GATEWAY_API_VERSION`: The version of Gateway API CRDs to install. Defaults to "v1.2.1".
- `GATEWAY_API_CHANNEL`: The channel of Gateway API CRDs to install. Defaults to "experimental" (required for TCPRoute testing).
- `INF_EXT_VERSION`: The version of Gateway API Inference Extension to use. Defaults to "v0.1.0".

### Inference Extension Testing

The `test-kgateway-inference-ext.sh` script automates the setup and testing of Gateway API [Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/) support for Kgateway (`./scripts/install-kgateway.sh` required).

#### Usage

```bash
./scripts/test-kgateway-inference-ext.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `HF_TOKEN`: Your Hugging Face API token with access to the Llama-2-7b-hf model. Defaults to "" so it's required.
- `NS`: The namspace to use for testing. The script will create the namespace if it does not exist. Defaults to "" (meaning the default namespace).
- `NUM_REPLICAS`: The number of replicas for the model server deployment. Defaults to `1`.
- `CURL_POD`: Whether or not to use a pod to run the client curl commands. Defaults to `true`.
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity testing. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity testing. Defaults to 12.

### HTTPRoute Testing

The `test-kgateway-httproute.sh` script automates the setup and testing of HTTProute support for Kgateway (`./scripts/install-kgateway.sh` required).

#### Usage

```bash
./scripts/test-kgateway-httproute.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS`: Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist. Defaults to "default"
- `CURL_POD`: Whether or not to use a pod to run the client curl commands. Defaults to `true`.
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity testing. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity testing. Defaults to 12.

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-kgateway-httproute.sh apply
```

This command creates namespace 'test' and applies the Kubernetes resources in this namespace with a 10-second backoff time between connectivity testing retries.

### TCPRoute Testing

The `test-kgateway-tcproute.sh` script automates the setup and testing of TCProute support for Kgateway (`./scripts/install-kgateway.sh` required).

#### Usage

```bash
./scripts/test-kgateway-tcproute.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS`: Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist. Defaults to "default"
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity testing. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity testing. Defaults to 12.

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-kgateway-tcproute.sh apply
```

### Uninstall Kgateway

The `uninstall-kgateway.sh` script automates the removal of Kgateway on the Kubernetes cluster in the current kubectl context.

#### Usage

```bash
./scripts/uninstall-kgateway.sh
```

## Gloo Gateway

[Gloo Gateway](https://docs.solo.io/gloo-edge/main/) is a feature-rich, Envoy-powered, Kubernetes-native ingress controller, and next-generation API gateway.

### Install Gloo Gateway

The `install-gloo-gateway.sh` script automates the installation of Gloo Gateway on a Kubernetes cluster.

#### Usage

```bash
./scripts/install-gloo-gateway.sh
```

#### User-Facing Variables

- `GLOO_GTW_VERSION`: The version of Gloo Gateway to install. Defaults to "v1.18.0-rc4".
- `HELM_CHART`: The location of the Gloo Gateway Helm chart. Specify the full path to the tarball for local charts. Defaults to "gloo/gloo".
- `INSTALL_CRDS`: Install the Gateway API CRDs. Defaults to true.
- `GATEWAY_API_VERSION`: The version of Gateway API CRDs to install. Defaults to "v1.2.1".
- `GATEWAY_API_CHANNEL`: The channel of Gateway API CRDs to install. Defaults to "experimental" (required for TCPRoute testing).

### HTTPRoute Testing

The `test-gloo-gateway-httproute.sh` script automates the setup and testing of HTTProute support for Gloo Gateway (`./scripts/install-gloo-gateway.sh` required).

#### Usage

```bash
./scripts/test-gloo-gateway-httproute.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS`: Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist. Defaults to "default"
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity testing. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity testing. Defaults to 12.

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-gloo-gateway-httproute.sh apply
```

This command creates namespace 'test' and applies the Kubernetes resources in this namespace with a 10-second backoff time between connectivity testing retries.

### TCPRoute Testing

The `test-gloo-gateway-tcproute.sh` script automates the setup and testing of TCProute support for Gloo Gateway (`./scripts/install-gloo-gateway.sh` required).

#### Usage

```bash
./scripts/test-gloo-gateway-tcproute.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS`: Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist. Defaults to "default"
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity testing. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity testing. Defaults to 12.

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-gloo-gateway-tcproute.sh apply
```

This command creates namespace 'test' and applies the Kubernetes resources in this namespace with a 10-second backoff time between connectivity testing retries.

### Uninstall Gloo Gateway

The `uninstall-gloo-gateway.sh` script automates the removal of Gloo Gateway on the Kubernetes cluster in the current kubectl context.

#### Usage

```bash
./scripts/uninstall-gloo-gateway.sh
```

## Istio

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

The `test-ambient.sh` script automates the setup and testing of Istio's ambient mode in a Kubernetes cluster. It handles the deployment of Istio
waypoints, services, and other resources, and performs connectivity checks between pods.

#### Usage

```bash
./scripts/test-ambient.sh [apply|delete]
```

#### Arguments

- `apply`: Deploy all resources and test connectivity.
- `delete`: Clean up all resources.

#### User-Facing Variables

- `NS`: Specifies the namespace in which resources will be created or deleted. If a different namespace is used, the script will create it if it doesn't already exist. Defaults to "default"
- `BACKOFF_TIME`: Specifies the time in seconds to wait between retries during connectivity and waypoint stats checks. Defaults to 5.
- `MAX_RETRIES`: The maximum number of retry attempts for connectivity and waypoint stats checks. Defaults to 12.
- `WAYPOINT_STATS_KEY`: The specific Istio waypoint stats key to monitor during waypoint connectivity testing. Defaults to "default: http.inbound_0.0.0.0_80;.rbac.allowed".

Example

```bash
NS=test BACKOFF_TIME=10 ./scripts/test-ambient.sh apply
```

This command creates namespace 'test' and applies the Kubernetes resources in this namespace with a 10-second backoff time between retries.

### Uninstall Istio

The `uninstall-istio.sh` script automates the removal of Istio on a Kubernetes cluster in the current kubectl context. It uninstalls the
Istio control plane, ambient mesh configuration, etc.

#### Usage

```bash
./scripts/uninstall-istio.sh [ambient|sidecar]
```

#### Arguments

- `ambient`: Uninstall Istio in ambient mode.
- `sidecar`: Uninstall Istio in sidecar mode.

## Contributing

Feel free to open issues or submit pull requests if you'd like to contribute to improving the scripts.
