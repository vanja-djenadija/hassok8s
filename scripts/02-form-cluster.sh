#!/usr/bin/env bash
# =============================================================
#  02 — Formiranje HA klastera
#  Pokrenuti SAMO na prvom čvoru (n00).
#  Generiše komande za pridruživanje koje se pokreću na n01 i n02.
#
#  microk8s automatski uključuje HA kontrolnu ravan (dqlite)
#  kada klaster dostigne tri čvora. Nema ručne etcd/keepalived
#  konfiguracije kao kod kubeadm-a.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==> Generisanje tokena za pridruživanje n01"
echo "    Na čvoru ${NODE1_NAME} (${NODE1_IP}) pokrenite komandu koju"
echo "    ispiše sljedeća linija:"
echo ""
microk8s add-node
echo ""
echo "------------------------------------------------------------"
echo " Pokrenite gornju 'microk8s join ...' komandu na n01."
echo " Zatim se vratite ovdje i pritisnite ENTER za token za n02."
echo "------------------------------------------------------------"
read -r _

echo "==> Generisanje tokena za pridruživanje n02"
microk8s add-node
echo ""
echo "------------------------------------------------------------"
echo " Pokrenite gornju 'microk8s join ...' komandu na n02."
echo "------------------------------------------------------------"
echo ""
echo "Kada oba čvora budu pridružena, provjerite stanje sa:"
echo "    microk8s kubectl get nodes"
echo "    microk8s status"
echo ""
echo "Klaster sa tri čvora automatski prelazi u HA režim."
echo "DONE."
