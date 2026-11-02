#!/usr/bin/env bash
# Run BEFORE rebooting or shutting down TrueNAS (or the Proxmox host under it).
#
# TrueNAS takes about three minutes to come back. The cluster's iSCSI initiators
# only wait two, after which ext4 aborts its journal and remounts the volume
# read-only, and nothing recovers it until the pod is deleted. Stopping the apps
# first lets the volumes unmount cleanly instead.
#
# This script:
#   1. finds every workload that mounts a $STORAGE_CLASS volume,
#   2. suspends the Flux 'apps' Kustomization so Flux cannot scale them back up,
#   3. scales them to zero,
#   4. waits until Kubernetes reports every iSCSI volume detached.
# It only prints "safe to reboot" once step 4 has succeeded. The previous replica
# counts are saved so post-reboot.sh can put things back exactly as they were.
#
# Usage: bash scripts/truenas-maintenance/pre-reboot.sh [-n|--dry-run] [-y|--yes]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

DETACH_TIMEOUT="${DETACH_TIMEOUT:-300}"
DRY_RUN=0
ASSUME_YES=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n | --dry-run) DRY_RUN=1 ;;
    -y | --yes) ASSUME_YES=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

require_cluster

if [ -s "$STATE_FILE" ]; then
  die "$STATE_FILE already exists, so a previous run has not been restored.
Run post-reboot.sh first. If you are sure nothing is still scaled down, delete that file and try again."
fi

workloads=$(workloads_on_storage) ||
  die "some pods using $STORAGE_CLASS cannot be scaled down; deal with them by hand before rebooting TrueNAS"

if [ -z "$workloads" ]; then
  log "Nothing uses the $STORAGE_CLASS StorageClass, so there is nothing to stop."
  exit 0
fi

log "Workloads using $STORAGE_CLASS (context $KUBE_CONTEXT):"
while IFS='|' read -r kind ns name rep; do
  printf '  %-12s %-30s replicas %s\n' "$kind" "$ns/$name" "$rep"
done <<<"$workloads"

before=$(attachments)
log ""
log "iSCSI volumes currently attached: $(printf '%s' "$before" | grep -c . || true)"

flux_was_suspended=$(k -n "$FLUX_NAMESPACE" get kustomization "$FLUX_KUSTOMIZATION" -o jsonpath='{.spec.suspend}')
if [ "$flux_was_suspended" = "true" ]; then
  flux_by_script=0
  log "Flux Kustomization '$FLUX_KUSTOMIZATION' is already suspended; leaving it that way afterwards."
else
  flux_by_script=1
  log "Flux Kustomization '$FLUX_KUSTOMIZATION' will be suspended."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log ""
  log "Dry run: nothing was changed and no state file was written."
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  [ -t 0 ] || die "not running in a terminal; pass --yes to confirm without a prompt"
  printf '\nScale these down now? Their apps will be offline until post-reboot.sh runs. [y/N] '
  read -r answer
  case "$answer" in y | Y | yes) ;; *) log "Aborted."; exit 1 ;; esac
fi

# Save the plan BEFORE changing anything, so a failure part-way through can
# still be undone with post-reboot.sh.
{
  printf '# written by pre-reboot.sh on %s\n' "$(date)"
  printf 'context|%s\n' "$KUBE_CONTEXT"
  printf 'flux|%s\n' "$flux_by_script"
  while IFS='|' read -r kind ns name rep; do
    printf 'workload|%s|%s|%s|%s\n' "$kind" "$ns" "$name" "$rep"
  done <<<"$workloads"
} >"$STATE_FILE"
log "Saved previous replica counts to $STATE_FILE"

if [ "$flux_by_script" -eq 1 ]; then
  k -n "$FLUX_NAMESPACE" patch kustomization "$FLUX_KUSTOMIZATION" --type merge -p '{"spec":{"suspend":true}}' >/dev/null
  log "Suspended Flux Kustomization '$FLUX_KUSTOMIZATION'."
fi

while IFS='|' read -r kind ns name rep; do
  k -n "$ns" scale "$kind/$name" --replicas=0 >/dev/null
  log "Scaled $ns/$name to 0 (was $rep)."
done <<<"$workloads"

log ""
log "Waiting up to ${DETACH_TIMEOUT}s for the volumes to unmount and detach..."
deadline=$((SECONDS + DETACH_TIMEOUT))
while :; do
  left=$(attachments)
  [ -z "$left" ] && break
  if [ "$SECONDS" -ge "$deadline" ]; then
    printf '%s\n' "$left" >&2
    die "volumes are still attached after ${DETACH_TIMEOUT}s. Do NOT reboot TrueNAS yet.
Look at 'kubectl --context $KUBE_CONTEXT get pods -A' for stuck Terminating pods. Run post-reboot.sh to undo everything."
  fi
  log "  $(printf '%s\n' "$left" | grep -c .) volume(s) still attached..."
  sleep 5
done

log ""
log "All iSCSI volumes are detached. It is SAFE to reboot or shut down TrueNAS now."
log "When it is back up, run: bash scripts/truenas-maintenance/post-reboot.sh"
