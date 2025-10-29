#!/bin/bash
# Setup Helm repository for testing RFE-7965
# Usage: ./setup-basic-auth-repo.sh [IP] [MODE]
# 
# Modes:
#   full       - HTTPS + Basic Auth + CA (default)
#   https-only - HTTPS + CA (no auth)
#   http-only  - HTTP (no SSL, no auth)
#   basic-http - HTTP + Basic Auth (for validation testing - INSECURE)

set -e

EC2_IP="${1:-$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)}"
MODE="${2:-full}"
HELM_USER="helmuser"
HELM_PASS="HelmPass123!"
REPO_DIR="/var/www/helm-repo"
CA_CERT_FILE="/tmp/helm-ca-cert.pem"

echo "========================================"
echo "Setting up Helm repository"
echo "========================================"
echo "IP: ${EC2_IP}"
echo "Mode: ${MODE}"
echo ""

# Install dependencies
sudo apt-get update -qq
sudo apt-get install -y nginx apache2-utils openssl curl

# Setup based on mode
case "${MODE}" in
  full|basic-http)
    echo "[1/4] Creating basic auth credentials..."
    sudo mkdir -p /etc/nginx/auth
    sudo htpasswd -bc /etc/nginx/auth/helm.htpasswd "${HELM_USER}" "${HELM_PASS}"
    ;;
  *)
    echo "[1/4] Skipping basic auth (not needed for ${MODE})"
    ;;
esac

case "${MODE}" in
  full|https-only)
    echo "[2/4] Generating SSL certificate..."
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout /etc/ssl/private/helm-repo.key \
      -out /etc/ssl/certs/helm-repo.crt \
      -subj "/CN=${EC2_IP}/O=Helm Testing/C=US" \
      -addext "subjectAltName=IP:${EC2_IP}"
    ;;
  *)
    echo "[2/4] Skipping SSL (not needed for ${MODE})"
    ;;
esac

# Configure nginx based on mode
echo "[3/4] Configuring nginx..."
case "${MODE}" in
  full)
    sudo tee /etc/nginx/sites-available/helm-repo <<EOF > /dev/null
server {
    listen 443 ssl;
    server_name ${EC2_IP};
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "Helm Repository";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    root ${REPO_DIR};
    location / { autoindex on; }
    location /health { auth_basic off; return 200 "OK\n"; }
}
EOF
    ;;
  
  https-only)
    sudo tee /etc/nginx/sites-available/helm-repo <<EOF > /dev/null
server {
    listen 443 ssl;
    server_name ${EC2_IP};
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root ${REPO_DIR};
    location / { autoindex on; }
    location /health { return 200 "OK\n"; }
}
EOF
    ;;
  
  http-only)
    sudo tee /etc/nginx/sites-available/helm-repo <<EOF > /dev/null
server {
    listen 80;
    server_name ${EC2_IP};
    root ${REPO_DIR};
    location / { autoindex on; }
    location /health { return 200 "OK\n"; }
}
EOF
    ;;
  
  basic-http)
    sudo tee /etc/nginx/sites-available/helm-repo <<EOF > /dev/null
server {
    listen 80;
    server_name ${EC2_IP};
    auth_basic "Helm Repository (INSECURE)";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    root ${REPO_DIR};
    location / { autoindex on; }
    location /health { auth_basic off; return 200 "OK\n"; }
}
EOF
    ;;
esac

sudo ln -sf /etc/nginx/sites-available/helm-repo /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo mkdir -p ${REPO_DIR}
sudo nginx -t && sudo systemctl reload nginx

# Install Helm if needed
if ! command -v helm &> /dev/null; then
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Create and publish sample charts
echo "[4/4] Creating test charts..."
cd /tmp
for chart in hello-world nginx-demo redis-test; do
    helm create ${chart} 2>/dev/null || true
    cat > ${chart}/Chart.yaml <<EOF
apiVersion: v2
name: ${chart}
description: Test chart for RFE-7965 (${chart})
type: application
version: 1.0.0
appVersion: "1.0"
EOF
    helm package ${chart} >/dev/null
done

# Generate index with correct URL
case "${MODE}" in
  full|https-only)
    helm repo index . --url "https://${EC2_IP}/"
    ;;
  *)
    helm repo index . --url "http://${EC2_IP}/"
    ;;
esac

sudo mv *.tgz index.yaml ${REPO_DIR}/
sudo chmod -R 755 ${REPO_DIR}

# Extract CA certificate if using HTTPS
if [[ "${MODE}" == "full" || "${MODE}" == "https-only" ]]; then
  sudo cp /etc/ssl/certs/helm-repo.crt ${CA_CERT_FILE}
  sudo chmod 644 ${CA_CERT_FILE}
fi

# Generate OpenShift configuration based on mode
case "${MODE}" in
  full)
    cat > /tmp/openshift-helm-repo-setup.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: helm-test
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-repo-ca
  namespace: helm-test
data:
  ca-bundle.crt: |
$(sudo sed 's/^/    /' ${CA_CERT_FILE})
---
apiVersion: v1
kind: Secret
metadata:
  name: helm-basic-auth
  namespace: helm-test
type: Opaque
stringData:
  username: ${HELM_USER}
  password: ${HELM_PASS}
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-helm-repo
  namespace: helm-test
spec:
  name: "Test Repo (HTTPS + Basic Auth)"
  description: "Full security: HTTPS + CA + Basic Auth"
  connectionConfig:
    url: https://${EC2_IP}/
    ca:
      name: helm-repo-ca
    basicAuthConfig:
      name: helm-basic-auth
EOF
    ;;
  
  https-only)
    cat > /tmp/openshift-helm-repo-setup.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: helm-test
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-repo-ca
  namespace: helm-test
data:
  ca-bundle.crt: |
$(sudo sed 's/^/    /' ${CA_CERT_FILE})
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-helm-repo
  namespace: helm-test
spec:
  name: "Test Repo (HTTPS Only)"
  description: "HTTPS with CA, no authentication"
  connectionConfig:
    url: https://${EC2_IP}/
    ca:
      name: helm-repo-ca
EOF
    ;;
  
  http-only)
    cat > /tmp/openshift-helm-repo-setup.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: helm-test
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-helm-repo
  namespace: helm-test
spec:
  name: "Test Repo (HTTP Only)"
  description: "Plain HTTP, no security"
  connectionConfig:
    url: http://${EC2_IP}/
EOF
    ;;
  
  basic-http)
    cat > /tmp/openshift-helm-repo-setup.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: helm-test
---
apiVersion: v1
kind: Secret
metadata:
  name: helm-basic-auth
  namespace: helm-test
type: Opaque
stringData:
  username: ${HELM_USER}
  password: ${HELM_PASS}
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-helm-repo
  namespace: helm-test
spec:
  name: "Test Repo (HTTP + Basic Auth - SHOULD FAIL)"
  description: "For testing validation - HTTP with Basic Auth (insecure)"
  connectionConfig:
    url: http://${EC2_IP}/
    basicAuthConfig:
      name: helm-basic-auth
EOF
    ;;
esac

# Summary
echo ""
echo "========================================"
echo "✅ Setup complete!"
echo "========================================"
echo "Mode: ${MODE}"
case "${MODE}" in
  full)
    echo "URL: https://${EC2_IP}/"
    echo "Auth: ${HELM_USER} / ${HELM_PASS}"
    ;;
  https-only)
    echo "URL: https://${EC2_IP}/"
    echo "Auth: None"
    ;;
  http-only)
    echo "URL: http://${EC2_IP}/"
    echo "Auth: None"
    ;;
  basic-http)
    echo "URL: http://${EC2_IP}/ (⚠️  INSECURE)"
    echo "Auth: ${HELM_USER} / ${HELM_PASS}"
    ;;
esac
echo ""
echo "Apply to OpenShift:"
echo "  oc apply -f /tmp/openshift-helm-repo-setup.yaml"
echo ""
echo "Test different modes:"
echo "  ./setup-basic-auth-repo.sh 13.60.201.122 full        # Full security"
echo "  ./setup-basic-auth-repo.sh 13.60.201.122 https-only  # No auth"
echo "  ./setup-basic-auth-repo.sh 13.60.201.122 http-only   # No SSL"
echo "  ./setup-basic-auth-repo.sh 13.60.201.122 basic-http  # Test validation"
echo ""
