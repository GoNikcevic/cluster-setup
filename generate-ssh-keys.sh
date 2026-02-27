#!/bin/bash
set -euo pipefail

# This script generates an SSH key pair for cluster communication and distributes the public key to all cluster nodes.
# It is intended to be run from the machine that will orchestrate the cluster deployment (the control host).

# The script ensures passwordless SSH access from the control host to all master and worker nodes,
# which is required for remote execution of cluster setup scripts.

# parameters
# $1: SSH user on the remote nodes
# $2: master node IP address
# $3+: worker node IP addresses (one or more)

## 0. Validate input parameters

if [ "$#" -lt 3 ]; then
    echo "ERROR: This script requires at least 3 parameters."
    echo "Usage: $0 <ssh_user> <master_ip> <worker_ip_1> [worker_ip_2] ..."
    exit 1
fi

SSH_USER="$1"
MASTER_IP="$2"
shift 2
WORKER_IPS=("$@")

if [ -z "$SSH_USER" ] || [ -z "$MASTER_IP" ]; then
    echo "ERROR: SSH user and master IP must be non-empty."
    exit 1
fi

# Validate master IP address format
if ! echo "$MASTER_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "ERROR: Invalid IP address format for master: $MASTER_IP"
    exit 1
fi

# Validate worker IP address formats
for WORKER_IP in "${WORKER_IPS[@]}"; do
    if ! echo "$WORKER_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        echo "ERROR: Invalid IP address format for worker: $WORKER_IP"
        exit 1
    fi
done

SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa_cluster}"

echo "=== Generating SSH keys for cluster communication ==="
echo "SSH user: $SSH_USER"
echo "Master node: $MASTER_IP"
echo "Worker nodes: ${WORKER_IPS[*]}"
echo "Key path: $SSH_KEY_PATH"

## 1. Generate SSH key pair

echo "--- Step 1: Generating SSH key pair ---"

if [ -f "$SSH_KEY_PATH" ]; then
    echo "WARNING: SSH key already exists at $SSH_KEY_PATH"
    read -rp "Overwrite existing key? (y/N): " OVERWRITE
    if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
        echo "Using existing SSH key."
    else
        ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY_PATH" -C "cluster-setup-key"
        echo "New SSH key pair generated."
    fi
else
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_KEY_PATH" -C "cluster-setup-key"
    echo "SSH key pair generated."
fi

## 2. Distribute public key to the master node

echo "--- Step 2: Distributing public key to master node ($MASTER_IP) ---"

ssh-copy-id -i "${SSH_KEY_PATH}.pub" "${SSH_USER}@${MASTER_IP}"
echo "Key distributed to master node."

## 3. Distribute public key to all worker nodes

echo "--- Step 3: Distributing public key to worker nodes ---"

for WORKER_IP in "${WORKER_IPS[@]}"; do
    echo "Distributing key to worker node: $WORKER_IP"
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" "${SSH_USER}@${WORKER_IP}"
    echo "Key distributed to $WORKER_IP."
done

## 4. Verify SSH connectivity to all nodes

echo "--- Step 4: Verifying SSH connectivity ---"

ALL_NODES=("$MASTER_IP" "${WORKER_IPS[@]}")
FAILED_NODES=()

for NODE_IP in "${ALL_NODES[@]}"; do
    echo "Testing SSH connection to $NODE_IP..."
    if ssh -i "$SSH_KEY_PATH" -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${NODE_IP}" "echo 'SSH connection successful'" 2>/dev/null; then
        echo "OK: $NODE_IP is reachable."
    else
        echo "FAIL: Cannot connect to $NODE_IP via SSH."
        FAILED_NODES+=("$NODE_IP")
    fi
done

if [ "${#FAILED_NODES[@]}" -gt 0 ]; then
    echo ""
    echo "WARNING: SSH connectivity failed for the following nodes:"
    for NODE in "${FAILED_NODES[@]}"; do
        echo "  - $NODE"
    done
    echo "Please verify network access and retry."
    exit 1
fi

echo ""
echo "=== SSH key generation and distribution complete ==="
echo "Key path: $SSH_KEY_PATH"
echo "All nodes are reachable via SSH."
