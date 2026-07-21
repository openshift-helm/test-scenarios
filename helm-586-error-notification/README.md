# HELM-586: Error Notification for Invalid Helm Chart Repositories

Verify that users get a toast notification when Helm Chart repositories are misconfigured or unreachable, instead of charts silently disappearing from the Developer Catalog.

**PR**: https://github.com/openshift/console/pull/16792
**JIRA**: https://redhat.atlassian.net/browse/HELM-586

## Prerequisites

- OpenShift cluster with cluster-admin access
- EC2 instance (Debian/Ubuntu) with public IP and ports 22, 443 open
- SSH key at `../helm-test-2.pem`
- Console built from the `HELM-586` branch

## Setup

### 1. Deploy a private HTTPS Helm repository with basic auth

```bash
cd ../basic-auth-test
./run-setup.sh <EC2_IP> full
```

This creates an nginx server with HTTPS + basic auth (credentials: `helmuser` / `HelmPass123!`) and 3 sample charts.

### 2. Apply the good-credentials repo to the cluster

```bash
oc apply -f /tmp/openshift-helm-repo-setup.yaml
```

This creates in namespace `helm-test`:
- **ConfigMap** `helm-repo-ca` — CA certificate
- **Secret** `helm-basic-auth` — correct credentials
- **ProjectHelmChartRepository** `test-helm-repo` — working repo

### 3. Create a bad-credentials repo

```bash
oc create secret generic helm-bad-auth \
  -n helm-test \
  --from-literal=username=wronguser \
  --from-literal=password=wrongpass

cat <<'EOF' | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-bad-auth
  namespace: helm-test
spec:
  connectionConfig:
    url: https://<EC2_IP>
    ca:
      name: helm-repo-ca
    basicAuthConfig:
      name: helm-bad-auth
EOF
```

## Test Scenarios

### Scenario 1: Auth failure notification

1. Navigate to **Developer Catalog** (`/catalog/ns/helm-test`)
2. **Expected**: Red danger toast appears: `"Helm Chart repository error"` with content `"The following repositories are unreachable: test-bad-auth: authentication failed (HTTP 401)"`
3. Charts from `test-helm-repo` (good repo) still load normally
4. Toast auto-dismisses after ~8 seconds and is manually dismissible

### Scenario 2: Auth failure on Helm Charts filter

1. Navigate to **Developer Catalog** → filter by **Helm Charts** (`/catalog/ns/helm-test?catalogType=HelmChart`)
2. **Expected**: Same toast notification appears

### Scenario 3: Misconfigured Secret (wrong key names)

```bash
oc delete secret helm-bad-auth -n helm-test
oc create secret generic helm-bad-auth \
  -n helm-test \
  --from-literal=usenrame=helmuser \
  --from-literal=password='HelmPass123!'
```

1. Reload the Developer Catalog
2. **Expected**: Toast shows `"test-bad-auth: failed to find "username" key in secret 'helm-test/helm-bad-auth'"`

### Scenario 4: Unreachable repository

```bash
cat <<'EOF' | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-unreachable
  namespace: helm-test
spec:
  connectionConfig:
    url: https://192.0.2.1
EOF
```

1. Reload the Developer Catalog (may take ~5s due to connection timeout)
2. **Expected**: Toast mentions `"test-unreachable: ... context deadline exceeded"`

### Scenario 5: Multiple errors in one toast

With both `test-bad-auth` (wrong creds) and `test-unreachable` active:

1. Reload the Developer Catalog
2. **Expected**: Single toast listing both repos and their respective errors

### Scenario 6: Fix credentials — toast disappears

```bash
oc delete secret helm-bad-auth -n helm-test
oc create secret generic helm-bad-auth \
  -n helm-test \
  --from-literal=username=helmuser \
  --from-literal=password='HelmPass123!'
oc delete projecthelmchartrepository test-unreachable -n helm-test
```

1. Reload the Developer Catalog
2. **Expected**: No toast. Charts from both repos load.

### Scenario 7: Disabled repo — no toast

```bash
oc patch projecthelmchartrepository test-bad-auth -n helm-test \
  --type=merge -p '{"spec":{"disabled":true}}'
```

1. Reload the Developer Catalog
2. **Expected**: No toast for the disabled repo

### Scenario 8: Different namespace — no cross-bleed

1. Switch to a namespace that has no misconfigured repos
2. **Expected**: No toast

## Cleanup

```bash
oc delete namespace helm-test
```

## Error Types Covered

| Error type | Example message | Source |
|-----------|----------------|--------|
| Auth failure (401/403) | `authentication failed (HTTP 401)` | `IndexFile()` — wrong credentials |
| HTTP error (404, 500, etc.) | `failed to fetch index (HTTP 404)` | `IndexFile()` — server error |
| Connection timeout | `context deadline exceeded` | `IndexFile()` — unreachable host |
| Missing Secret key | `failed to find "username" key in secret 'ns/name'` | `List()` — misconfigured Secret |
| Secret not found | `Failed to GET secret "name" from "ns"` | `List()` — Secret doesn't exist |
| ConfigMap not found | `Failed to GET configmap name` | `List()` — CA ConfigMap missing |
| HTTPS required | `Basic authentication requires HTTPS repository` | `List()` — HTTP URL with basicAuth |
