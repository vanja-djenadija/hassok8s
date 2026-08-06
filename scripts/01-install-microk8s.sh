#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config.env"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: config.env not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run this script as root or via sudo." >&2
  exit 1
fi

RUN_USER="${SUDO_USER:-${USER}}"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6 || true)"
if [[ -z "${RUN_HOME}" ]]; then
  RUN_HOME="/home/${RUN_USER}"
fi

echo "==> [1/4] Installing microk8s (channel ${MICROK8S_CHANNEL})"
if snap list microk8s >/dev/null 2>&1; then
  echo "    microk8s is already installed; skipping installation."
else
  snap install microk8s --classic --channel="${MICROK8S_CHANNEL}"
fi

echo "==> [2/4] Allowing user '${RUN_USER}' to use microk8s"
usermod -a -G microk8s "${RUN_USER}" || true
mkdir -p "${RUN_HOME}/.kube" || true
chown -R "${RUN_USER}:${RUN_USER}" "${RUN_HOME}/.kube" || true

echo "==> [3/4] Waiting for microk8s to become ready"
microk8s status --wait-ready --timeout 300

echo "==> [4/4] Verification"
microk8s kubectl get nodes -o wide

echo ""
echo "DONE: microk8s installed/verified on $(hostname)."
echo "Note: log out and log back in, or run 'newgrp microk8s',"
echo "so that the microk8s group membership takes effect."
