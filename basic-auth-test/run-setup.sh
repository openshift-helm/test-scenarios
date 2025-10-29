#!/bin/bash
# Wrapper script to run setup-basic-auth-repo.sh on EC2 from your Mac
# Usage: ./run-setup.sh [EC2_IP] [MODE]
#
# Modes: full, https-only, http-only, basic-http

set -e

# Configuration
EC2_IP="${1:-13.60.201.122}"
MODE="${2:-full}"
SSH_KEY="$(dirname "$0")/../helm-test-2.pem"
SSH_USER="admin"

echo "Setting up Helm repository on EC2: ${EC2_IP}"
echo "Mode: ${MODE}"

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "❌ Error: SSH key not found at ${SSH_KEY}"
    exit 1
fi

# Upload and run setup script
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "$(dirname "$0")/setup-basic-auth-repo.sh" \
    "${SSH_USER}@${EC2_IP}:/tmp/"

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${EC2_IP}" \
    "chmod +x /tmp/setup-basic-auth-repo.sh && /tmp/setup-basic-auth-repo.sh ${EC2_IP} ${MODE}"

scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${EC2_IP}:/tmp/openshift-helm-repo-setup.yaml" \
    /tmp/

echo ""
echo "Setup complete!"
echo "  oc apply -f /tmp/openshift-helm-repo-setup.yaml"
echo ""
echo "Examples:"
echo "  ./run-setup.sh 13.60.201.122 full"
echo "  ./run-setup.sh 13.60.201.122 https-only"
echo "  ./run-setup.sh 13.60.201.122 http-only"
echo "  ./run-setup.sh 13.60.201.122 basic-http"
echo ""

