#!/usr/bin/env bash
# Archive the previous candidate's evidence, then tear the sandbox down.
set -euo pipefail

export SANDBOX_ROOT="${SANDBOX_ROOT:-/tmp/interview-sandbox}"
export CLUSTER_NAME="${CLUSTER_NAME:-interview-sandbox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE="$SANDBOX_ROOT/evidence"
LABEL="${1:-pre-reset}"

case "$SANDBOX_ROOT" in
  /tmp/*|/private/tmp/*) ;;
  *) printf 'ERROR: SANDBOX_ROOT must be under /tmp\n' >&2; exit 1 ;;
esac

say() { printf '==> %s\n' "$*"; }

if [[ -s "$EVIDENCE/audit.jsonl" || -s "$EVIDENCE/candidate-shell-history" \
      || -d "$SANDBOX_ROOT/cc-config/projects" ]]; then
  say "archiving the previous session before wiping"
  if ! "$SCRIPT_DIR/collect-evidence.sh" "$LABEL"; then
    if [[ "${FORCE:-0}" == "1" ]]; then
      say "WARNING: collect-evidence.sh failed, but FORCE=1 - wiping anyway"
    else
      printf '\nERROR: collect-evidence.sh failed. Refusing to wipe unarchived evidence.\n'  >&2
      printf '       Fix the archive step, or re-run with FORCE=1 to discard it.\n\n' >&2
      exit 1
    fi
  fi
fi

if command -v kind >/dev/null 2>&1; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    say "deleting kind cluster '$CLUSTER_NAME'"
    kind delete cluster --name "$CLUSTER_NAME" --kubeconfig "$SANDBOX_ROOT/home/.kube/config" >/dev/null
  fi
else
  say "kind not installed; skipping cluster teardown"
fi

# Wipe everything except evidence/archive.
for target in cc-config home workspace mcp .preflight start-session.sh start-shell.sh shell-rc; do
  path="$SANDBOX_ROOT/$target"
  [[ -e "$path" ]] || continue
  case "$path" in
    /tmp/*|/private/tmp/*) say "removing $path"; rm -rf "$path" ;;
    *) printf 'refusing to remove %s\n' "$path" >&2 ;;
  esac
done
# Also drop the per-session leftovers, so they cannot land in the NEXT
# candidate's bundle. evidence/archive is never touched.
rm -f "$EVIDENCE/audit.jsonl" "$EVIDENCE/preflight-audit.jsonl" "$EVIDENCE/audit-hook.err" \
      "$EVIDENCE/candidate-shell-history" "$EVIDENCE"/settings-before-bootstrap-*.json
rm -rf "$EVIDENCE"/hooks-before-bootstrap-* "$SANDBOX_ROOT/.cache" "$SANDBOX_ROOT/.config" \
       "$SANDBOX_ROOT/.local"

say "done. archives kept in $EVIDENCE/archive"
say "next: $SCRIPT_DIR/bootstrap.sh"
