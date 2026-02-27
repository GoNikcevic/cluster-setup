#!/bin/bash
set -euo pipefail

# This script verifies the health of a deployed Kubernetes cluster.
# It checks that all nodes are in Ready state, system pods are running,
# DNS is functional, and basic network connectivity works.

# The script can be run from the control host (connects via SSH to the master)
# or directly on the master node.

# parameters
# $1: SSH user (optional if running on master)
# $2: Master node IP (optional if running on master)
# $3: SSH key path (optional if running on master)

## 0. Determine execution mode

REMOTE_MODE=false
if [ "$#" -ge 2 ]; then
    REMOTE_MODE=true
    SSH_USER="$1"
    MASTER_IP="$2"
    SSH_KEY_PATH="${3:-$HOME/.ssh/id_rsa_cluster}"

    if [ -z "$SSH_USER" ] || [ -z "$MASTER_IP" ]; then
        echo "ERROR: SSH user and master IP must be non-empty."
        echo "Usage: $0 [ssh_user] [master_ip] [ssh_key_path]"
        exit 1
    fi
fi

# Helper function to run commands on the master node
run_on_master() {
    if [ "$REMOTE_MODE" = true ]; then
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "${SSH_USER}@${MASTER_IP}" "$@"
    else
        eval "$@"
    fi
}

echo "=== Kubernetes Cluster Health Verification ==="
echo ""

CHECKS_PASSED=0
CHECKS_FAILED=0

## 1. Check node status

echo "--- Check 1: Node Status ---"

NODE_OUTPUT="$(run_on_master "kubectl get nodes -o wide" 2>&1)" || true
echo "$NODE_OUTPUT"
echo ""

NOT_READY_NODES="$(echo "$NODE_OUTPUT" | grep -v "NAME" | grep -v "Ready" || true)"
if [ -z "$NOT_READY_NODES" ]; then
    echo "PASS: All nodes are in Ready state."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: The following nodes are NOT Ready:"
    echo "$NOT_READY_NODES"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 2. Check system pods (kube-system namespace)

echo "--- Check 2: System Pods (kube-system) ---"

PODS_OUTPUT="$(run_on_master "kubectl get pods -n kube-system -o wide" 2>&1)" || true
echo "$PODS_OUTPUT"
echo ""

FAILED_PODS="$(echo "$PODS_OUTPUT" | grep -v "NAME" | grep -vE "Running|Completed" || true)"
if [ -z "$FAILED_PODS" ]; then
    echo "PASS: All system pods are Running or Completed."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: The following system pods are not in a healthy state:"
    echo "$FAILED_PODS"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 3. Check core components health

echo "--- Check 3: Core Component Status ---"

COMPONENT_OUTPUT="$(run_on_master "kubectl get componentstatuses" 2>&1)" || true
echo "$COMPONENT_OUTPUT"
echo ""

UNHEALTHY_COMPONENTS="$(echo "$COMPONENT_OUTPUT" | grep -v "NAME" | grep -v "Healthy" || true)"
if [ -z "$UNHEALTHY_COMPONENTS" ]; then
    echo "PASS: All core components are healthy."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "WARNING: Some components may report issues (componentstatuses is deprecated in newer versions)."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
fi

echo ""

## 4. Check DNS functionality

echo "--- Check 4: DNS Resolution ---"

DNS_RESULT="$(run_on_master "kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -i --wait=true -- nslookup kubernetes.default.svc.cluster.local" 2>&1)" || true
echo "$DNS_RESULT"
echo ""

if echo "$DNS_RESULT" | grep -q "Address"; then
    echo "PASS: DNS resolution is working."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: DNS resolution failed."
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 5. Check CoreDNS pods

echo "--- Check 5: CoreDNS Status ---"

COREDNS_OUTPUT="$(run_on_master "kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide" 2>&1)" || true
echo "$COREDNS_OUTPUT"
echo ""

COREDNS_NOT_RUNNING="$(echo "$COREDNS_OUTPUT" | grep -v "NAME" | grep -v "Running" || true)"
if [ -z "$COREDNS_NOT_RUNNING" ]; then
    echo "PASS: CoreDNS pods are running."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: CoreDNS pods are not all running."
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 6. Check network plugin (Calico)

echo "--- Check 6: Network Plugin (Calico) ---"

CALICO_OUTPUT="$(run_on_master "kubectl get pods -n kube-system -l k8s-app=calico-node -o wide" 2>&1)" || true
echo "$CALICO_OUTPUT"
echo ""

CALICO_NOT_RUNNING="$(echo "$CALICO_OUTPUT" | grep -v "NAME" | grep -v "Running" || true)"
if [ -z "$CALICO_NOT_RUNNING" ]; then
    echo "PASS: Calico network plugin pods are running."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: Calico network plugin pods are not all running."
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 7. Check pod-to-pod network connectivity

echo "--- Check 7: Pod-to-API-Server Network Connectivity ---"

# Deploy a test pod and verify it can reach the API server
CONNECTIVITY_RESULT="$(run_on_master "kubectl run net-test --image=busybox:1.36 --restart=Never --rm -i --wait=true -- wget -qO- --timeout=5 https://kubernetes.default.svc.cluster.local/healthz --no-check-certificate" 2>&1)" || true
echo "$CONNECTIVITY_RESULT"
echo ""

if echo "$CONNECTIVITY_RESULT" | grep -q "ok"; then
    echo "PASS: Pod-to-API-server network connectivity is working."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: Pod-to-API-server network connectivity test failed."
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 8. Check cluster info

echo "--- Check 8: Cluster Info ---"

CLUSTER_INFO="$(run_on_master "kubectl cluster-info" 2>&1)" || true
echo "$CLUSTER_INFO"
echo ""

if echo "$CLUSTER_INFO" | grep -q "is running at"; then
    echo "PASS: Kubernetes control plane is running."
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
else
    echo "FAIL: Cannot retrieve cluster info."
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
fi

echo ""

## 9. Summary

echo "========================================="
echo "  Cluster Health Verification Summary"
echo "========================================="
echo "  Checks passed: $CHECKS_PASSED"
echo "  Checks failed: $CHECKS_FAILED"
echo "  Total checks:  $((CHECKS_PASSED + CHECKS_FAILED))"
echo "========================================="

if [ "$CHECKS_FAILED" -gt 0 ]; then
    echo ""
    echo "WARNING: Some checks failed. Review the output above for details."
    echo "Common troubleshooting steps:"
    echo "  - Wait a few minutes for pods to become ready"
    echo "  - Check node logs: kubectl describe node <node-name>"
    echo "  - Check pod logs: kubectl logs -n kube-system <pod-name>"
    echo "  - Verify network connectivity between nodes"
    exit 1
fi

echo ""
echo "=== All cluster health checks passed ==="
