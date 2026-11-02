# shellcheck shell=bash
# Shared settings and helpers for pre-reboot.sh and post-reboot.sh. Sourced, not run.
#
# Every setting can be overridden from the environment, for example:
#   KUBE_CONTEXT=bob bash scripts/truenas-maintenance/pre-reboot.sh

# Git Bash would otherwise rewrite arguments such as /proc/mounts into Windows
# paths before kubectl sees them. This switches that off for ARGUMENTS only.
# MSYS_NO_PATHCONV=1 must not be used here: it also stops Git Bash translating
# environment variables, so a POSIX-style KUBECONFIG=/c/a:/c/b reaches the
# Windows kubectl untouched and it fails with "filename syntax is incorrect".
export MSYS2_ARG_CONV_EXCL='*'

KUBE_CONTEXT="${KUBE_CONTEXT:-talos3}"
TRUENAS_HOST="${TRUENAS_HOST:-192.168.0.144}"
STORAGE_CLASS="${STORAGE_CLASS:-truenas-iscsi}"
CSI_ATTACHER="${CSI_ATTACHER:-org.democratic-csi.iscsi}"
CSI_NAMESPACE="${CSI_NAMESPACE:-democratic-csi}"
CSI_CONTROLLER="${CSI_CONTROLLER:-democratic-csi-iscsi-controller}"
FLUX_NAMESPACE="${FLUX_NAMESPACE:-flux-system}"
FLUX_KUSTOMIZATION="${FLUX_KUSTOMIZATION:-apps}"
# Written by pre-reboot.sh, consumed and deleted by post-reboot.sh. It lives
# outside the repo so it can never be committed.
STATE_FILE="${STATE_FILE:-$HOME/.truenas-maintenance.state}"

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
log() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_cluster() {
  # kubectl's stderr is left visible on purpose. This context signs in through
  # Omni (kubectl oidc-login), which prints its sign-in URL there when the login
  # has expired; hiding it makes an expired login look like an unreachable cluster.
  k get namespace kube-system >/dev/null ||
    die "cannot reach the cluster with kubectl context '$KUBE_CONTEXT'.
If the message above mentions a login or token, run 'kubectl --context $KUBE_CONTEXT get nodes'
once to sign in through the browser, then run this script again."
}

# One line per (pod, claim) pair for every live pod that mounts a PVC of
# $STORAGE_CLASS:  namespace|pod|claim|owner  (owner is Kind/name, or empty).
# Finished pods (Error, Completed) are ignored: they hold no mount.
pods_on_storage() {
  local claims
  claims=$(k get pvc -A -o jsonpath="{range .items[?(@.spec.storageClassName==\"$STORAGE_CLASS\")]}{.metadata.namespace}/{.metadata.name}{\"\\n\"}{end}") || return 1
  [ -n "$claims" ] || return 0

  k get pods -A --field-selector='status.phase!=Failed,status.phase!=Succeeded' \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{end}{"|"}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{","}{end}{"\n"}{end}' |
    CLAIMS="$claims" awk -F'|' '
      BEGIN { n = split(ENVIRON["CLAIMS"], a, "\n"); for (i = 1; i <= n; i++) want[a[i]] = 1 }
      {
        m = split($4, c, ",")
        for (i = 1; i <= m; i++)
          if (c[i] != "" && (($1 "/" c[i]) in want)) print $1 "|" $2 "|" c[i] "|" $3
      }'
}

# Map a pod's owner to the thing that can be scaled: "deployment|name" or
# "statefulset|name". Fails for anything else (bare pods, Jobs, ...).
resolve_workload() { # $1 namespace, $2 owner as Kind/name
  local kind=${2%%/*} name=${2#*/} parent
  case "$kind" in
    ReplicaSet)
      parent=$(k -n "$1" get replicaset "$name" -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}{"/"}{.name}{end}') || return 1
      case "$parent" in
        Deployment/*) printf 'deployment|%s\n' "${parent#*/}" ;;
        *) return 1 ;;
      esac
      ;;
    StatefulSet) printf 'statefulset|%s\n' "$name" ;;
    *) return 1 ;;
  esac
}

# One line per distinct scalable workload:  kind|namespace|name|replicas
# Returns 1 (after printing what it could resolve) if any pod uses the storage
# but cannot be scaled, because rebooting TrueNAS under it would not be safe.
workloads_on_storage() {
  local pods out="" rc=0 ns pod claim owner res kind name rep
  pods=$(pods_on_storage) || return 1
  while IFS='|' read -r ns pod claim owner; do
    [ -n "$ns" ] || continue
    if ! res=$(resolve_workload "$ns" "$owner"); then
      warn "pod $ns/$pod uses $claim but is owned by '${owner:-nothing}', not a Deployment or StatefulSet, so it cannot be scaled down for you"
      rc=1
      continue
    fi
    kind=${res%%|*}
    name=${res#*|}
    rep=$(k -n "$ns" get "$kind" "$name" -o jsonpath='{.spec.replicas}')
    out+="$kind|$ns|$name|${rep:-1}"$'\n'
  done <<<"$pods"
  printf '%s' "$out" | sort -u
  return $rc
}

# iSCSI volumes Kubernetes still considers attached to a node, one per line.
# Empty means every volume has been unmounted and detached.
attachments() {
  k get volumeattachments -o jsonpath="{range .items[?(@.spec.attacher==\"$CSI_ATTACHER\")]}{.spec.source.persistentVolumeName}{\" on \"}{.spec.nodeName}{\"\\n\"}{end}"
}
