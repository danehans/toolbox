#!/usr/bin/env bash

set -e

# Source the utility functions.
source ./scripts/utils.sh

# The stats key to check for the waypoint proxy.
WAYPOINT_STATS_KEY="http.inbound_0.0.0.0_80;.rbac.allowed"
CURL_SUCCESS_COUNT=0

# Validate input argument
set_action() {
  if [ "$1" != "apply" ] && [ "$1" != "delete" ]; then
    echo "Invalid action. Use 'apply' or 'delete'."
    exit 1
  fi
  action=$1
}

# Check if required CLI tools are installed.
for cmd in kubectl istioctl; do
  if ! command_exists $cmd; then
    echo "$cmd is not installed. Please install $cmd before running this script."
    exit 1
  fi
done

# If istioctl is installed, check its version
check_istio_version

# Function to find client and server nodes
set_nodes() {
  nodes=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name,:metadata.labels")
  client_node=""
  server_node=""

  i=0
  while read -r line; do
    node=$(echo "$line" | cut -d ' ' -f 1)
    labels=$(echo "$line" | cut -d ' ' -f 2-)

    if [[ ! "$labels" =~ "node-role.kubernetes.io/control-plane" ]]; then
      if [ $i -eq 0 ]; then
        client_node=$node
      elif [ $i -eq 1 ]; then
        server_node=$node
        break
      fi
      i=$((i + 1))
    fi
  done <<< "$nodes"

  if [ -z "$client_node" ] || [ -z "$server_node" ]; then
    echo "Could not find sufficient worker nodes."
    exit 1
  fi

  echo "Client Node: $client_node"
  echo "Server Node: $server_node"
}

# Ensure the namespace exists and manage labels
manage_namespace_labels() {
  if [ "$NS" != "default" ]; then
    echo "Checking if namespace $NS exists..."
    if ! kubectl get namespace "$NS" &>/dev/null; then
      echo "Namespace $NS does not exist. Creating it..."
      kubectl create namespace "$NS"
    fi
  fi

  if [ "$action" = "apply" ]; then
    echo "Labeling namespace $NS with istio.io/dataplane-mode=ambient and istio.io/use-waypoint=waypoint..."
    kubectl label namespace "$NS" istio.io/dataplane-mode=ambient --overwrite
    kubectl label namespace "$NS" istio.io/use-waypoint=waypoint --overwrite
  elif [ "$action" = "delete" ]; then
    echo "Removing labels from namespace $NS: istio.io/dataplane-mode and istio.io/use-waypoint..."
    kubectl label namespace "$NS" istio.io/dataplane-mode- --overwrite
    kubectl label namespace "$NS" istio.io/use-waypoint- --overwrite
  fi
}

# Apply or delete the waypoint
manage_waypoint() {
  if [ "$action" = "apply" ]; then
    echo "Applying Istio waypoint..."
    istioctl waypoint apply --namespace "$NS" --wait
  elif [ "$action" = "delete" ]; then
    echo "Deleting Istio waypoint..."
    istioctl waypoint delete waypoint --namespace "$NS"
  fi
}

# Create or delete Kubernetes resources
manage_k8s_resources() {
  echo "Managing Kubernetes resources with action: $action"
  kubectl $action -n $NS -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: client
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
spec:
  serviceAccountName: client
  containers:
  - name: curl-client
    image: curlimages/curl
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh"]
    args: ["-c", "while true; do sleep 1000; done"]
  nodeSelector:
    kubernetes.io/hostname: $client_node
---
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
  nodeSelector:
    kubernetes.io/hostname: $server_node
---
apiVersion: v1
kind: Service
metadata:
  name: server
  labels:
    app: server
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    targetPort: 80
  selector:
    app: server
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: server
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: server
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/$NS/sa/client
    to:
    - operation:
        methods: ["GET"]
EOF
}

# Wait for client and server pods to be running
wait_for_pods() {
  echo "Waiting for client and server pods to be in Running state..."
  kubectl wait --for=condition=Ready pod/client --namespace="$NS" --timeout=180s
  kubectl wait --for=condition=Ready pod/server --namespace="$NS" --timeout=180s
}

# Test connectivity
test_connectivity() {
  echo "Testing connectivity between client and server..."

  retries=0
  success=false
  until kubectl exec po/client --namespace="$NS" -- curl -s http://server.$NS.svc.cluster.local/ip; do
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

# Check waypoint deployment stats
check_waypoint_stats() {
  echo "Checking waypoint stats..."

  retries=0
  while [ $retries -lt $MAX_RETRIES ]; do
    # Get the $WAYPOINT_STATS_KEY value from the waypoint deployment
    allowed_value=$(kubectl exec deployment/waypoint -n "$NS" -c istio-proxy -- pilot-agent request GET stats | grep "$WAYPOINT_STATS_KEY" | awk '{print $2}')

    # Check if stat is empty
    if [ -z "$allowed_value" ]; then
      echo "No stats found for $WAYPOINT_STATS_KEY. Retrying in $BACKOFF_TIME seconds..."
      sleep $BACKOFF_TIME
      retries=$((retries + 1))
      continue
    fi

    # Check if the stat value matches the successful curl request count
    if [ "$allowed_value" -eq "$CURL_SUCCESS_COUNT" ]; then
      echo "Waypoint stat key '$WAYPOINT_STATS_KEY' is correct: $allowed_value successful requests recorded."
      return 0
    else
      echo "Mismatch in stats. Expected $CURL_SUCCESS_COUNT, but waypoint reports $allowed_value."
      exit 1
    fi
  done

  echo "Failed to retrieve the expected waypoint stats after $MAX_RETRIES retries."
  exit 1
}

main() {
  # Validate inputs
  if [ $# -ne 1 ]; then
    echo "Usage: $0 [apply|delete]"
    exit 1
  fi

  # Set action and validate
  set_action "$1"

  # Ensure namespace and manage labels
  manage_namespace_labels

  # Set client and server nodes
  set_nodes

  # Manage Istio waypoint
  manage_waypoint

  # Create or delete k8s resources
  manage_k8s_resources

  if [ "$action" = "apply" ]; then
    # Wait for pods to be ready
    wait_for_pods

    # Test connectivity
    test_connectivity

    # Check waypoint stats
    check_waypoint_stats
  elif [ "$action" = "delete" ] && [ "$NS" != "default" ]; then
    echo "Deleting namespace $NS..."
    kubectl delete namespace "$NS"
  fi
}

# Execute main function
main "$@"
