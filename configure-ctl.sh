#!/bin/bash
set -euo pipefail

# This script sets up kubectl on the local machine for remote access to the Kubernetes cluster.
# It copies the kubeconfig from the master node and configures the kubectl context.

# parameters
# $1: SSH user on the master node
# $2: Master node IP address
# $3: SSH key path (optional, default: ~/.ssh/id_rsa_cluster)
# $4: Context name (optional, default: read from cluster.yml or "kubernetes")

## 0. Validate input parameters

if [ "$#" -lt 2 ]; then
    echo "ERROR: This script requires at least 2 parameters."
    echo "Usage: $0 <ssh_user> <master_ip> [ssh_key_path] [context_name]"
    exit 1
fi

SSH_USER="$1"
MASTER_IP="$2"
SSH_KEY_PATH="${3:-$HOME/.ssh/id_rsa_cluster}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/cluster.yml}"

# Try to read context name from cluster.yml, fall back to parameter or default
if [ -n "${4:-}" ]; then
    CONTEXT_NAME="$4"
elif [ -f "$CONFIG_FILE" ] && command -v yq &> /dev/null; then
    CONTEXT_NAME="$(yq -r '.cluster_name // "kubernetes"' "$CONFIG_FILE")"
else
    CONTEXT_NAME="kubernetes"
fi

if [ -z "$SSH_USER" ] || [ -z "$MASTER_IP" ]; then
    echo "ERROR: SSH user and master IP must be non-empty."
    exit 1
fi

# Validate IP address format
if ! echo "$MASTER_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "ERROR: Invalid IP address format: $MASTER_IP"
    exit 1
fi

# Check that kubectl is installed locally
if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed on this machine."
    echo "Install it from: https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    exit 1
fi

echo "=== Configuring kubectl for remote cluster access ==="
echo "Master node: $SSH_USER@$MASTER_IP"
echo "SSH key:     $SSH_KEY_PATH"
echo "Context:     $CONTEXT_NAME"
echo ""

## 1. Fetch kubeconfig from the master node

echo "--- Step 1: Fetching kubeconfig from master node ---"

KUBE_DIR="$HOME/.kube"
REMOTE_KUBECONFIG="/etc/kubernetes/admin.conf"
LOCAL_KUBECONFIG="${KUBE_DIR}/config-${CONTEXT_NAME}"

mkdir -p "$KUBE_DIR"

scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${MASTER_IP}:${REMOTE_KUBECONFIG}" "$LOCAL_KUBECONFIG" 2>/dev/null || \
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${MASTER_IP}" \
    "sudo cat ${REMOTE_KUBECONFIG}" > "$LOCAL_KUBECONFIG"

echo "Kubeconfig downloaded to: $LOCAL_KUBECONFIG"

## 2. Update the server address to use the external master IP

echo "--- Step 2: Updating API server address ---"

# Replace the internal API server address with the master node's IP
sed -i.bak "s|server: https://.*:6443|server: https://${MASTER_IP}:6443|g" "$LOCAL_KUBECONFIG"
rm -f "${LOCAL_KUBECONFIG}.bak"

echo "API server address updated to: https://${MASTER_IP}:6443"

## 3. Set up kubectl context

echo "--- Step 3: Configuring kubectl context ---"

# Check if a kubeconfig already exists
if [ -f "${KUBE_DIR}/config" ]; then
    echo "Existing kubeconfig found. Merging configurations..."

    # Backup existing config
    cp "${KUBE_DIR}/config" "${KUBE_DIR}/config.backup.$(date +%Y%m%d%H%M%S)"

    # Merge kubeconfigs
    KUBECONFIG="${KUBE_DIR}/config:${LOCAL_KUBECONFIG}" kubectl config view --flatten > "${KUBE_DIR}/config.merged"
    mv "${KUBE_DIR}/config.merged" "${KUBE_DIR}/config"

    echo "Kubeconfig merged."
else
    cp "$LOCAL_KUBECONFIG" "${KUBE_DIR}/config"
    echo "Kubeconfig installed."
fi

# Set file permissions
chmod 600 "${KUBE_DIR}/config"

## 4. Rename context for clarity

echo "--- Step 4: Setting kubectl context ---"

# Get the current context name from the downloaded config
CURRENT_CONTEXT="$(kubectl --kubeconfig="$LOCAL_KUBECONFIG" config current-context)"

# Rename the context if needed
if [ "$CURRENT_CONTEXT" != "$CONTEXT_NAME" ]; then
    kubectl config rename-context "$CURRENT_CONTEXT" "$CONTEXT_NAME" 2>/dev/null || true
fi

# Set the active context
kubectl config use-context "$CONTEXT_NAME"

echo "Active context set to: $CONTEXT_NAME"

## 5. Verify connectivity

echo ""
echo "--- Step 5: Verifying cluster connectivity ---"

echo "Testing connection to the cluster..."

if kubectl cluster-info --context="$CONTEXT_NAME" 2>/dev/null; then
    echo ""
    echo "PASS: Successfully connected to the cluster."
else
    echo ""
    echo "WARNING: Could not connect to the cluster."
    echo "Possible causes:"
    echo "  - The master node ($MASTER_IP) is not reachable from this machine"
    echo "  - Port 6443 is not open on the master node firewall"
    echo "  - The cluster is not running"
    echo ""
    echo "Kubeconfig has been saved. You can retry with:"
    echo "  kubectl --context=$CONTEXT_NAME cluster-info"
    exit 1
fi

echo ""
echo "=== kubectl configuration complete ==="
echo ""
echo "You can now use kubectl to manage the cluster:"
echo "  kubectl get nodes"
echo "  kubectl get pods --all-namespaces"
echo ""
echo "To switch contexts:"
echo "  kubectl config use-context $CONTEXT_NAME"
echo ""
echo "Kubeconfig file:  ${KUBE_DIR}/config"
echo "Cluster config:   $LOCAL_KUBECONFIG"
