#!/bin/bash
set -euo pipefail

# This script installs k8s cluster using kubeadm and kubectl.

# This script is used to install the necessary packages and configure the VM for the installation of the Kubernetes cluster.

# The script is executed on the VM that will be used as the Kubernetes master node.
# It assumes Docker and apt-transport-https ca-certificates curl software-properties-common are already installed, firewall is configured, and the user has sudo privileges.

# parameters (via environment variables)
# IPADDR:              IP address of the master node
# POD_CIDR:            Pod network CIDR (e.g. 192.168.0.0/16)
# NODENAME:            Hostname for the master node
# KUBERNETES_VERSION:  Kubernetes minor version (e.g. 1.29)

## 0. Validate required environment variables

KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.29}"

if [ -z "${IPADDR:-}" ]; then
    echo "ERROR: IPADDR environment variable is required."
    echo "Usage: IPADDR=<master_ip> POD_CIDR=<pod_cidr> NODENAME=<node_name> $0"
    exit 1
fi

if [ -z "${POD_CIDR:-}" ]; then
    echo "ERROR: POD_CIDR environment variable is required."
    echo "Usage: IPADDR=<master_ip> POD_CIDR=<pod_cidr> NODENAME=<node_name> $0"
    exit 1
fi

if [ -z "${NODENAME:-}" ]; then
    echo "ERROR: NODENAME environment variable is required."
    echo "Usage: IPADDR=<master_ip> POD_CIDR=<pod_cidr> NODENAME=<node_name> $0"
    exit 1
fi

# Validate IP address format
if ! echo "$IPADDR" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "ERROR: Invalid IP address format for IPADDR: $IPADDR"
    exit 1
fi

# Validate CIDR format
if ! echo "$POD_CIDR" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$'; then
    echo "ERROR: Invalid CIDR format for POD_CIDR: $POD_CIDR"
    exit 1
fi

echo "=== Installing Kubernetes cluster engine ==="
echo "Kubernetes version: $KUBERNETES_VERSION"
echo "Master IP: $IPADDR"
echo "Pod CIDR: $POD_CIDR"
echo "Node name: $NODENAME"

## 1. Install Kubeadm & Kubelet & Kubectl on all Nodes

echo "--- Step 1: Installing kubeadm, kubelet, and kubectl ---"

# Add the Kubernetes GPG key

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key" | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

sudo apt-get install -y kubelet kubeadm kubectl

# freeze the version of the packages
sudo apt-mark hold kubelet kubeadm kubectl

## 2. Start and enable the kubelet service

echo "--- Step 2: Starting kubelet service ---"

sudo systemctl enable kubelet
sudo systemctl start kubelet

## 3. Initialize the Kubernetes cluster

echo "--- Step 3: Initializing Kubernetes cluster ---"

sudo kubeadm init \
    --apiserver-advertise-address="$IPADDR" \
    --apiserver-cert-extra-sans="$IPADDR" \
    --pod-network-cidr="$POD_CIDR" \
    --node-name "$NODENAME" \
    --ignore-preflight-errors Swap

## 4. Configure kubectl for the current user

echo "--- Step 4: Configuring kubectl ---"

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

## 5. Generate join command for worker nodes

echo "--- Step 5: Generating join command ---"

kubeadm token create --print-join-command > /tmp/join-command.sh

## 6. Install the Calico network plugin

echo "--- Step 6: Installing Calico network plugin ---"

kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml

echo "=== Kubernetes cluster engine installation complete ==="
