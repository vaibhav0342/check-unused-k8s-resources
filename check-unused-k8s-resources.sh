#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Script: check-unused-k8s-resources.sh
# Description: Identify and optionally clean unused or orphaned K8s resources
# Author: Vaibhav Upare 
# -------------------------------------------------------------------------
# Usage:
#   ./check-unused-k8s-resources.sh                # Read-only scan (default namespace: prod)
#   ./check-unused-k8s-resources.sh -n staging     # Specify namespace
#   ./check-unused-k8s-resources.sh --clean        # Interactive cleanup
#   ./check-unused-k8s-resources.sh -n dev --clean # Clean a specific namespace
#   ./check-unused-k8s-resources.sh --force --clean # Cleanup without confirmation (danger!)
# -------------------------------------------------------------------------

set -euo pipefail

######################################################################
# CONFIGURATION (can be overridden via environment vars or flags)
######################################################################
NAMESPACE="${NAMESPACE:-prod}"
CLEAN_MODE=false
FORCE_MODE=false
DATE=$(date +%Y-%m-%d_%H-%M-%S)
RUN_ID=$(uuidgen 2>/dev/null || echo "run-$RANDOM-$DATE")
LOG_DIR="${LOG_DIR:-./k8s-unused-logs}"
OUTPUT_FILE="${LOG_DIR}/unused-k8s-resources-${DATE}-${RUN_ID}.log"
BACKUP_DIR="${LOG_DIR}/backup-${DATE}-${RUN_ID}"

######################################################################
# COLOR OUTPUT
######################################################################
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
CYAN="\033[36m"
RESET="\033[0m"

######################################################################
# ARGUMENT PARSING
######################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      NAMESPACE="$2"; shift 2;;
    --clean)
      CLEAN_MODE=true; shift;;
    --force)
      FORCE_MODE=true; shift;;
    -h|--help)
      echo "Usage: $0 [-n <namespace>] [--clean] [--force]"
      exit 0;;
    *)
      echo "Unknown option: $1" >&2
      exit 1;;
  esac
done

######################################################################
# PRECHECKS
######################################################################
mkdir -p "${LOG_DIR}" "${BACKUP_DIR}"

if ! command -v kubectl >/dev/null; then
  echo -e "${RED}❌ kubectl not found in PATH${RESET}"
  exit 1
fi

if ! command -v jq >/dev/null; then
  echo -e "${RED}❌ jq is required but not installed${RESET}"
  exit 1
fi

if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${RED}❌ Namespace '${NAMESPACE}' not found${RESET}"
  exit 1
fi

######################################################################
# BANNER
######################################################################
echo -e "${CYAN}🔍 Starting scan: Namespace = ${NAMESPACE}${RESET}"
echo "LOG FILE   : ${OUTPUT_FILE}"
echo "RUN ID     : ${RUN_ID}"
echo "BACKUP DIR : ${BACKUP_DIR}"
echo "CLEAN MODE : ${CLEAN_MODE}"
echo "FORCE MODE : ${FORCE_MODE}"
echo "------------------------------------------------------------" | tee "${OUTPUT_FILE}"

######################################################################
# HELPERS
######################################################################
print_section() {
  echo -e "\n${YELLOW}# $1${RESET}" | tee -a "${OUTPUT_FILE}"
}

backup_resource() {
  local res="$1"
  kubectl get "$res" -n "${NAMESPACE}" -o yaml > "${BACKUP_DIR}/${res//\//_}.yaml" 2>/dev/null || true
}

delete_resources() {
  local kind="$1"
  local list="$2"

  [[ -z "${list// }" ]] && return 0

  if [[ "${CLEAN_MODE}" == false ]]; then
    echo -e "${YELLOW}❎ Skipping delete (read-only mode)${RESET}"
    return 0
  fi

  if [[ "${FORCE_MODE}" == false ]]; then
    echo ""
    read -p "🧹 Delete these ${kind}? (y/N): " ans
    [[ ! "${ans}" =~ ^[Yy]$ ]] && echo "❎ Skipped ${kind}" && return 0
  fi

  echo -e "${RED}⚠️ Deleting ${kind}...${RESET}"

  while read -r res; do
    [[ -z "${res}" ]] && continue
    echo -e "  🔒 Backing up: ${res}"
    backup_resource "${res}"

    echo -e "  ❌ Deleting: ${res}"
    kubectl delete "${res}" -n "${NAMESPACE}" || echo "⚠️ Failed to delete ${res}"
  done <<< "${list}"
}

######################################################################
# COLLECT POD YAML ONCE
######################################################################
PODS_YAML=$(kubectl get pods -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "")

######################################################################
# 1. Pods not running
######################################################################
print_section "Pods not running"
NOT_RUNNING=$(kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase!=Running -o name || true)
echo "${NOT_RUNNING:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "pods" "${NOT_RUNNING}"

######################################################################
# 2. Unused ConfigMaps
######################################################################
print_section "Unreferenced ConfigMaps"
CONFIGMAPS=$(kubectl get configmaps -n "${NAMESPACE}" -o name | grep -v 'kube-root-ca.crt' || true)
UNUSED_CM=""
while read -r cm; do
  name=${cm#configmap/}
  grep -q "${name}" <<< "${PODS_YAML}" || UNUSED_CM+="${cm}"$'\n'
done <<< "${CONFIGMAPS:-}"
echo -e "${UNUSED_CM:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "configmaps" "${UNUSED_CM}"

######################################################################
# 3. Unused Secrets
######################################################################
print_section "Unreferenced Secrets"
SECRETS=$(kubectl get secrets -n "${NAMESPACE}" -o name | grep -v 'default-token' || true)
UNUSED_SEC=""
while read -r sec; do
  name=${sec#secret/}
  grep -q "${name}" <<< "${PODS_YAML}" || UNUSED_SEC+="${sec}"$'\n'
done <<< "${SECRETS:-}"
echo -e "${UNUSED_SEC:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "secrets" "${UNUSED_SEC}"

######################################################################
# 4. Unbound PVCs
######################################################################
print_section "Unbound PVCs"
PVCs=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print "pvc/"$1}' || true)
echo "${PVCs:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "persistentvolumeclaims" "${PVCs}"

######################################################################
# 5. Services without endpoints
######################################################################
print_section "Services without endpoints"
SVCs=$(kubectl get svc -n "${NAMESPACE}" -o name || true)
UNUSED_SVC=""
while read -r svc; do
  name=${svc#service/}
  EP=$(kubectl get endpoints -n "${NAMESPACE}" "${name}" -o jsonpath='{.subsets}' 2>/dev/null || echo "")
  [[ -z "${EP}" || "${EP}" == "null" ]] && UNUSED_SVC+="${svc}"$'\n'
done <<< "${SVCs:-}"
echo -e "${UNUSED_SVC:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "services" "${UNUSED_SVC}"

######################################################################
# 6. Workload cleanup (Deploy / RS / Jobs / CronJobs)
######################################################################
print_section "Deployments scaled to 0"
DEPLOY_0=$(kubectl get deploy -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.spec.replicas==0) | "deployment/" + .metadata.name' || true)
echo "${DEPLOY_0:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "deployments" "${DEPLOY_0}"

print_section "ReplicaSets with no pods"
RS_EMPTY=$(kubectl get rs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.replicas==0) | "rs/" + .metadata.name' || true)
echo "${RS_EMPTY:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "replicasets" "${RS_EMPTY}"

print_section "Completed / Failed Jobs"
JOBS=$(kubectl get jobs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.succeeded==1 or .status.failed>=1) | "job/" + .metadata.name' || true)
echo "${JOBS:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "jobs" "${JOBS}"

print_section "CronJobs without active jobs"
CRONJOBS=$(kubectl get cronjobs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.active==null) | "cronjob/" + .metadata.name' || true)
echo "${CRONJOBS:-✅ None found}" | tee -a "${OUTPUT_FILE}"
delete_resources "cronjobs" "${CRONJOBS}"

######################################################################
# SUMMARY
######################################################################
echo -e "\n${GREEN}✔ Scan complete${RESET}"
echo "Log file    : ${OUTPUT_FILE}"
echo "Backups     : ${BACKUP_DIR}"
[[ "${CLEAN_MODE}" == true ]] && echo -e "${GREEN}🧹 Cleanup executed (backups created before deletion)${RESET}"
echo -e "${CYAN}Run ID: ${RUN_ID}${RESET}"
