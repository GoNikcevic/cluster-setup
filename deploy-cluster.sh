#!/bin/bash
set -euo pipefail

# This script orchestrates the full Kubernetes cluster deployment.
# It reads configuration from cluster.yml and executes the setup steps in order:
#   1. Prepare all VMs (master + workers)
#   2. Generate and distribute SSH keys
#   3. Install the Kubernetes cluster engine on the master node
#   4. Join worker nodes to the cluster
#   5. Verify cluster health

# The script is intended to be run from the control host (your local machine or a bastion host).

# parameters (via environment variables)
# CONFIG_FILE:  Path to cluster.yml (default: ./cluster.yml)
# SSH_PASSWORD: Password for initial SSH connections (before key-based auth is set up)
# SKIP_PREPARE: Set to "true" to skip VM preparation (default: false)
# SKIP_VERIFY:  Set to "true" to skip cluster verification (default: false)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/cluster.yml}"

## 0. Validate prerequisites

echo "=== Kubernetes Cluster Deployment ==="
echo ""

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    echo "Run create-cluster-config.sh first to generate the configuration."
    exit 1
fi

# Check for required tools
for TOOL in ssh scp yq; do
    if ! command -v "$TOOL" &> /dev/null; then
        echo "ERROR: Required tool '$TOOL' is not installed."
        echo "Install yq with: sudo apt-get install -y yq  (or: pip install yq)"
        exit 1
    fi
done

## 1. Parse cluster configuration

echo "--- Step 1: Parsing cluster configuration ---"

CLUSTER_NAME="$(yq -r '.cluster_name' "$CONFIG_FILE")"
KUBERNETES_VERSION="$(yq -r '.kubernetes_version' "$CONFIG_FILE")"
SSH_USER="$(yq -r '.ssh.user' "$CONFIG_FILE")"
SSH_KEY_PATH="$(yq -r '.ssh.key_path' "$CONFIG_FILE")"
MASTER_IP="$(yq -r '.master.ip' "$CONFIG_FILE")"
MASTER_HOSTNAME="$(yq -r '.master.hostname' "$CONFIG_FILE")"
POD_CIDR="$(yq -r '.network.pod_cidr' "$CONFIG_FILE")"
SERVICE_CIDR="$(yq -r '.network.service_cidr' "$CONFIG_FILE")"

# Parse worker nodes
WORKER_COUNT="$(yq -r '.workers | length' "$CONFIG_FILE")"
WORKER_IPS=()
WORKER_HOSTNAMES=()
for (( i=0; i<WORKER_COUNT; i++ )); do
    WORKER_IPS+=("$(yq -r ".workers[$i].ip" "$CONFIG_FILE")")
    WORKER_HOSTNAMES+=("$(yq -r ".workers[$i].hostname" "$CONFIG_FILE")")
done

# Expand tilde in SSH_KEY_PATH
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

echo "Cluster name:       $CLUSTER_NAME"
echo "Kubernetes version: $KUBERNETES_VERSION"
echo "Master node:        $MASTER_HOSTNAME ($MASTER_IP)"
echo "Worker nodes:       $WORKER_COUNT"
for (( i=0; i<WORKER_COUNT; i++ )); do
    echo "                    ${WORKER_HOSTNAMES[$i]} (${WORKER_IPS[$i]})"
done
echo "Pod CIDR:           $POD_CIDR"
echo "Service CIDR:       $SERVICE_CIDR"
echo ""

## 2. Generate and distribute SSH keys

echo "--- Step 2: Generating and distributing SSH keys ---"

"$SCRIPT_DIR/generate-ssh-keys.sh" "$SSH_USER" "$MASTER_IP" "${WORKER_IPS[@]}"

echo ""

## 3. Prepare all VMs

if [ "${SKIP_PREPARE:-false}" = "true" ]; then
    echo "--- Step 3: Skipping VM preparation (SKIP_PREPARE=true) ---"
else
    echo "--- Step 3: Preparing all VMs ---"

    ALL_IPS=("$MASTER_IP" "${WORKER_IPS[@]}")
    ALL_HOSTNAMES=("$MASTER_HOSTNAME" "${WORKER_HOSTNAMES[@]}")

    for (( i=0; i<${#ALL_IPS[@]}; i++ )); do
        NODE_IP="${ALL_IPS[$i]}"
        NODE_HOSTNAME="${ALL_HOSTNAMES[$i]}"

        echo ""
        echo "Preparing node: $NODE_HOSTNAME ($NODE_IP)"

        # Set the hostname on the remote node
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE_IP}" \
            "sudo hostnamectl set-hostname $NODE_HOSTNAME"

        # Copy and execute prepare-vm.sh on the remote node
        scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
            "$SCRIPT_DIR/prepare-vm.sh" "${SSH_USER}@${NODE_IP}:/tmp/prepare-vm.sh"

        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${NODE_IP}" \
            "chmod +x /tmp/prepare-vm.sh && /tmp/prepare-vm.sh '$SSH_USER' '${SSH_PASSWORD:-changeme}' '$SSH_USER' '$MASTER_IP'"

        echo "Node $NODE_HOSTNAME ($NODE_IP) prepared."
    done
fi

echo ""

## 4. Install Kubernetes on the master node

echo "--- Step 4: Installing Kubernetes cluster engine on master node ---"

scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
    "$SCRIPT_DIR/install-cluster-engine.sh" "${SSH_USER}@${MASTER_IP}:/tmp/install-cluster-engine.sh"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${MASTER_IP}" \
    "chmod +x /tmp/install-cluster-engine.sh && \
     export IPADDR='$MASTER_IP' && \
     export POD_CIDR='$POD_CIDR' && \
     export NODENAME='$MASTER_HOSTNAME' && \
     export KUBERNETES_VERSION='$KUBERNETES_VERSION' && \
     /tmp/install-cluster-engine.sh"

echo "Kubernetes cluster engine installed on master node."
echo ""

## 5. Join worker nodes to the cluster

echo "--- Step 5: Joining worker nodes to the cluster ---"

# Retrieve the join command from the master node
JOIN_COMMAND="$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${MASTER_IP}" \
    "cat /tmp/join-command.sh")"

if [ -z "$JOIN_COMMAND" ]; then
    echo "ERROR: Failed to retrieve join command from master node."
    exit 1
fi

echo "Join command retrieved from master."

for (( i=0; i<WORKER_COUNT; i++ )); do
    WORKER_IP="${WORKER_IPS[$i]}"
    WORKER_HOSTNAME="${WORKER_HOSTNAMES[$i]}"

    echo ""
    echo "Joining worker node: $WORKER_HOSTNAME ($WORKER_IP)"

    # Install kubelet and kubeadm on the worker node
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${WORKER_IP}" \
        "export KUBERNETES_VERSION='$KUBERNETES_VERSION' && \
         sudo mkdir -p /etc/apt/keyrings && \
         curl -fsSL https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg && \
         echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list && \
         sudo apt-get update -y && \
         sudo apt-get install -y kubelet kubeadm && \
         sudo apt-mark hold kubelet kubeadm && \
         sudo systemctl enable kubelet && \
         sudo systemctl start kubelet"

    # Execute the join command on the worker node
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${WORKER_IP}" \
        "sudo $JOIN_COMMAND"

    echo "Worker node $WORKER_HOSTNAME ($WORKER_IP) joined the cluster."
done

echo ""

## 6. Verify cluster health

if [ "${SKIP_VERIFY:-false}" = "true" ]; then
    echo "--- Step 6: Skipping cluster verification (SKIP_VERIFY=true) ---"
else
    echo "--- Step 6: Verifying cluster health ---"

    "$SCRIPT_DIR/verify-cluster.sh" "$SSH_USER" "$MASTER_IP" "$SSH_KEY_PATH"
fi

echo ""
echo "=== Kubernetes cluster deployment complete ==="
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Master:  $MASTER_HOSTNAME ($MASTER_IP)"
echo "Workers: $WORKER_COUNT node(s)"
echo ""
echo "To configure kubectl on your local machine, run:"
echo "  ./configure-ctl.sh $SSH_USER $MASTER_IP $SSH_KEY_PATH"
