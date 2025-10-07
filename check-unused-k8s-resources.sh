#!/usr/bin/env bash
# -------------------------------------------------------------------------
# Script: check-unused-k8s-resources.sh
# Description: Identify and optionally clean unused or orphaned K8s resources.
# Author: GPT-5
# -------------------------------------------------------------------------
# Usage:
#   ./check-unused-k8s-resources.sh                # Read-only scan (default namespace: prod)
#   ./check-unused-k8s-resources.sh -n staging     # Specify namespace
#   ./check-unused-k8s-resources.sh --clean        # Interactive cleanup
#   ./check-unused-k8s-resources.sh -n dev --clean # Clean a specific namespace
# -------------------------------------------------------------------------

set -euo pipefail

# --- Default Values ---
NAMESPACE="prod"
CLEAN_MODE=false
DATE=$(date +%Y-%m-%d_%H-%M-%S)
OUTPUT_FILE="unused-k8s-resources-${DATE}.log"

# --- Color Output ---
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
RESET="\033[0m"

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace)
      NAMESPACE="$2"; shift 2;;
    --clean)
      CLEAN_MODE=true; shift;;
    -h|--help)
      echo "Usage: $0 [-n NAMESPACE] [--clean]"
      exit 0;;
    *)
      echo "Unknown option: $1" && exit 1;;
  esac
done

# --- Banner ---
echo -e "${BLUE}🔍 Checking unused Kubernetes resources in namespace: ${NAMESPACE}${RESET}"
echo "Results will be saved to: ${OUTPUT_FILE}"
echo "------------------------------------------------------------" | tee "${OUTPUT_FILE}"

# --- Validate Namespace ---
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${RED}❌ Namespace '${NAMESPACE}' not found.${RESET}"
  exit 1
fi

# --- Helper Functions ---
function print_section() {
  echo -e "\n${YELLOW}# $1${RESET}" | tee -a "${OUTPUT_FILE}"
}

function confirm_delete() {
  local kind="$1"
  local list="$2"
  if [[ "${CLEAN_MODE}" == true && -n "${list}" ]]; then
    echo ""
    read -p "🧹 Delete these ${kind}? (y/N): " ans
    if [[ "${ans}" =~ ^[Yy]$ ]]; then
      echo "${list}" | while read -r res; do
        [[ -z "${res}" ]] && continue
        echo -e "${RED}Deleting ${res}...${RESET}"
        kubectl delete "${res}" -n "${NAMESPACE}" || echo "⚠️  Failed to delete ${res}"
      done
    else
      echo "❎ Skipped ${kind}"
    fi
  fi
}

# --- Collect Pod Data Once ---
PODS_YAML=$(kubectl get pods -n "${NAMESPACE}" -o yaml 2>/dev/null || echo "")

# --- 1. Pods not running ---
print_section "Pods not running (Failed, CrashLoopBackOff, Evicted, Completed)"
NOT_RUNNING=$(kubectl get pods -n "${NAMESPACE}" --field-selector=status.phase!=Running -o name 2>/dev/null || true)
echo "${NOT_RUNNING:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "pods" "${NOT_RUNNING}"

# --- 2. Unused ConfigMaps ---
print_section "Unreferenced ConfigMaps"
CONFIGMAPS=$(kubectl get configmaps -n "${NAMESPACE}" -o name | grep -v 'kube-root-ca.crt' || true)
UNUSED_CM=""
for cm in ${CONFIGMAPS}; do
  name=${cm#configmap/}
  if ! grep -q "${name}" <<< "${PODS_YAML}"; then
    UNUSED_CM+="${cm}\n"
  fi
done
if [[ -z "${UNUSED_CM// }" ]]; then echo "✅ None found" | tee -a "${OUTPUT_FILE}"; else echo -e "${UNUSED_CM}" | tee -a "${OUTPUT_FILE}"; fi
confirm_delete "configmaps" "${UNUSED_CM}"

# --- 3. Unused Secrets ---
print_section "Unreferenced Secrets"
SECRETS=$(kubectl get secrets -n "${NAMESPACE}" -o name | grep -v 'default-token' || true)
UNUSED_SEC=""
for sec in ${SECRETS}; do
  name=${sec#secret/}
  if ! grep -q "${name}" <<< "${PODS_YAML}"; then
    UNUSED_SEC+="${sec}\n"
  fi
done
if [[ -z "${UNUSED_SEC// }" ]]; then echo "✅ None found" | tee -a "${OUTPUT_FILE}"; else echo -e "${UNUSED_SEC}" | tee -a "${OUTPUT_FILE}"; fi
confirm_delete "secrets" "${UNUSED_SEC}"

# --- 4. Unbound PVCs ---
print_section "Unbound PersistentVolumeClaims"
PVCs=$(kubectl get pvc -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print "pvc/"$1}' || true)
echo "${PVCs:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "persistentvolumeclaims" "${PVCs}"

# --- 5. Services without endpoints ---
print_section "Services without endpoints"
SVCs=$(kubectl get svc -n "${NAMESPACE}" -o name || true)
UNUSED_SVC=""
for svc in ${SVCs}; do
  name=${svc#service/}
  EP=$(kubectl get endpoints -n "${NAMESPACE}" "${name}" -o jsonpath='{.subsets}' 2>/dev/null || echo "")
  [[ -z "${EP}" || "${EP}" == "null" ]] && UNUSED_SVC+="${svc}\n"
done
if [[ -z "${UNUSED_SVC// }" ]]; then echo "✅ None found" | tee -a "${OUTPUT_FILE}"; else echo -e "${UNUSED_SVC}" | tee -a "${OUTPUT_FILE}"; fi
confirm_delete "services" "${UNUSED_SVC}"

# --- 6. Deployments / ReplicaSets / Jobs / CronJobs ---
print_section "Deployments scaled to 0"
DEPLOY_0=$(kubectl get deploy -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.spec.replicas==0) | "deployment/" + .metadata.name' || true)
echo "${DEPLOY_0:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "deployments" "${DEPLOY_0}"

print_section "ReplicaSets with no Pods"
RS_EMPTY=$(kubectl get rs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.replicas==0) | "rs/" + .metadata.name' || true)
echo "${RS_EMPTY:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "replicasets" "${RS_EMPTY}"

print_section "Completed or Failed Jobs"
JOBS=$(kubectl get jobs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.succeeded==1 or .status.failed>=1) | "job/" + .metadata.name' || true)
echo "${JOBS:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "jobs" "${JOBS}"

print_section "CronJobs with no active jobs"
CRONJOBS=$(kubectl get cronjobs -n "${NAMESPACE}" -o json | jq -r '.items[] | select(.status.active==null) | "cronjob/" + .metadata.name' || true)
echo "${CRONJOBS:-✅ None found}" | tee -a "${OUTPUT_FILE}"
confirm_delete "cronjobs" "${CRONJOBS}"

# --- Done ---
echo -e "\n${GREEN}✅ Scan completed.${RESET} Results saved to ${OUTPUT_FILE}."
if [[ "${CLEAN_MODE}" == true ]]; then
  echo -e "${GREEN}🧹 Cleanup mode finished (only confirmed deletions were executed).${RESET}"
fi
