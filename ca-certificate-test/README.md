# OCPBUGS-44235 - Helm CA Certificate Bug Reproduction

## Bug Description

Helm chart installation fails when CA certificates or client TLS certificates are configured on `HelmChartRepository` or `ProjectHelmChartRepository`:

```
error locating chart: open /.cache/helm/repository/<hash>-index.yaml: no such file or directory
```

Browsing charts works. Installing fails.

**Affected:** OCP 4.14, 4.15, 4.16+

---

## Manual Reproduction Steps

### 1. Create HTTPS Helm Repository

On a server (Debian/Ubuntu):

```bash
# Install nginx
sudo apt-get install -y nginx

# Generate self-signed certificate (⚠️ IMPORTANT: Replace your-domain.com with actual domain!)
cat > ~/openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = your-domain.com
[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = your-domain.com
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ~/helm-repo.key \
  -out ~/helm-repo.crt \
  -config ~/openssl.cnf

# Install certificate with proper permissions
sudo install -m 600 ~/helm-repo.key /etc/ssl/private/helm-repo.key
sudo install -m 644 ~/helm-repo.crt /etc/ssl/certs/helm-repo.crt

# Configure nginx for HTTP and HTTPS
sudo tee /etc/nginx/sites-available/helm-repo <<'EOF'
server {
    listen 80;
    listen 443 ssl;
    server_name your-domain.com;
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    root /var/www/helm;
    location / {
        autoindex on;
    }
}
EOF

sudo ln -sf /etc/nginx/sites-available/helm-repo /etc/nginx/sites-enabled/helm-repo
sudo rm -f /etc/nginx/sites-enabled/default
sudo mkdir -p /var/www/helm
sudo nginx -t && sudo systemctl reload nginx
```

### 2. Create and Publish Helm Chart

```bash
# Create chart
helm create hello-helm
rm -rf hello-helm/templates/tests

# Package chart
helm package hello-helm

# Copy to web root
sudo cp hello-helm-0.1.0.tgz /var/www/helm/

# Generate repository index (⚠️ IMPORTANT: Replace your-domain.com with actual domain!)
cd /var/www/helm
sudo helm repo index . --url https://your-domain.com/

# Set proper permissions
sudo chmod 644 /var/www/helm/*

# Verify URLs in index.yaml are correct
cat /var/www/helm/index.yaml | grep "urls:" -A 1
# Should show: - https://your-domain.com/hello-helm-0.1.0.tgz
```

### 3. Configure on OpenShift

```bash
# Download CA certificate from server ⚠️ IMPORTANT:(replace admin and SSH key path)
scp -i ~/your-key.pem admin@your-server-ip:/etc/ssl/certs/helm-repo.crt ~/ca-bundle.crt

# Create namespace
oc new-project helm-lab

# Create CA ConfigMap
oc create configmap charts-ca -n helm-lab --from-file=ca-bundle.crt=ca-bundle.crt

# Verify ConfigMap
oc get configmap charts-ca -n helm-lab -o jsonpath='{.data.ca-bundle\.crt}' | head -n 5

# Create Helm repository with CA
cat <<EOF | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-repo
  namespace: helm-lab
spec:
  connectionConfig:
    url: https://your-domain.com/
    ca:
      name: charts-ca
EOF
```

### 4. Reproduce Bug

**In Console UI:**
1. Developer → Project: helm-lab → +Add → Helm Chart
2. Browse works (charts visible)
3. Click on chart → Error appears

**Via Helm CLI (for comparison):**
```bash
helm repo add test https://your-domain.com/ --ca-file ~/ca-bundle.crt
helm install demo test/hello-helm -n helm-lab
# Works correctly
```

---

## Root Cause

Console uses Kubernetes CRDs to store repository configuration, not Helm's repository cache. Setting `chartPathOptions.RepoURL` during authentication forced Helm to look for `$HOME/.cache/helm/repository/` which doesn't exist in read-only pod filesystems.

---

## Additional Resources

- Automated setup script: `verify-helm-ca-bug.sh` (requires EC2 instance)
- Issue: https://issues.redhat.com/browse/OCPBUGS-44235
