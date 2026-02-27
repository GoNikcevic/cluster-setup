# Kubernetes Cluster Setup Toolkit

A complete toolkit for deploying a production-ready Kubernetes cluster using kubeadm on Ubuntu-based VMs. This project automates VM preparation, SSH key distribution, Kubernetes installation, cluster verification, and local kubectl configuration.

## Architecture

```
                        +---------------------------+
                        |      Control Host         |
                        | (your machine / bastion)  |
                        |                           |
                        |  deploy-cluster.sh        |
                        |  create-cluster-config.sh |
                        |  configure-ctl.sh         |
                        +-----+-----+-----+--------+
                              |     |     |
                     SSH      |     |     |      SSH
                  +----------+      |     +----------+
                  |                 |                 |
                  v                 v                 v
        +-----------------+ +-----------+ +------------------+
        |   Master Node   | |  Worker 1 | |   Worker N       |
        | (controlplane)  | |           | |                  |
        |                 | |           | |                  |
        | - API Server    | | - kubelet | | - kubelet        |
        | - Scheduler     | | - kube-   | | - kube-proxy     |
        | - Controller    | |   proxy   | | - Calico node    |
        |   Manager       | | - Calico  | | - App workloads  |
        | - etcd          | |   node    | |                  |
        | - Calico        | | - App     | |                  |
        |                 | |  workloads| |                  |
        +-----------------+ +-----------+ +------------------+
              10.0.0.10       10.0.0.11       10.0.0.1x

        Pod CIDR:     192.168.0.0/16  (Calico)
        Service CIDR: 10.96.0.0/12   (kubeadm default)
```

### Deployment Flow

```
create-cluster-config.sh   -->  cluster.yml
                                    |
deploy-cluster.sh  <----------------+
    |
    +-- generate-ssh-keys.sh        (Step 1: SSH key distribution)
    |
    +-- prepare-vm.sh               (Step 2: Run on each node via SSH)
    |       +-- Create user
    |       +-- Install Docker
    |       +-- Configure firewall
    |       +-- Disable swap
    |
    +-- install-cluster-engine.sh   (Step 3: Run on master node)
    |       +-- Install kubeadm/kubelet/kubectl
    |       +-- kubeadm init
    |       +-- Install Calico CNI
    |       +-- Generate join command
    |
    +-- [worker join]               (Step 4: Install kubelet + join on each worker)
    |
    +-- verify-cluster.sh           (Step 5: Health checks)

configure-ctl.sh                    (Post-deploy: Set up local kubectl)
```

## Prerequisites

### Control Host Requirements

- **Operating System**: macOS or Linux
- **Tools**:
  - `ssh` and `scp` (for remote node access)
  - `yq` (YAML parser, used by deploy-cluster.sh)
  - `kubectl` (for configure-ctl.sh and cluster management)
- **Network**: Ability to reach all cluster nodes on ports 22 (SSH) and 6443 (Kubernetes API)

### Cluster Node Requirements

- **Operating System**: Ubuntu 20.04 LTS or newer
- **Minimum Resources**:
  - Master node: 2 CPU, 2 GB RAM, 20 GB disk
  - Worker nodes: 2 CPU, 2 GB RAM, 20 GB disk
- **Network**: Static IP addresses, all nodes can communicate with each other
- **Access**: A user with sudo privileges and SSH access from the control host
- **Ports**: The following ports will be opened by prepare-vm.sh:
  - `22/tcp` - SSH
  - `6443/tcp` - Kubernetes API server
  - `2379-2380/tcp` - etcd server client API
  - `10250-10252/tcp` - Kubelet API, kube-scheduler, kube-controller-manager
  - `30000-32767/tcp` - NodePort services

### Installing Prerequisites

```bash
# Install yq (macOS)
brew install yq

# Install yq (Ubuntu/Debian)
sudo apt-get install -y yq
# or via pip:
pip install yq

# Install kubectl (macOS)
brew install kubectl

# Install kubectl (Linux)
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

## Quick Start

### Option A: Automated Deployment (Recommended)

```bash
# 1. Clone the repository
git clone <repository-url>
cd cluster-setup

# 2. Make scripts executable
chmod +x *.sh

# 3. Generate cluster configuration
#    (interactive - will prompt for IPs, hostnames, etc.)
./create-cluster-config.sh

# 4. Deploy the cluster
./deploy-cluster.sh

# 5. Configure local kubectl
./configure-ctl.sh ubuntu 10.0.0.10
```

### Option B: Non-Interactive Deployment

```bash
# 1. Generate config with environment variables
CLUSTER_NAME=production \
MASTER_IP=10.0.0.10 \
MASTER_HOSTNAME=master-01 \
WORKER_IPS=10.0.0.11,10.0.0.12 \
WORKER_HOSTNAMES=worker-01,worker-02 \
POD_CIDR=192.168.0.0/16 \
SERVICE_CIDR=10.96.0.0/12 \
KUBERNETES_VERSION=1.29 \
SSH_USER=ubuntu \
SSH_KEY_PATH=~/.ssh/id_rsa_cluster \
./create-cluster-config.sh

# 2. Deploy
SSH_PASSWORD=your-password ./deploy-cluster.sh

# 3. Configure kubectl
./configure-ctl.sh ubuntu 10.0.0.10 ~/.ssh/id_rsa_cluster production
```

### Option C: Step-by-Step Manual Deployment

```bash
# 1. Edit cluster.yml directly with your values
vim cluster.yml

# 2. Generate and distribute SSH keys
./generate-ssh-keys.sh ubuntu 10.0.0.10 10.0.0.11 10.0.0.12

# 3. Prepare each VM (run on each node or via SSH)
ssh ubuntu@10.0.0.10 'bash -s' < prepare-vm.sh -- ubuntu password ubuntu 10.0.0.10
ssh ubuntu@10.0.0.11 'bash -s' < prepare-vm.sh -- ubuntu password ubuntu 10.0.0.10
ssh ubuntu@10.0.0.12 'bash -s' < prepare-vm.sh -- ubuntu password ubuntu 10.0.0.10

# 4. Install Kubernetes on the master
ssh ubuntu@10.0.0.10 \
  'IPADDR=10.0.0.10 POD_CIDR=192.168.0.0/16 NODENAME=master-01 bash -s' \
  < install-cluster-engine.sh

# 5. Join workers (get join command from master, run on each worker)
JOIN_CMD=$(ssh ubuntu@10.0.0.10 'cat /tmp/join-command.sh')
ssh ubuntu@10.0.0.11 "sudo $JOIN_CMD"
ssh ubuntu@10.0.0.12 "sudo $JOIN_CMD"

# 6. Verify the cluster
./verify-cluster.sh ubuntu 10.0.0.10

# 7. Configure local kubectl
./configure-ctl.sh ubuntu 10.0.0.10
```

## Scripts Reference

### prepare-vm.sh

Prepares a VM for Kubernetes by creating a user, installing Docker, configuring the firewall, and disabling swap.

```
Usage: ./prepare-vm.sh <username> <password> <master_username> <master_ip>
```

| Parameter | Description |
|-----------|-------------|
| `username` | New user to create with sudo privileges |
| `password` | Password for the new user |
| `master_username` | Username on the master node for SSH key exchange |
| `master_ip` | IP address of the master node |

### generate-ssh-keys.sh

Generates an SSH key pair and distributes the public key to all cluster nodes.

```
Usage: ./generate-ssh-keys.sh <ssh_user> <master_ip> <worker_ip_1> [worker_ip_2] ...
```

| Parameter | Description |
|-----------|-------------|
| `ssh_user` | SSH username on all remote nodes |
| `master_ip` | IP address of the master node |
| `worker_ip_N` | IP addresses of worker nodes (one or more) |

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `SSH_KEY_PATH` | `~/.ssh/id_rsa_cluster` | Path to store the generated key pair |

### install-cluster-engine.sh

Installs kubeadm, kubelet, and kubectl on the master node, initializes the cluster, and installs Calico CNI.

```
Usage: IPADDR=<ip> POD_CIDR=<cidr> NODENAME=<name> ./install-cluster-engine.sh
```

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `IPADDR` | (required) | IP address of the master node |
| `POD_CIDR` | (required) | Pod network CIDR (e.g. 192.168.0.0/16) |
| `NODENAME` | (required) | Hostname for the master node |
| `KUBERNETES_VERSION` | `1.29` | Kubernetes minor version |

### create-cluster-config.sh

Generates the `cluster.yml` configuration file interactively or from environment variables.

```
Usage: ./create-cluster-config.sh
```

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CLUSTER_NAME` | `my-cluster` | Name of the cluster |
| `MASTER_IP` | (prompted) | Master node IP address |
| `MASTER_HOSTNAME` | `master-01` | Master node hostname |
| `WORKER_IPS` | (prompted) | Comma-separated worker IPs |
| `WORKER_HOSTNAMES` | auto-generated | Comma-separated worker hostnames |
| `POD_CIDR` | `192.168.0.0/16` | Pod network CIDR |
| `SERVICE_CIDR` | `10.96.0.0/12` | Service network CIDR |
| `KUBERNETES_VERSION` | `1.29` | Kubernetes minor version |
| `SSH_USER` | `ubuntu` | SSH user on all nodes |
| `SSH_KEY_PATH` | `~/.ssh/id_rsa_cluster` | SSH private key path |
| `CONFIG_FILE` | `./cluster.yml` | Output configuration file path |

### deploy-cluster.sh

Orchestrates the full cluster deployment by reading `cluster.yml` and executing all setup scripts in order.

```
Usage: ./deploy-cluster.sh
```

| Environment Variable | Default | Description |
|---------------------|---------|-------------|
| `CONFIG_FILE` | `./cluster.yml` | Path to the cluster configuration file |
| `SSH_PASSWORD` | `changeme` | Password for initial SSH connections |
| `SKIP_PREPARE` | `false` | Set to `true` to skip VM preparation |
| `SKIP_VERIFY` | `false` | Set to `true` to skip health verification |

### verify-cluster.sh

Runs 8 health checks against the cluster: node status, system pods, component status, DNS resolution, CoreDNS, Calico, network connectivity, and cluster info.

```
Usage: ./verify-cluster.sh [ssh_user] [master_ip] [ssh_key_path]
```

When run without parameters, the script executes checks locally (must be on the master node). With parameters, it connects via SSH.

| Parameter | Description |
|-----------|-------------|
| `ssh_user` | SSH username on the master node |
| `master_ip` | IP address of the master node |
| `ssh_key_path` | Path to SSH private key (default: `~/.ssh/id_rsa_cluster`) |

### configure-ctl.sh

Sets up kubectl on your local machine by fetching the kubeconfig from the master node and configuring a named context.

```
Usage: ./configure-ctl.sh <ssh_user> <master_ip> [ssh_key_path] [context_name]
```

| Parameter | Description |
|-----------|-------------|
| `ssh_user` | SSH username on the master node |
| `master_ip` | IP address of the master node |
| `ssh_key_path` | Path to SSH private key (default: `~/.ssh/id_rsa_cluster`) |
| `context_name` | kubectl context name (default: read from cluster.yml or `kubernetes`) |

## Configuration File (cluster.yml)

The `cluster.yml` file defines all cluster parameters. It can be generated by `create-cluster-config.sh` or edited manually.

```yaml
cluster_name: my-cluster
kubernetes_version: "1.29"

ssh:
  user: ubuntu
  key_path: ~/.ssh/id_rsa_cluster

master:
  hostname: master-01
  ip: 10.0.0.10
  role: controlplane,etcd

workers:
  - hostname: worker-01
    ip: 10.0.0.11
    role: worker
  - hostname: worker-02
    ip: 10.0.0.12
    role: worker

network:
  pod_cidr: 192.168.0.0/16
  service_cidr: 10.96.0.0/12
  cni_plugin: calico
```

| Field | Description |
|-------|-------------|
| `cluster_name` | Identifier for the cluster, used as kubectl context name |
| `kubernetes_version` | Minor version of Kubernetes to install (e.g. `1.29`) |
| `ssh.user` | SSH user with sudo access on all nodes |
| `ssh.key_path` | Private key for SSH authentication |
| `master.hostname` | Hostname assigned to the master node |
| `master.ip` | Static IP of the master node |
| `master.role` | Node roles (`controlplane,etcd` for master) |
| `workers[].hostname` | Hostname assigned to each worker |
| `workers[].ip` | Static IP of each worker |
| `workers[].role` | Node role (`worker`) |
| `network.pod_cidr` | CIDR for pod IPs (must match CNI expectations) |
| `network.service_cidr` | CIDR for Kubernetes service ClusterIPs |
| `network.cni_plugin` | Container Network Interface plugin (`calico`) |

## Environment Variables Reference

All environment variables used across the toolkit, consolidated:

| Variable | Used By | Default | Description |
|----------|---------|---------|-------------|
| `CLUSTER_NAME` | create-cluster-config.sh | `my-cluster` | Cluster name |
| `MASTER_IP` | create-cluster-config.sh | (prompted) | Master node IP |
| `MASTER_HOSTNAME` | create-cluster-config.sh | `master-01` | Master hostname |
| `WORKER_IPS` | create-cluster-config.sh | (prompted) | Comma-separated worker IPs |
| `WORKER_HOSTNAMES` | create-cluster-config.sh | auto-generated | Comma-separated worker hostnames |
| `POD_CIDR` | create-cluster-config.sh, install-cluster-engine.sh | `192.168.0.0/16` | Pod network CIDR |
| `SERVICE_CIDR` | create-cluster-config.sh | `10.96.0.0/12` | Service network CIDR |
| `KUBERNETES_VERSION` | create-cluster-config.sh, install-cluster-engine.sh | `1.29` | Kubernetes version |
| `SSH_USER` | create-cluster-config.sh | `ubuntu` | SSH user |
| `SSH_KEY_PATH` | generate-ssh-keys.sh, create-cluster-config.sh | `~/.ssh/id_rsa_cluster` | SSH key path |
| `SSH_PASSWORD` | deploy-cluster.sh | `changeme` | Initial SSH password |
| `CONFIG_FILE` | deploy-cluster.sh, create-cluster-config.sh, configure-ctl.sh | `./cluster.yml` | Config file path |
| `IPADDR` | install-cluster-engine.sh | (required) | Master IP for kubeadm |
| `NODENAME` | install-cluster-engine.sh | (required) | Master hostname for kubeadm |
| `SKIP_PREPARE` | deploy-cluster.sh | `false` | Skip VM preparation step |
| `SKIP_VERIFY` | deploy-cluster.sh | `false` | Skip verification step |

## Troubleshooting

### SSH Connection Issues

**Problem**: `ssh-copy-id` or SSH connections fail.

```bash
# Verify network connectivity
ping <node-ip>

# Test SSH manually
ssh -v ubuntu@<node-ip>

# Check if SSH service is running on the target
ssh ubuntu@<node-ip> 'systemctl status sshd'

# Regenerate keys if needed
SSH_KEY_PATH=~/.ssh/id_rsa_cluster ./generate-ssh-keys.sh ubuntu <master-ip> <worker-ips>
```

### kubeadm init Fails

**Problem**: `kubeadm init` fails during cluster initialization.

```bash
# Check preflight errors
ssh ubuntu@<master-ip> 'sudo kubeadm init --dry-run'

# Verify swap is disabled
ssh ubuntu@<master-ip> 'free -h'
ssh ubuntu@<master-ip> 'sudo swapoff -a'

# Check Docker is running
ssh ubuntu@<master-ip> 'sudo systemctl status docker'

# Reset and retry
ssh ubuntu@<master-ip> 'sudo kubeadm reset -f'
```

### Nodes Not Ready

**Problem**: `kubectl get nodes` shows nodes in NotReady state.

```bash
# Check node conditions
kubectl describe node <node-name>

# Check kubelet logs
ssh ubuntu@<node-ip> 'sudo journalctl -u kubelet -f'

# Verify Calico is running
kubectl get pods -n kube-system -l k8s-app=calico-node

# Check CNI configuration
ssh ubuntu@<node-ip> 'ls /etc/cni/net.d/'
```

### Pods Stuck in Pending or CrashLoopBackOff

**Problem**: System pods or application pods are not starting.

```bash
# Describe the pod for events
kubectl describe pod <pod-name> -n kube-system

# Check pod logs
kubectl logs <pod-name> -n kube-system

# Check available resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check if all system pods are running
kubectl get pods -n kube-system -o wide
```

### DNS Resolution Fails

**Problem**: Services cannot resolve DNS names inside the cluster.

```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns

# Test DNS from a debug pod
kubectl run dns-debug --image=busybox:1.36 --rm -it -- nslookup kubernetes.default
```

### Worker Nodes Cannot Join

**Problem**: `kubeadm join` fails on worker nodes.

```bash
# Verify the join token is still valid (tokens expire after 24h)
ssh ubuntu@<master-ip> 'kubeadm token list'

# Generate a new join command
ssh ubuntu@<master-ip> 'kubeadm token create --print-join-command'

# Check firewall allows required ports
ssh ubuntu@<master-ip> 'sudo ufw status'
ssh ubuntu@<worker-ip> 'sudo ufw status'

# Reset the worker and retry
ssh ubuntu@<worker-ip> 'sudo kubeadm reset -f'
```

### kubectl Cannot Connect to Cluster

**Problem**: `kubectl cluster-info` fails from the control host.

```bash
# Verify the API server is reachable
curl -k https://<master-ip>:6443/healthz

# Check kubeconfig
kubectl config view
kubectl config current-context

# Re-run configure-ctl.sh
./configure-ctl.sh ubuntu <master-ip>

# Check firewall allows port 6443
ssh ubuntu@<master-ip> 'sudo ufw status | grep 6443'
```

## Project Structure

```
cluster-setup/
  cluster.yml                 # Cluster configuration (template / generated)
  prepare-vm.sh               # VM preparation (Docker, firewall, swap)
  generate-ssh-keys.sh        # SSH key generation and distribution
  install-cluster-engine.sh   # Kubernetes installation (kubeadm init)
  create-cluster-config.sh    # Interactive config generator
  deploy-cluster.sh           # Full deployment orchestrator
  verify-cluster.sh           # Cluster health verification
  configure-ctl.sh            # Local kubectl setup
  readme.md                   # This file
```

## License

This project is provided as-is for educational and operational use.
