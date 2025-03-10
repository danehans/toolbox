#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# Set default values
BACKOFF_TIME=${BACKOFF_TIME:-5}
MAX_RETRIES=${MAX_RETRIES:-12}
NS=${NS:-default}
HF_TOKEN=${HF_TOKEN:-""}
# CURL_POD defines whether to use a curl pod as a client to test connectivity.
CURL_POD=${CURL_POD:-true}
# NUM_REPLICAS defines the number of replicas to use for the model server backend deployment.
NUM_REPLICAS=${NUM_REPLICAS:-1}

# Check if required CLI tools are installed.
for cmd in kubectl helm; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

set_action() {
  if [ "$1" != "apply" ] && [ "$1" != "delete" ]; then
    echo "Invalid action. Use 'apply' or 'delete'."
    exit 1
  fi
  action=$1
}

# Create or delete the HF token secret.
manage_hf_secret() {
  if [ "$HF_TOKEN" == "" ]; then
    echo "You must set HF_TOKEN to your Hugging Face token."
    exit 1
  fi

  if [ "$action" == "apply" ]; then
    if ! kubectl -n $NS get secret/hf-token > /dev/null 2>&1; then
      echo "Creating secret in namespace $NS..."
      kubectl -n $NS create secret generic hf-token --from-literal=token=$HF_TOKEN
    else
      echo "Secret hf-token in namespace $NS already exists."
    fi
  else
    echo "Deleting secret in namespace $NS..."
    kubectl -n $NS delete secret/hf-token
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
      kubectl apply -n $NS -f - <<EOF
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
    else
      echo "Deleting curl client Pod in namespace $NS..."
      kubectl delete po/curl -n $NS --force
    fi
  fi
}

check_and_manage_metallb() {
  if [ "$CURL_POD" == "false" ]; then
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

manage_gateway_parameters() {
  if [ "$CURL_POD" == "true" ]; then
    echo "Managing GatewayParameters for Kgateway..."
    service_type="LoadBalancer"
    if [ "$action" == "apply" ]; then
      service_type="ClusterIP"
    fi
    kubectl patch gwp/kgateway -n kgateway-system --type='merge' -p "
spec:
  kube:
    service:
      type: ${service_type}
  "
    echo "GatewayParameters updated: spec.kube.service.type=${service_type}"
  fi
}

# Create or delete the model server Kubernetes resource.
manage_model_resources() {
  echo "Managing Kubernetes resources for model server with action: $action"

  if [ "$action" == "apply" ]; then
    # Apply the model server resources
    kubectl -n $NS apply -f https://gist.githubusercontent.com/danehans/d43c6b5bd706ba5ba356ec992cd31217/raw/f149cc470291e47de676c48fb5481f805d8ec909/vllm_llama_deployment.yaml
    # Scale the deployment down
    echo "Scaling model server deployment to $NUM_REPLICAS replicas..."
    kubectl -n $NS scale deploy/vllm-llama2-7b-pool --replicas=$NUM_REPLICAS
  else
    # Delete the model server resources
    kubectl -n $NS delete -f https://gist.githubusercontent.com/danehans/d43c6b5bd706ba5ba356ec992cd31217/raw/f149cc470291e47de676c48fb5481f805d8ec909/vllm_llama_deployment.yaml
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

# Create or delete the Kubernetes InferenceModel resource
manage_infmodel_resource() {
  echo "Managing InferenceModel resource with action: $action"
  kubectl $action -n $NS -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api-inference-extension/refs/tags/$INF_EXT_VERSION/pkg/manifests/inferencemodel.yaml
}

# Create or delete the Kubernetes InferencePool resource.
manage_infpool_resource() {
  api_ver="v1alpha2"
  if [ "$INF_EXT_VERSION" == "v0.1.0" ]; then
    api_ver="v1alpha1"
  fi
  echo "Managing Kubernetes InferencePool resource..."
  kubectl $action -n $NS -f - <<EOF
apiVersion: inference.networking.x-k8s.io/${api_ver}
kind: InferencePool
metadata:
  name: vllm-llama2-7b-pool
spec:
  targetPortNumber: 8000
  selector:
    app: vllm-llama2-7b-pool
  extensionRef:
    name: vllm-llama2-7b-pool-endpoint-picker
EOF
}

# Create or delete the Kubernetes httproute resource
manage_httproute_resource() {
  echo "Managing Kubernetes HTTPRoute resource..."
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
      name: vllm-llama2-7b-pool
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
    gtw_ip=$(kubectl get gateway/inference-gateway -n $NS -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$gtw_ip" ]; then
      echo "Attempt $((retries + 1)): Failed to get gateway/inference-gateway IP. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    else
      echo "Gateway IP: $gtw_ip"
      break
    fi
  done

  if [ -z "$gtw_ip" ]; then
    echo "Failed to get gateway/inference-gateway IP after $retries retries."
    return 1
  fi

  retries=0
  sleep $BACKOFF_TIME
  data='{"model": "tweet-summary","prompt": "Write as if you were a critic: San Francisco","max_tokens": 100,"temperature": 0}'

  while [ $retries -lt $MAX_RETRIES ]; do
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

  echo "Failed to connect after $retries retries."
  return 1
}

main() {
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  set_action "$1"

  if [ "$action" = "apply" ]; then
    manage_ns
  fi

  manage_hf_secret

  manage_gateway_parameters

  check_and_manage_metallb

  manage_curl_pod

  manage_gtw_resource

  manage_model_resources

  manage_infmodel_resource

  manage_infpool_resource

  manage_httproute_resource

  if [ "$action" = "apply" ]; then
    deploy_rollout_status "vllm-llama2-7b-pool" $NS

    check_gateway_status "inference-gateway" $NS

    check_httproute_status "llm-route" $NS

    test_kgtw_connectivity
  fi

  if [ "$action" = "delete" ]; then
    manage_ns
  fi
}

main "$@"
