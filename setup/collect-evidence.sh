#!/usr/bin/env bash
# Bundle everything observed during one session into a timestamped tarball.
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-/tmp/interview-sandbox}"
CLUSTER_NAME="${CLUSTER_NAME:-interview-sandbox}"
CC_CONFIG="$SANDBOX_ROOT/cc-config"
SANDBOX_HOME="$SANDBOX_ROOT/home"
WORKSPACE_ROOT="$SANDBOX_ROOT/workspace"
WORKSPACE="$WORKSPACE_ROOT/k8s-exercise"
EVIDENCE="$SANDBOX_ROOT/evidence"
ARCHIVE="$EVIDENCE/archive"
# Sanitised: the label reaches mkdir/tar/rm -rf, so a '../' in it would escape.
LABEL="$(printf '%s' "${1:-session}" | tr -cs 'A-Za-z0-9._-' '-')"
[[ -n "$LABEL" ]] || LABEL="session"

case "$SANDBOX_ROOT" in
  /tmp/*|/private/tmp/*) ;;
  *) printf 'ERROR: SANDBOX_ROOT must be under /tmp\n' >&2; exit 1 ;;
esac
[[ -d "$SANDBOX_ROOT" ]] || { printf 'ERROR: no sandbox at %s\n' "$SANDBOX_ROOT" >&2; exit 1; }

export KUBECONFIG="$SANDBOX_HOME/.kube/config"
# Keep kubectl/helm caches inside the sandbox instead of the operator's HOME.
export HOME="$SANDBOX_HOME"
export HELM_CACHE_HOME="$SANDBOX_ROOT/.cache/helm" HELM_CONFIG_HOME="$SANDBOX_ROOT/.config/helm" \
       HELM_DATA_HOME="$SANDBOX_ROOT/.local/helm"
KUBECTL_CACHE=(--cache-dir "$SANDBOX_ROOT/.cache/kube")
TS="$(date +%Y%m%d-%H%M%S)"
NAME="evidence-${TS}-${LABEL}"
STAGE="$ARCHIVE/$NAME"
mkdir -p "$STAGE"
# Belt and braces: the staging dir must resolve inside evidence/archive.
[[ "$(cd "$STAGE" && pwd -P)" == "$(cd "$ARCHIVE" && pwd -P)/$NAME" ]] \
  || { printf 'ERROR: refusing to stage outside %s\n' "$ARCHIVE" >&2; exit 1; }

# 1. the passive audit log
for f in audit.jsonl preflight-audit.jsonl audit-hook.err candidate-shell-history; do
  [[ -f "$EVIDENCE/$f" ]] && cp "$EVIDENCE/$f" "$STAGE/$f"
done

# bash writes history timestamps as bare '#<epoch>' lines. Render a readable
# copy so the interviewer can line the candidate's own commands up against the
# agent's audit.jsonl by clock time.
if [[ -f "$STAGE/candidate-shell-history" ]]; then
  python3 - "$STAGE/candidate-shell-history" "$STAGE/candidate-shell-history.txt" <<'PY' || true
import datetime, sys
src, dst = sys.argv[1], sys.argv[2]
ts = ""
with open(src, errors="replace") as fh, open(dst, "w") as out:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("#") and line[1:].strip().isdigit():
            ts = datetime.datetime.fromtimestamp(
                int(line[1:].strip()), datetime.timezone.utc
            ).strftime("%Y-%m-%dT%H:%M:%SZ")
            continue
        out.write(f"{ts or '(no timestamp)':21}  {line}\n")
PY
fi

# 2. session transcripts from the isolated profile
if [[ -d "$CC_CONFIG/projects" ]]; then
  mkdir -p "$STAGE/transcripts"
  ( cd "$CC_CONFIG" && find projects -name '*.jsonl' -print0 | xargs -0 tar cf - ) \
    | tar xf - -C "$STAGE/transcripts"
fi

# 3. primary evidence: guardrails the candidate authored
mkdir -p "$STAGE/candidate-config"
for f in "$CC_CONFIG/CLAUDE.md" "$CC_CONFIG/settings.json" "$CC_CONFIG/settings.local.json" \
         "$CC_CONFIG/mcp.json" "$CC_CONFIG/.claude.json"; do
  [[ -f "$f" ]] && cp "$f" "$STAGE/candidate-config/profile-$(basename "$f")"
done
for f in "$EVIDENCE"/settings-before-bootstrap-*.json "$EVIDENCE"/hooks-before-bootstrap-*/; do
  [[ -e "$f" ]] && cp -R "$f" "$STAGE/candidate-config/$(basename "$f")"
done
# Hook scripts the candidate wrote are the highest-value artifact; settings.json
# only references them by path.
[[ -d "$CC_CONFIG/hooks" ]] && cp -R "$CC_CONFIG/hooks" "$STAGE/candidate-config/profile-hooks"
for f in "$WORKSPACE/CLAUDE.md" "$WORKSPACE/AGENTS.md" "$WORKSPACE/.mcp.json"; do
  [[ -f "$f" ]] && cp "$f" "$STAGE/candidate-config/repo-$(basename "$f")"
done
[[ -d "$WORKSPACE/.claude" ]] && cp -R "$WORKSPACE/.claude" "$STAGE/candidate-config/repo-dot-claude"

# 4. what changed in the repo
for repo in "$WORKSPACE_ROOT"/*/; do
  [[ -d "$repo/.git" ]] || continue
  r=$(basename "$repo")
  git -C "$repo" log -p --stat --all > "$STAGE/$r-git-log-p.txt" 2>&1 || true
  git -C "$repo" diff > "$STAGE/$r-git-diff-unstaged.txt" 2>&1 || true
  git -C "$repo" diff --cached > "$STAGE/$r-git-diff-staged.txt" 2>&1 || true
  git -C "$repo" status --porcelain --ignored > "$STAGE/$r-git-status.txt" 2>&1 || true
done
# A copy of the workspace, uncommitted work included, so the review can run on another machine.
mkdir -p "$STAGE/workspace"
tar -C "$WORKSPACE_ROOT" -cf - --exclude='charts/*/charts' --exclude='apps/*/charts' --exclude='Chart.lock' . \
  | tar -C "$STAGE/workspace" -xf - || true

# 5. cluster state, including the live probes (shows a half-landed fix)
{
  echo "### kubectl get pods -A -o wide"; kubectl "${KUBECTL_CACHE[@]}" get pods -A -o wide 2>&1
  echo; echo "### events (last 120)"; kubectl "${KUBECTL_CACHE[@]}" get events -A --sort-by=.lastTimestamp 2>&1 | tail -120
  echo; echo "### helm releases"; helm list -A 2>&1
} > "$STAGE/cluster-state.txt" || true
kubectl "${KUBECTL_CACHE[@]}" get deploy -A -o yaml > "$STAGE/cluster-deployments.yaml" 2>&1 || true

TARBALL="$ARCHIVE/$NAME.tar.gz"
tar czf "$TARBALL" -C "$ARCHIVE" "$NAME"
rm -rf "$STAGE"

printf '\nevidence bundle: %s\n\n' "$TARBALL"
