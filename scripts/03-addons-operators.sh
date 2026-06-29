#!/usr/bin/env bash
# =============================================================
#  03 — Add-ons i operatori
#  Pokrenuti SAMO na n00 nakon što su sva tri čvora u klasteru.
#  Uključuje potrebne microk8s dodatke i instalira operatore
#  (CloudNativePG i Keycloak).
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

KC="microk8s kubectl"

echo "==> [1/5] DNS (interno razrješavanje imena servisa)"
microk8s enable dns

echo "==> [2/5] hostpath-storage (podrazumijevana storage klasa)"
# Obezbjeđuje StorageClass za PersistentVolumeClaim-ove (PostgreSQL).
microk8s enable hostpath-storage

echo "==> [3/5] ingress (nginx Ingress kontroler)"
microk8s enable ingress

echo "    Čekanje da klaster bude spreman..."
microk8s status --wait-ready --timeout 120

echo "==> [4/5] CloudNativePG operator (v${CNPG_VERSION})"
${KC} apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/${CNPG_RELEASE_BRANCH}/releases/cnpg-${CNPG_VERSION}.yaml"

# Ako je operator startovao prije nego su CRD-ovi kreirani (npr. usljed
# privremenog zaključavanja dqlite baze tokom formiranja klastera), pod
# ostaje u CrashLoopBackOff i ne oporavlja se sam ni nakon kreiranja CRD-ova.
# Restart osigurava da nova instanca operatora zatekne CRD-ove na mjestu.
${KC} rollout restart deployment/cnpg-controller-manager -n cnpg-system
${KC} rollout status deployment/cnpg-controller-manager -n cnpg-system --timeout=180s

echo "==> [5/5] Keycloak operator (v${KEYCLOAK_VERSION})"
BASE="https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/${KEYCLOAK_VERSION}/kubernetes"
${KC} apply -f "${BASE}/keycloaks.k8s.keycloak.org-v1.yml"
${KC} apply -f "${BASE}/keycloakrealmimports.k8s.keycloak.org-v1.yml"
${KC} apply -f "${BASE}/kubernetes.yml"
# Keycloak operator se instalira u podrazumijevani (default) namespace.
${KC} rollout status deployment/keycloak-operator --timeout=180s

echo ""
echo "==> Provjera"
${KC} get pods -n cnpg-system
${KC} get pods -l app.kubernetes.io/name=keycloak-operator

echo ""
echo "DONE: dodaci i operatori su aktivni."
