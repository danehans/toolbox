#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

HF_TOKEN=${HF_TOKEN:-""}
# NUM_REPLICAS defines the number of replicas to use for the model server backend deployment.
NUM_REPLICAS=${NUM_REPLICAS:-3}
# PROC_TYPE defines the processor type to use for vLLM, either "cpu" or "gpu" (default).
PROC_TYPE=${PROC_TYPE:-"gpu"}

# Check if required CLI tools are installed.
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

check_k8s_version() {
  # Grab the line that starts with "Server Version:" from `kubectl version`.
  local server_line
  server_line=$(kubectl version | grep "Server Version")

  if [ -z "$server_line" ]; then
    echo "Could not parse Kubernetes server version from 'kubectl version' output."
    exit 1
  fi

  # Extract the third field (v1.32.0), remove leading "v".
  local server_version
  server_version=$(echo "$server_line" | awk '{print $3}' | sed 's/^v//')

  # Extract major and minor.
  local major minor
  major=$(echo "$server_version" | cut -d '.' -f1)
  minor=$(echo "$server_version" | cut -d '.' -f2)

  # Validate numeric version.
  if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
    echo "Could not parse Kubernetes server version: $server_version"
    exit 1
  fi

  # Compare to support version (1.29).
  if [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 29 ]; }; then
    echo "Error: Kubernetes server version v${major}.${minor} is not supported. Minimum required version is v1.29."
    exit 1
  fi

  echo "Kubernetes server is at least v1.29 (Detected v${major}.${minor}). Continuing..."
}

set_action() {
  if [ "$1" != "apply" ] && [ "$1" != "delete" ]; then
    echo "Invalid action. Use 'apply' or 'delete'."
    exit 1
  fi
  action=$1
}

# Create or delete the HF token secret.
manage_hf_secret() {
  if [ "$action" == "apply" ] && [ "$PROC_TYPE" == "gpu" ] && [ -z "$HF_TOKEN" ]; then
    echo "You must set HF_TOKEN to your Hugging Face token."
    exit 1
  fi

  if [ "$PROC_TYPE" == "gpu" ]; then
    if [ "$action" == "apply" ]; then
      if ! kubectl -n $NS get secret/hf-token > /dev/null 2>&1; then
        echo "Creating secret in namespace $NS..."
        kubectl -n $NS create secret generic hf-token --from-literal=token=$HF_TOKEN
      else
        echo "Secret hf-token in namespace $NS already exists."
      fi
    else
      if kubectl -n $NS get secret/hf-token > /dev/null 2>&1; then
        echo "Deleting secret in namespace $NS..."
        kubectl -n $NS delete secret/hf-token
      else
        echo "Secret hf-token in namespace $NS already deleted."
      fi
    fi
  fi
}

manage_ns() {
  if [ "$NS" == "default" ]; then
    echo "Namespace is 'default', skipping namespace management."
    return
  fi

  # Manage the user-provided namespace.
  if [ "$action" == "apply" ]; then
    if ! kubectl get namespace "$NS" > /dev/null 2>&1; then
      echo "Creating namespace $NS..."
      kubectl create namespace $NS
    else
    echo "Namespace $NS already exists."
    fi
  else
    echo "Deleting namespace $NS..."
    kubectl delete namespace $NS --force
  fi
}

manage_curl_pod() {
  if [ "$CURL_POD" == "true" ]; then
    if [ "$action" == "apply" ]; then
      echo "Ensuring curl client Pod is running in namespace $NS..."
      kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: curl
  labels:
    app: curl
spec:
  containers:
  - name: curl-client
    image: curlimages/curl
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh"]
    args: ["-c", "while true; do sleep 1000; done"]
EOF
      echo "Curl client Pod created successfully."

    elif [ "$action" == "delete" ]; then
      # Only delete if the Pod actually exists:
      if kubectl get po/curl -n "$NS" > /dev/null 2>&1; then
        echo "Deleting curl client Pod in namespace $NS..."
        kubectl delete po/curl -n "$NS" --force
      else
        echo "Curl client Pod does not exist in namespace $NS."
      fi
    fi
  fi
}

check_and_manage_metallb() {
  if [ "$METAL_LB" == "true" ]; then
    if [ "$action" == "apply" ]; then
      if ! kubectl get namespace metallb-system >/dev/null 2>&1; then
        echo "Namespace 'metallb-system' does not exist. Applying MetalLB configuration..."
        if ! ./scripts/metallb.sh apply; then
          echo "Error: Failed to apply MetalLB configuration."
          exit 1
        fi
        echo "MetalLB configuration applied successfully."
      else
        echo "MetalLB is already installed."
      fi
    elif [ "$action" == "delete" ]; then
      if kubectl get namespace metallb-system >/dev/null 2>&1; then
        echo "Namespace 'metallb-system' exists. Deleting MetalLB configuration..."
        if ! ./scripts/metallb.sh delete; then
          echo "Error: Failed to delete MetalLB configuration."
          exit 1
        fi
        echo "MetalLB configuration deleted successfully."
      fi
    fi
  fi
}

# Create or delete the model server Kubernetes resource.
manage_model_resources() {
  echo "Managing Kubernetes resources for model server with action: $action"

  # Set the vllm deployment manifest based on the processor type.
  url="https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/refs/tags/$INF_EXT_VERSION/config/manifests/vllm/gpu-deployment.yaml"
  if [ "$PROC_TYPE" != "gpu" ]; then
    url="https://gist.githubusercontent.com/danehans/d43c6b5bd706ba5ba356ec992cd31217/raw/80f004324735af51496df890ab48923ca02ca786/vllm_cpu_deployment.yaml"
  fi

  if [ "$action" == "apply" ]; then
    # Apply the model server resources
    kubectl -n "$NS" apply -f "$url"

    # Only scale if NUM_REPLICAS < 3
    if [ "$NUM_REPLICAS" -lt 3 ] || [ "$NUM_REPLICAS" -gt 3 ]; then
      echo "Scaling model server deployment to $NUM_REPLICAS replicas..."
      kubectl -n "$NS" scale deploy/my-pool --replicas="$NUM_REPLICAS"
    else
      echo "NUM_REPLICAS is $NUM_REPLICAS, which is not less than 3. Skipping scaling."
    fi
  else
    # Delete the model server resources
    kubectl -n "$NS" delete -f "$url"
  fi
}

# Create or delete the Kubernetes gateway resource
manage_gtw_resource() {
  echo "Managing Kubernetes Gateway resource with action: $action"
  kubectl -n $NS $action -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: inference-gateway
spec:
  gatewayClassName: kgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 8080
    - name: llm-gw
      protocol: HTTP
      port: 8081
EOF
}

# Create or delete the Kubernetes InferenceModel resource.
# TODO: Use upstream url when the manifests settle down.
manage_infmodel_resource() {
  echo "Managing InferenceModel resource with action: $action"
  kubectl $action -n $NS -f https://gist.githubusercontent.com/danehans/4e980e79402fbb6e6ff987c99b832dce/raw/d176cf648336d96e9b05f95645df607044d09816/inferencemodel.yaml
}

# Create or delete the Kubernetes InferencePool resource.
manage_infpool_resource() {
  echo "Managing InferencePool resource..."
  kubectl $action -n $NS -f - <<EOF
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferencePool
metadata:
  name: my-pool
spec:
  targetPortNumber: 8000
  selector:
    app: my-pool
  extensionRef:
    name: my-pool-endpoint-picker
EOF
}

# Create or delete the Kubernetes httproute resource
manage_httproute_resource() {
  echo "Managing HTTPRoute resource..."
  kubectl $action -n $NS -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: inference-gateway
    sectionName: llm-gw
  rules:
  - backendRefs:
    - group: inference.networking.x-k8s.io
      kind: InferencePool
      name: my-pool
      port: 8000
      weight: 1
    matches:
    - path:
        type: PathPrefix
        value: /
    timeouts:
      backendRequest: 24h
      request: 24h
EOF
}

test_kgtw_connectivity() {
  echo "Testing connectivity through gateway/inference-gateway..."

  retries=0
  gtw_ip=""

  while [ $retries -lt $MAX_RETRIES ]; do
    echo "Fetching the IP for gateway/inference-gateway ..."
    gtw_ip=$(kubectl get gateway/inference-gateway -n "$NS" -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$gtw_ip" ]; then
      echo "Attempt $((retries + 1)): Failed to get gateway/inference-gateway IP. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep "$BACKOFF_TIME"
    else
      echo "Gateway address (IP or DNS): $gtw_ip"
      break
    fi
  done

  if [ -z "$gtw_ip" ]; then
    echo "Failed to get gateway/inference-gateway address after $retries retries."
    return 1
  fi

  # Check if $gtw_ip is an IP or DNS
  # Quick test: "Does $gtw_ip match a simple IPv4 pattern?"
  # If NOT, then treat it as DNS
  if ! [[ $gtw_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$gtw_ip looks like a DNS name. Trying to resolve..."

    dns_retries=0
    while [ $dns_retries -lt $MAX_RETRIES ]; do
      if dig +short "$gtw_ip" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; then
        echo "DNS resolution for '$gtw_ip' succeeded."
        break
      else
        echo "Attempt $((dns_retries + 1)): DNS resolution failed. Retrying in $BACKOFF_TIME seconds..."
        dns_retries=$((dns_retries + 1))
        sleep "$BACKOFF_TIME"
      fi
    done

    if [ $dns_retries -eq $MAX_RETRIES ]; then
      echo "Failed to resolve DNS name '$gtw_ip' after $dns_retries retries."
      return 1
    fi
  fi

  # At this point, $gtw_ip is either a valid IP or a DNS name that resolves.
  # Optional: Attempt a curl connectivity check
  echo "Attempting connectivity via curl..."
  curl_retries=0
  data='{"model": "tweet-summary","prompt": "Write as if you were a critic: San Francisco","max_tokens": 100,"temperature": 0}'
  while [ $curl_retries -lt $MAX_RETRIES ]; do
    if [ "$CURL_POD" == "true" ]; then
      echo "Using curl Pod to test connectivity..."
      response=$(kubectl exec -n $NS po/curl -- curl -i "$gtw_ip:8081/v1/completions" -H 'Content-Type: application/json' -d "$data")
    else
      response=$(curl -i "$gtw_ip:8081/v1/completions" -H 'Content-Type: application/json' -d "$data")
    fi

    if echo "$response" | grep -q "HTTP/1.1 200 OK"; then
      echo "Connection successful! Received HTTP 200 OK."
      echo ""
      echo "Try for yourself with the following command:"
      echo "kubectl exec po/curl -- curl -i \"$gtw_ip:8081/v1/completions\" -H 'Content-Type: application/json' -d '$data'"
      return 0
    else
      echo "Attempt $((retries + 1)): Did not receive HTTP 200 OK. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    fi
  done

  echo "Failed to connect to $gtw_ip after $curl_retries retries."
  return 1
}

main() {
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  set_action "$1"

  if [ "$action" = "apply" ]; then
    check_k8s_version
    manage_ns
  fi

  manage_hf_secret

  check_and_manage_metallb

  manage_curl_pod

  manage_gtw_resource

  manage_model_resources

  manage_infmodel_resource

  manage_infpool_resource

  manage_httproute_resource

  if [ "$action" = "apply" ]; then
    deploy_rollout_status "my-pool" $NS

    check_gateway_status "inference-gateway" $NS

    check_httproute_status "llm-route" $NS

    test_kgtw_connectivity
  fi

  if [ "$action" = "delete" ]; then
    manage_ns
  fi
}

main "$@"
