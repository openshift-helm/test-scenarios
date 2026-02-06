# Basic Auth UI Feature Testing - RFE-7965 & OCPBUGS-76328

HTTPS Helm repository with Basic Authentication for testing ProjectHelmChartRepository UI features.

## Features Tested

- **RFE-7965**: Basic Authentication support for ProjectHelmChartRepository
- **OCPBUGS-76328**: CA/TLS dropdowns using correct namespace (project vs cluster-scoped)
- HTTPS validation (prevents HTTP + basic auth)

## Quick Setup

### Prerequisites
- EC2 instance (Ubuntu/Debian) with public IP
- OpenShift cluster with cluster-admin access
- SSH key at `../helm-test-2.pem` (or update `run-setup.sh`)

### Run Setup

```bash
cd basic-auth-test

# Setup HTTPS Helm repo with Basic Auth on EC2
./run-setup.sh <EC2_PUBLIC_IP> full

# Apply generated resources to OpenShift
oc apply -f /tmp/openshift-helm-repo-setup.yaml
```

### Setup Modes

The `run-setup.sh` script supports different testing scenarios:

```bash
./run-setup.sh <EC2_IP> full          # HTTPS + Basic Auth + CA cert (default)
./run-setup.sh <EC2_IP> https-only    # HTTPS only, no auth
./run-setup.sh <EC2_IP> http-only     # HTTP only, no auth
./run-setup.sh <EC2_IP> basic-http    # HTTP + Basic Auth (for validation testing)
```

## What Gets Created

### On EC2
- Nginx server with HTTPS (self-signed certificate)
- HTTP Basic Authentication (username: `helmuser`, password: `HelmPass123!`)
- Sample Helm charts repository

### On OpenShift (in project namespace)
- **Secret** `helm-basic-auth`: Contains username/password for Basic Auth
- **ConfigMap** `helm-ca-cert`: Contains CA certificate for self-signed cert
- **ProjectHelmChartRepository** `test-basic-auth-repo`: Pre-configured with all settings

## UI Testing

### Test 1: Basic Authentication Field (RFE-7965)

**Namespace-scoped (ProjectHelmChartRepository):**
1. Navigate: **Helm** → **Helm Repositories** → **Create ProjectHelmChartRepository**
2. Select: **Scope type** → Namespaced scoped
3. Expand: **Show advanced options**
4. ✅ **Verify**: Basic Authentication dropdown is visible
5. Select a secret with `username` and `password` keys
6. ✅ **Verify**: Form accepts the configuration

**Cluster-scoped (HelmChartRepository):**
1. Create HelmChartRepository (cluster-scoped)
2. Expand: **Show advanced options**
3. ✅ **Verify**: Basic Authentication dropdown is NOT visible (not supported)

### Test 2: HTTPS Validation

1. Create ProjectHelmChartRepository
2. Enter **URL**: `http://<EC2_IP>/` (HTTP without S)
3. Select **Basic Authentication**: Choose any secret
4. ✅ **Verify**: Error message appears: "Basic authentication requires HTTPS"
5. ✅ **Verify**: Create button is disabled or shows error on submit
6. Change URL to `https://<EC2_IP>/`
7. ✅ **Verify**: Error disappears, form can be submitted

### Test 3: Namespace Bug Fix (OCPBUGS-76328)

**ProjectHelmChartRepository (namespace-scoped):**
1. Create ConfigMap in project namespace:
   ```bash
   oc create configmap my-custom-ca --from-literal=ca-bundle.crt="test" -n <PROJECT>
   ```
2. Create ProjectHelmChartRepository in that namespace
3. Expand: **Show advanced options**
4. Open **CA Certificate** dropdown
5. ✅ **Verify**: Shows `my-custom-ca` and `helm-ca-cert` from project namespace
6. ✅ **Before fix**: Would only show ConfigMaps from `openshift-config`

**HelmChartRepository (cluster-scoped):**
1. Create HelmChartRepository (cluster-scoped)
2. Open **CA Certificate** dropdown
3. ✅ **Verify**: Shows ConfigMaps from `openshift-config` namespace (correct behavior)

### Test 4: End-to-End Repository Test

1. Use the pre-configured `test-basic-auth-repo` created by the setup
2. Navigate: **Developer** → **+Add** → **Helm Chart**
3. ✅ **Verify**: Charts from `test-basic-auth-repo` appear in catalog
4. Select a chart
5. ✅ **Verify**: Install form loads (proves authentication worked)

## Manual Setup (Alternative)

If you prefer manual setup without the scripts:

### On EC2:
```bash
./setup-basic-auth-repo.sh <EC2_PUBLIC_IP> full
```

This script:
- Installs nginx
- Configures HTTPS with self-signed certificate
- Sets up HTTP Basic Auth
- Creates sample Helm chart repository
- Generates OpenShift YAML file

### On OpenShift:
```bash
oc new-project helm-auth-test

# Create Basic Auth secret
oc create secret generic helm-basic-auth \
  --from-literal=username=helmuser \
  --from-literal=password=HelmPass123! \
  -n helm-auth-test

# Create CA ConfigMap (use cert from EC2 /tmp/ca.crt)
oc create configmap helm-ca-cert \
  --from-file=ca-bundle.crt=/path/to/ca.crt \
  -n helm-auth-test

# Create repository via UI or YAML
```

## Credentials

- **Username**: `helmuser`
- **Password**: `HelmPass123!`
- **CA Certificate**: Generated on EC2 at `/tmp/ca.crt`
- **Repository URL**: `https://<EC2_IP>/`

## Related Issues

- **RFE-7965**: Add basic auth support for ProjectHelmChartRepository UI  
  https://issues.redhat.com/browse/RFE-7965

- **OCPBUGS-76328**: Helm Chart Repository form lists CA/TLS secrets from wrong namespace  
  https://issues.redhat.com/browse/OCPBUGS-76328

- **PR**: https://github.com/openshift/console/pull/15624
