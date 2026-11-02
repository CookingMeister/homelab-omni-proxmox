#!/usr/bin/env bash
# Run AFTER TrueNAS is back up, to undo pre-reboot.sh.
#
# This script:
#   1. waits for the TrueNAS API and its iSCSI port (3260) to answer,
#   2. restarts the democratic-csi controller, whose sidecars crash-loop while
#      TrueNAS is away and would otherwise take up to five minutes to retry,
#   3. scales every workload back to the replica count saved by pre-reboot.sh,
#   4. waits for each rollout, resumes Flux if pre-reboot.sh suspended it,
#   5. checks that every TrueNAS volume is mounted read-write.
#
# --check-only skips straight to step 5. It needs no state file and is a handy
# health check at any time: a volume that went read-only (emergency_ro) leaves
# its app running but unable to save.
#
# Usage: bash scripts/truenas-maintenance/post-reboot.sh [-n|--dry-run] [--check-only]
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$here/lib.sh"

WAIT_TRUENAS="${WAIT_TRUENAS:-900}"
SETTLE_SECONDS="${SETTLE_SECONDS:-30}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
DRY_RUN=0
CHECK_ONLY=0

usage() {
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '/^set -euo/d' -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n | --dry-run) DRY_RUN=1 ;;
    --check-only) CHECK_ONLY=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option '$1' (try --help)" ;;
  esac
  shift
done

# True once the TrueNAS API answers (401 is the expected reply to an
# unauthenticated request, so no credentials are used) and iSCSI is listening.
truenas_up() {
  local code
  code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$TRUENAS_HOST/api/v2.0/system/version" 2>/dev/null) || code=000
  case "$code" in 200 | 401 | 403) ;; *) return 1 ;; esac
  (timeout 3 bash -c "echo > /dev/tcp/$TRUENAS_HOST/3260") 2>/dev/null
}

# Every pod holding a TrueNAS volume must have it mounted read-write. Reads
# /proc/mounts inside the pod; an unreadable pod is a warning, a read-only
# mount is a failure.
check_rw_mounts() {
  local pods ns pod claim owner vol paths path mounts state bad=0 checked=0
  pods=$(pods_on_storage) || return 1
  [ -n "$pods" ] || { log "No pods are using $STORAGE_CLASS right now."; return 0; }

  while IFS='|' read -r ns pod claim owner; do
    [ -n "$ns" ] || continue
    vol=$(k -n "$ns" get pod "$pod" -o jsonpath="{range .spec.volumes[?(@.persistentVolumeClaim.claimName==\"$claim\")]}{.name}{end}")
    paths=$(k -n "$ns" get pod "$pod" -o jsonpath="{range .spec.containers[*].volumeMounts[?(@.name==\"$vol\")]}{.mountPath}{\"\\n\"}{end}" | sort -u)
    if ! mounts=$(k -n "$ns" exec "$pod" -- cat /proc/mounts 2>/dev/null); then
      warn "could not read /proc/mounts in $ns/$pod (not running yet?)"
      continue
    fi
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      state=$(printf '%s\n' "$mounts" | awk -v p="$path" '
        $2 == p { found = 1; n = split($4, o, ","); for (i = 1; i <= n; i++) if (o[i] == "ro" || o[i] == "emergency_ro") ro = 1 }
        END { print (!found ? "missing" : ro ? "READ-ONLY" : "ok") }')
      checked=$((checked + 1))
      if [ "$state" = "ok" ]; then
        printf '  ok         %s/%s:%s\n' "$ns" "$pod" "$path"
      else
        printf '  %-10s %s/%s:%s\n' "$state" "$ns" "$pod" "$path"
        bad=$((bad + 1))
      fi
    done <<<"$paths"
  done <<<"$pods"

  if [ "$bad" -gt 0 ]; then
    warn "$bad of $checked volume mount(s) are not read-write. Snapshot the volume in TrueNAS, then delete the pod so it remounts."
    return 1
  fi
  log "All $checked TrueNAS volume mount(s) are read-write."
}

require_cluster

if [ "$CHECK_ONLY" -eq 1 ]; then
  log "Checking TrueNAS volume mounts (context $KUBE_CONTEXT):"
  check_rw_mounts
  exit 0
fi

[ -f "$STATE_FILE" ] ||
  die "no state file at $STATE_FILE, so pre-reboot.sh has not been run (or it was already restored).
Use --check-only to just verify the volumes."

workloads=()
flux_by_script=0
state_context=""
while IFS='|' read -r tag a b c d; do
  case "$tag" in
    context) state_context=$a ;;
    flux) flux_by_script=$a ;;
    workload) workloads+=("$a|$b|$c|$d") ;;
  esac
done <"$STATE_FILE"

[ "$state_context" = "$KUBE_CONTEXT" ] ||
  die "the state file was written for context '$state_context' but this run uses '$KUBE_CONTEXT'"
[ "${#workloads[@]}" -gt 0 ] || die "the state file lists no workloads; delete $STATE_FILE if that is correct"

log "Will restore (context $KUBE_CONTEXT):"
for w in "${workloads[@]}"; do
  IFS='|' read -r kind ns name rep <<<"$w"
  printf '  %-12s %-30s replicas %s\n' "$kind" "$ns/$name" "$rep"
done

if [ "$DRY_RUN" -eq 1 ]; then
  if truenas_up; then log "TrueNAS ($TRUENAS_HOST) is answering."; else log "TrueNAS ($TRUENAS_HOST) is NOT answering yet."; fi
  log "Dry run: nothing was changed."
  exit 0
fi

log ""
log "Waiting up to ${WAIT_TRUENAS}s for TrueNAS ($TRUENAS_HOST): API and iSCSI port 3260..."
deadline=$((SECONDS + WAIT_TRUENAS))
until truenas_up; do
  [ "$SECONDS" -lt "$deadline" ] ||
    die "TrueNAS did not come back within ${WAIT_TRUENAS}s. The apps are still scaled down; fix TrueNAS and run this again."
  sleep 10
done
log "TrueNAS is answering. Giving the pool and iSCSI targets ${SETTLE_SECONDS}s to settle..."
sleep "$SETTLE_SECONDS"

log "Restarting the democratic-csi controller so it reconnects at once..."
k -n "$CSI_NAMESPACE" rollout restart "deployment/$CSI_CONTROLLER" >/dev/null
k -n "$CSI_NAMESPACE" rollout status "deployment/$CSI_CONTROLLER" --timeout=180s >/dev/null ||
  warn "the CSI controller is not ready yet; new volumes may fail until it is"

for w in "${workloads[@]}"; do
  IFS='|' read -r kind ns name rep <<<"$w"
  k -n "$ns" scale "$kind/$name" --replicas="$rep" >/dev/null
  log "Scaled $ns/$name back to $rep."
done

failed=0
for w in "${workloads[@]}"; do
  IFS='|' read -r kind ns name rep <<<"$w"
  if k -n "$ns" rollout status "$kind/$name" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null; then
    log "  $ns/$name is ready."
  else
    warn "$ns/$name did not become ready within ${ROLLOUT_TIMEOUT}s"
    failed=1
  fi
done

if [ "$flux_by_script" = "1" ]; then
  k -n "$FLUX_NAMESPACE" patch kustomization "$FLUX_KUSTOMIZATION" --type merge -p '{"spec":{"suspend":false}}' >/dev/null
  k -n "$FLUX_NAMESPACE" annotate kustomization "$FLUX_KUSTOMIZATION" --overwrite "reconcile.fluxcd.io/requestedAt=$(date +%s)" >/dev/null
  log "Resumed Flux Kustomization '$FLUX_KUSTOMIZATION'."
fi

log ""
log "Checking the volumes are read-write:"
check_rw_mounts || failed=1

if [ "$failed" -eq 0 ]; then
  rm -f "$STATE_FILE"
  log ""
  log "Done. Everything is back and the state file has been removed."
else
  warn "Finished with problems. The state file was kept at $STATE_FILE; fix the issues above, then run this again."
  exit 1
fi
