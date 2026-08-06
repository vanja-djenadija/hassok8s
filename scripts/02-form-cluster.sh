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

KC="microk8s kubectl"

echo "==> Checking the initial node"
microk8s status --wait-ready --timeout 300
${KC} get nodes -o wide

echo ""
echo "==> Generating join token for ${NODE1_NAME} (${NODE1_IP})"
echo "    On node ${NODE1_NAME}, run the command printed below:"
echo ""
microk8s add-node

echo ""
echo "------------------------------------------------------------"
echo " Run the 'microk8s join ...' command above on ${NODE1_NAME}."
echo " Then return here and press ENTER to generate the token for ${NODE2_NAME}."
echo "------------------------------------------------------------"
read -r _

echo "==> Generating join token for ${NODE2_NAME} (${NODE2_IP})"
echo "    On node ${NODE2_NAME}, run the command printed below:"
echo ""
microk8s add-node

echo ""
echo "------------------------------------------------------------"
echo " Run the 'microk8s join ...' command above on ${NODE2_NAME}."
echo " When the node has joined, return here and press ENTER."
echo "------------------------------------------------------------"
read -r _

echo "==> Waiting for all three nodes to become Ready"
MAX_TRIES=120
READY_NODES="0"
for i in $(seq 1 "${MAX_TRIES}"); do
  READY_NODES="$(${KC} get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
  TOTAL_NODES="$(${KC} get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "    [$i/${MAX_TRIES}] Ready nodes: ${READY_NODES}/3 (registered total: ${TOTAL_NODES})"
  if [[ "${READY_NODES}" == "3" ]]; then
    break
  fi
  sleep 5
done

if [[ "${READY_NODES}" != "3" ]]; then
  echo "ERROR: not all three nodes became Ready." >&2
  ${KC} get nodes -o wide >&2 || true
  exit 1
fi

echo ""
echo "==> Cluster state"
${KC} get nodes -o wide
microk8s status

echo ""
echo "DONE: cluster formed. Check that microk8s status reports high-availability: yes."
