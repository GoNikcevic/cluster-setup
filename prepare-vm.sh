#!/bin/bash
set -euo pipefail

# This script is used to install the necessary packages and configure the VM for the installation of the Kubernetes cluster.
# The script is executed on the VM that will be used as the Kubernetes master node.
# This script will setup a new user with sudo privileges, install the necessary packages, and configure the firewall.

# This script will use ssh to connect to the VM

# The script will be executed by an Ansible playbook which will pass the necessary parameters to the script.

# exchange the key with the master node
# parameters
# $1: username
# $2: password
# $3: username of the master node
# $4: ip address of the master node

## 0. Validate input parameters

if [ "$#" -ne 4 ]; then
    echo "ERROR: This script requires exactly 4 parameters."
    echo "Usage: $0 <username> <password> <master_username> <master_ip>"
    exit 1
fi

USERNAME="$1"
PASSWORD="$2"
MASTER_USERNAME="$3"
MASTER_IP="$4"

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$MASTER_USERNAME" ] || [ -z "$MASTER_IP" ]; then
    echo "ERROR: All parameters must be non-empty."
    echo "Usage: $0 <username> <password> <master_username> <master_ip>"
    exit 1
fi

# Validate IP address format
if ! echo "$MASTER_IP" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    echo "ERROR: Invalid IP address format: $MASTER_IP"
    exit 1
fi

echo "=== Preparing VM for Kubernetes cluster ==="
echo "Username: $USERNAME"
echo "Master node: $MASTER_USERNAME@$MASTER_IP"

## 1. Create a new user with sudo privileges

echo "--- Step 1: Creating user $USERNAME with sudo privileges ---"

sudo useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | sudo chpasswd
sudo usermod -aG sudo "$USERNAME"

## 2. Exchange the key with the master node

echo "--- Step 2: Exchanging SSH key with master node ---"

ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id "$MASTER_USERNAME@$MASTER_IP"


## 3. Install the necessary packages

echo "--- Step 3: Installing required packages ---"

sudo apt-get update

sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

sudo apt-get install -y epel-release python3 python3-pip policycoreutils-python-utils

## 4. Install Docker engine

echo "--- Step 4: Installing Docker engine ---"

### 4.1. Add the Docker GPG key

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

### 4.2. Install Docker packages for k8 nodes

sudo apt-get install -y docker-ce docker-ce-cli containerd.io

### 4.3. Start and enable the Docker service

sudo systemctl start docker

sudo systemctl enable docker

## 5. Finalize the configuration

echo "--- Step 5: Finalizing configuration ---"

### 5.1. Disable the swap memory

sudo swapoff -a

sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

### 5.2. Configure the firewall

sudo ufw allow OpenSSH

sudo ufw allow 6443/tcp

sudo ufw allow 2379:2380/tcp

sudo ufw allow 10250:10252/tcp

sudo ufw allow 30000:32767/tcp

sudo ufw --force enable

echo "=== VM preparation complete ==="
