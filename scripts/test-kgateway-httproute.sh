#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# Set default values
BACKOFF_TIME=${BACKOFF_TIME:-5}
MAX_RETRIES=${MAX_RETRIES:-12}
NS=${NS:-default}
# CURL_POD defines whether to use a curl pod as a client to test connectivity.
CURL_POD=${CURL_POD:-true}
# NUM_REPLICAS defines the number of replicas to use for the httpbin backend deployment.
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
    elif kubectl get po/curl "$NS" > /dev/null 2>&1; then
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

# Create or delete the httpbin Kubernetes resources.
manage_httpbin_resources() {
  echo "Managing Kubernetes resources for httpbin app with action: $action"

  if [ "$action" == "apply" ]; then
    # Apply the httpbin resources
    kubectl -n $NS apply -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/policy-demo/httpbin.yaml
    # Scale the deployment down
    echo "Scaling httpbin deployment to $NUM_REPLICAS replicas..."
    kubectl -n $NS scale deploy/httpbin --replicas=$NUM_REPLICAS
  else
    # Delete the httpbin resources
    kubectl -n $NS delete -f https://raw.githubusercontent.com/solo-io/gloo-mesh-use-cases/main/policy-demo/httpbin.yaml --force
  fi
}

# Create or delete the Kubernetes gateway resource
manage_gtw_resource() {
  echo "Managing Kubernetes Gateway resource with action: $action"
  kubectl -n $NS $action -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: http
spec:
  gatewayClassName: kgateway
  listeners:
  - protocol: HTTP
    port: 8080
    name: http
    allowedRoutes:
      namespaces:
        from: All
EOF
}

# Create or delete the Kubernetes httproute resource
manage_httproute_resource() {
  echo "Managing Kubernetes HTTPRoute resource..."
  kubectl $action -n $NS -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: httpbin
  labels:
    example: httpbin-route
spec:
  parentRefs:
    - name: http
      namespace: $NS
  hostnames:
    - "www.example.com"
  rules:
    - backendRefs:
        - name: httpbin
          port: 8000
EOF
}

test_kgtw_connectivity() {
  echo "Testing HTTP connectivity through Kgateway..."

  retries=0
  gtw_ip=""

  while [ $retries -lt $MAX_RETRIES ]; do
    echo "Fetching the IP for gateway/http ..."
    gtw_ip=$(kubectl get gateway/http -n $NS -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$gtw_ip" ]; then
      echo "Attempt $((retries + 1)): Failed to get gateway/http IP. Retrying in $BACKOFF_TIME seconds..."
      retries=$((retries + 1))
      sleep $BACKOFF_TIME
    else
      echo "Gateway IP: $gtw_ip"
      break
    fi
  done

  if [ -z "$gtw_ip" ]; then
    echo "Failed to get gateway/http IP after $retries retries."
    return 1
  fi

  retries=0
  sleep $BACKOFF_TIME

  while [ $retries -lt $MAX_RETRIES ]; do
    if [ "$CURL_POD" == "true" ]; then
      echo "Using curl Pod to test connectivity..."
      response=$(kubectl exec -n $NS po/curl -- curl -s -H "host: www.example.com:8080" http://$gtw_ip:8080/headers)
    else
      response=$(curl -s -H "host: www.example.com:8080" http://$gtw_ip:8080/headers)
    fi

    if echo "$response" | grep -q "www.example.com:8080"; then
      echo "Connection successful! Response includes 'www.example.com:8080'."
      return 0
    else
      echo "Attempt $((retries + 1)): Response does not include 'www.example.com:8080'. Retrying in $BACKOFF_TIME seconds..."
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

  manage_gateway_parameters

  check_and_manage_metallb

  manage_curl_pod

  manage_gtw_resource

  manage_httpbin_resources

  manage_httproute_resource

  if [ "$action" = "apply" ]; then
    deploy_rollout_status "httpbin" $NS

    check_gateway_status "http" $NS

    check_httproute_status "httpbin" $NS

    test_kgtw_connectivity
  fi

  if [ "$action" = "delete" ]; then
    manage_ns
  fi
}

main "$@"
