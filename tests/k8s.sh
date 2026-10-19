#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:-freescout-custom}"
MANIFEST=deploy/kubernetes/freescout.yaml
CLUSTER=freescout-k8s-test
APP_NAMESPACE=freescout
DB_NAMESPACE=freescout-db
DB_PASS='db pass #1 & more'

on_exit() {
    local exit_status=$?
    if [ "${exit_status}" -ne 0 ]; then
        kubectl -n "${APP_NAMESPACE}" get pods,events >&2 || true
        kubectl -n "${APP_NAMESPACE}" logs deployment/freescout >&2 || true
    fi
    kind delete cluster --name "${CLUSTER}" >/dev/null 2>&1 || true
}
trap on_exit EXIT

kind create cluster --name "${CLUSTER}" --wait 120s

# Load the freshly built image under the exact reference of the manifest, so the manifest is applied unmodified.
manifest_image=$(sed -n 's/^ *image: //p' "${MANIFEST}")
docker tag "${IMAGE}" "${manifest_image}"
kind load docker-image --name "${CLUSTER}" "${manifest_image}"

kubectl create namespace "${DB_NAMESPACE}"
kubectl -n "${DB_NAMESPACE}" create secret generic mariadb --from-literal=password="${DB_PASS}"
kubectl -n "${DB_NAMESPACE}" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
spec:
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
        - name: mariadb
          image: mariadb:11
          env:
            - name: MARIADB_RANDOM_ROOT_PASSWORD
              value: "yes"
            - name: MARIADB_DATABASE
              value: freescout
            - name: MARIADB_USER
              value: freescout
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb
                  key: password
          readinessProbe:
            exec:
              command: [healthcheck.sh, --connect, --innodb_initialized]
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
spec:
  selector:
    app: mariadb
  ports:
    - port: 3306
EOF
kubectl -n "${DB_NAMESPACE}" rollout status deployment/mariadb --timeout=300s

kubectl create namespace "${APP_NAMESPACE}"
kubectl label namespace "${APP_NAMESPACE}" pod-security.kubernetes.io/enforce=restricted
kubectl -n "${APP_NAMESPACE}" create configmap freescout-config \
    --from-literal=APP_URL=https://freescout.example.com \
    --from-literal=DB_TYPE=mariadb \
    --from-literal=DB_HOST="mariadb.${DB_NAMESPACE}.svc.cluster.local" \
    --from-literal=DB_NAME=freescout \
    --from-literal=DB_USER=freescout \
    --from-literal=ADMIN_EMAIL=admin@example.com
kubectl -n "${APP_NAMESPACE}" create secret generic freescout-secrets \
    --from-literal=DB_PASS="${DB_PASS}" \
    --from-literal=ADMIN_PASS='Admin pass #1 & more'
kubectl -n "${APP_NAMESPACE}" apply -f "${MANIFEST}"
kubectl -n "${APP_NAMESPACE}" rollout status deployment/freescout --timeout=600s

# The recreated pod starts after the Service exists, which is when kubelet would inject the service links.
kubectl -n "${APP_NAMESPACE}" rollout restart deployment/freescout
kubectl -n "${APP_NAMESPACE}" rollout status deployment/freescout --timeout=600s
if kubectl -n "${APP_NAMESPACE}" exec deployment/freescout -- grep -q '^SERVICE_HOST=' /data/.env; then
    echo "FAIL: Kubernetes service links leaked into .env" >&2
    exit 1
fi

echo "PASS"
