#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# Set default back-off time, max retries, and namespace
BACKOFF_TIME=${BACKOFF_TIME:-5}
MAX_RETRIES=${MAX_RETRIES:-12}
NS=${NS:-default}  # User-facing namespace variable, defaults to "default"
CURL_SUCCESS_COUNT=0

# Check if required CLI tools are installed.
for cmd in kubectl kind; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# Validate input argument
set_action() {
  if [ "$1" != "apply" ] && [ "$1" != "delete" ]; then
    echo "Invalid action. Use 'apply' or 'delete'."
    exit 1
  fi
  action=$1
}

# Manage the Kubernetes namespace (create or delete)
manage_namespace() {
  if [ "$NS" != "default" ]; then
    if [ "$action" = "apply" ]; then
      # Check if namespace exists, and create it if it doesn't
      if ! kubectl get namespace $NS >/dev/null 2>&1; then
        echo "Namespace $NS does not exist. Creating namespace $NS..."
        kubectl create namespace $NS
      else
        echo "Namespace $NS already exists."
      fi
    elif [ "$action" = "delete" ]; then
      # Delete namespace if it exists
      if kubectl get namespace $NS >/dev/null 2>&1; then
        echo "Deleting namespace $NS..."
        kubectl delete namespace $NS
      else
        echo "Namespace $NS does not exist."
      fi
    fi
  else
    echo "Namespace is 'default', skipping namespace management."
  fi
}

# Create the Kubernetes resources
manage_k8s_resources() {
  echo "Applying Kubernetes test app resources..."
  kubectl apply -n $NS -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: server
---
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels:
    app: server
spec:
  serviceAccountName: server
  containers:
  - name: server
    image: kennethreitz/httpbin
    imagePullPolicy: IfNotPresent
    ports:
    - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: server
  labels:
    app: server
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 80
    targetPort: 80
  selector:
    app: server
EOF
}

# Wait for server pod to be ready
wait_for_pods() {
  echo "Waiting for server pod to be in Running state..."
  kubectl wait --for=condition=Ready pod/server --namespace="$NS" --timeout=180s
}

# Test connectivity
test_connectivity() {
  echo "Testing connectivity through LoadBalancer to server..."

  # Fetch the service LoadBalancer IP
  echo "Fetching the service LoadBalancer IP..."
  svc_ip=$(kubectl get svc server -n $NS -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

  if [ -z "$svc_ip" ]; then
    echo "Failed to get the LoadBalancer IP. Service might not be ready yet."
    exit 1
  fi

  echo "Service LoadBalancer IP: $svc_ip"

  retries=0
  until curl -s http://$svc_ip/ip; do
    if [ $retries -ge $MAX_RETRIES ]; then
      echo "Failed to connect after $retries retries."
      exit 1
    fi

    echo "Attempt $((retries + 1)) failed. Retrying in $BACKOFF_TIME seconds..."
    sleep $BACKOFF_TIME
    retries=$((retries + 1))
  done

  # Increment success count only when the request is successful
  CURL_SUCCESS_COUNT=$((CURL_SUCCESS_COUNT + 1))
  echo "Connection successful!"
}

main() {
  # Validate inputs
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  # Set action and validate
  set_action "$1"

  # Manage the namespace
  manage_namespace

  if [ "$action" = "apply" ]; then
    # Create k8s test app resources
    manage_k8s_resources

    # Wait for test app pods to be ready
    wait_for_pods

    # Test connectivity using load balancer service
    test_connectivity
  fi
}

# Execute main function
main "$@"
