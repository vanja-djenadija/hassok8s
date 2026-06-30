#!/usr/bin/env bash
# =============================================================
#  06 — Provjera i prikupljanje dokaza
#  Pokrenuti na n00 nakon deploya. Snima izlaze u logs/ kao
#  materijal za pisanje rada (poglavlja implementacije i rezultata).
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config.env"

KC="microk8s kubectl"
OUT="${ROOT_DIR}/logs"
mkdir -p "${OUT}"

echo "==> [1] Stanje čvorova i HA klastera"
${KC} get nodes -o wide | tee "${OUT}/06-01-nodes.txt"
echo "" | tee -a "${OUT}/06-01-nodes.txt"
microk8s status | tee "${OUT}/06-02-microk8s-status.txt"

echo ""
echo "==> [2] Svi resursi u namespace-u ${NAMESPACE}"
${KC} get all -n "${NAMESPACE}" | tee "${OUT}/06-03-get-all.txt"

echo ""
echo "==> [3] Raspored podova po čvorovima (dokaz distribucije za HA)"
${KC} get pods -n "${NAMESPACE}" -o wide \
  --sort-by='{.spec.nodeName}' | tee "${OUT}/06-04-pod-placement.txt"

echo ""
echo "==> [4] PostgreSQL klaster (CNPG): stanje i uloge"
${KC} get cluster -n "${NAMESPACE}" | tee "${OUT}/06-05-pg-cluster.txt"
echo "" | tee -a "${OUT}/06-05-pg-cluster.txt"
${KC} get pods -n "${NAMESPACE}" \
  -l cnpg.io/cluster=keycloak-postgres -L role -o wide \
  | tee -a "${OUT}/06-05-pg-cluster.txt"

echo ""
echo "==> [5] Trajno skladištenje (PVC) — dokaz perzistencije baze"
${KC} get pvc -n "${NAMESPACE}" | tee "${OUT}/06-06-pvc.txt"

echo ""
echo "==> [6] Servisi (CNPG -rw/-ro/-r, Keycloak servis i discovery)"
${KC} get svc -n "${NAMESPACE}" | tee "${OUT}/06-07-services.txt"

echo ""
echo "==> [7] Ingress (ulazna tačka)"
${KC} get ingress -n "${NAMESPACE}" | tee "${OUT}/06-08-ingress.txt"

echo ""
echo "==> [8] Import realma (status Job-a)"
${KC} get job -n "${NAMESPACE}" | tee "${OUT}/06-09-realm-import.txt"

echo ""
echo "==> [9] Keycloak Infinispan clustering (replikacija sesija)"
{
  for POD in $(${KC} get pods -n "${NAMESPACE}" \
      -l app=keycloak -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "----- ${POD} -----"
    ${KC} logs "${POD}" -n "${NAMESPACE}" 2>/dev/null \
      | grep -iE "ISPN00094|received new cluster view|ISPN000094|members|Channel.*connected" \
      | tail -5 || echo "(nema clustering linija u ovom podu)"
  done
} | tee "${OUT}/06-10-clustering.txt"

echo ""
echo "==> [10] Health i Ready endpoint (interno, zaobilazi DNS/Ingress)"
KC_POD="$(${KC} get pods -n "${NAMESPACE}" -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo '')"
if [[ -n "${KC_POD}" ]]; then
  echo "Provjera /health/ready preko poda ${KC_POD}:" | tee "${OUT}/06-11-health.txt"
  ${KC} exec "${KC_POD}" -n "${NAMESPACE}" -- \
    curl -sk https://localhost:9000/health/ready \
    | tee -a "${OUT}/06-11-health.txt" || \
    echo "Health provjera nije uspjela (provjeriti ručno)." | tee -a "${OUT}/06-11-health.txt"
fi

echo ""
echo "==> [11] Realm '${REALM_NAME}' dostupan (interno preko servisa)"
if [[ -n "${KC_POD}" ]]; then
  ${KC} exec "${KC_POD}" -n "${NAMESPACE}" -- \
    curl -sk "https://localhost:8443/realms/${REALM_NAME}" \
    -o /dev/null -w "HTTP status za /realms/${REALM_NAME}: %{http_code}\n" \
    | tee "${OUT}/06-12-realm.txt" || \
    echo "Realm provjera nije uspjela." | tee "${OUT}/06-12-realm.txt"
fi

echo ""
echo "============================================================"
echo " DONE: dokazi snimljeni u ${OUT}/"
echo " Fajlovi 06-01 do 06-12 čine kompletan snimak stanja sistema."
echo "============================================================"