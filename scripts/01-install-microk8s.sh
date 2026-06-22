#!/usr/bin/env bash
# =============================================================
#  01 — Instalacija microk8s
#  Pokrenuti na SVAKOM čvoru (n00, n01, n02).
#  microk8s sam odrađuje pripremu koju kod kubeadm-a radimo ručno
#  (containerd, mrežni sloj, CNI). Zato je ovaj korak kratak.
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config.env"

echo "==> [1/4] Instalacija microk8s (kanal ${MICROK8S_CHANNEL})"
# snap je predinstaliran na Ubuntu serverima.
snap install microk8s --classic --channel="${MICROK8S_CHANNEL}"

echo "==> [2/4] Dozvola trenutnom korisniku da koristi microk8s"
# Dodaje korisnika u grupu 'microk8s' da ne mora 'sudo' svaki put.
usermod -a -G microk8s "${SUDO_USER:-$USER}" || true
mkdir -p "/home/${SUDO_USER:-$USER}/.kube" || true
chown -R "${SUDO_USER:-$USER}" "/home/${SUDO_USER:-$USER}/.kube" || true

echo "==> [3/4] Čekanje da microk8s bude spreman"
microk8s status --wait-ready --timeout 300

echo "==> [4/4] Provjera"
microk8s kubectl get nodes

echo ""
echo "DONE: microk8s instaliran na $(hostname)."
echo "Napomena: odjavite se i prijavite ponovo (ili 'newgrp microk8s')"
echo "da bi članstvo u grupi 'microk8s' stupilo na snagu."
