#!/usr/bin/env bash
# Stand up a blank, fully recorded Claude Code interview sandbox. Safe to re-run.
set -euo pipefail

SANDBOX_ROOT="${SANDBOX_ROOT:-/tmp/interview-sandbox}"
CLUSTER_NAME="${CLUSTER_NAME:-interview-sandbox}"
REPO_BASE="${REPO_BASE:-https://github.com/eliya-gloat}"
WITH_CLUSTER="${WITH_CLUSTER:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CC_CONFIG="$SANDBOX_ROOT/cc-config"
SANDBOX_HOME="$SANDBOX_ROOT/home"
WORKSPACE_ROOT="$SANDBOX_ROOT/workspace"
WORKSPACE="$WORKSPACE_ROOT/k8s-exercise"
EVIDENCE="$SANDBOX_ROOT/evidence"
MCP_DIR="$SANDBOX_ROOT/mcp"
PREFLIGHT_DIR="$SANDBOX_ROOT/.preflight"
KUBECONFIG_FILE="$SANDBOX_HOME/.kube/config"
START_SCRIPT="$SANDBOX_ROOT/start-session.sh"
SHELL_SCRIPT="$SANDBOX_ROOT/start-shell.sh"
SHELL_RC="$SANDBOX_ROOT/shell-rc"

die() { printf '\nERROR: %s\n\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

# Everything this script writes must stay under /tmp. Never the real HOME.
case "$SANDBOX_ROOT" in
  /tmp/*|/private/tmp/*) ;;
  *) die "SANDBOX_ROOT must be under /tmp (got '$SANDBOX_ROOT')" ;;
esac

run_with_timeout() {
  local secs="$1"; shift
  local rc=0 pid killer
  # The callee must 'exec' its command so $pid is the command, not a subshell.
  "$@" & pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & killer=$!
  wait "$pid" || rc=$?
  kill "$killer" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------- preflight
say "preflight"

# Checked first: an MDM policy file invalidates the whole exercise.
MANAGED_DIR="/Library/Application Support/ClaudeCode"
if [[ -f "$MANAGED_DIR/CLAUDE.md" ]]; then
  cat >&2 <<EOF

WARNING: this machine has an MDM-managed policy file at
  $MANAGED_DIR/CLAUDE.md
Managed policy is injected into EVERY session and cannot be disabled by
CLAUDE_CONFIG_DIR or --settings, so the session would not start from a blank
profile.
Use a laptop that is not MDM-enrolled, or re-run with I_ACCEPT_MANAGED_POLICY=1
if you have read the file and accept it.

EOF
  [[ "${I_ACCEPT_MANAGED_POLICY:-0}" == "1" ]] || die "refusing to bootstrap on an MDM-managed laptop"
fi
if [[ -f "$MANAGED_DIR/managed-settings.json" ]]; then
  # Managed settings outrank CLAUDE_CONFIG_DIR, so a permissions or hooks block
  # there would apply inside the sandbox too.
  MANAGED_KEYS="$(python3 - "$MANAGED_DIR/managed-settings.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("UNPARSEABLE"); raise SystemExit(0)
print(",".join(k for k in ("permissions", "hooks") if k in data) or "OK")
PY
)"
  case "$MANAGED_KEYS" in
    OK) say "note: managed-settings.json is present; its env block (auth provider, telemetry, feature flags) still applies inside the sandbox" ;;
    UNPARSEABLE) say "WARNING: could not parse managed-settings.json; check it by hand for a permissions/hooks block" ;;
    *) die "managed-settings.json defines '$MANAGED_KEYS'. Managed settings beat CLAUDE_CONFIG_DIR, so that is a pre-installed guardrail with no escape hatch. Use a laptop that is not MDM-enrolled." ;;
  esac
fi

for tool in git python3 helm claude; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' not found on PATH"
done
# The task needs no cluster; WITH_CLUSTER=1 only gives the k8s-* MCP servers something real to reach.
if [[ "$WITH_CLUSTER" == "1" ]]; then
  command -v kubectl >/dev/null 2>&1 || die "'kubectl' not found. Install it: brew install kubectl"
  command -v docker >/dev/null 2>&1 || die "'docker' not found. Install Docker Desktop: brew install --cask docker"
  docker info >/dev/null 2>&1 || die "the Docker daemon is not running. Start Docker Desktop, then re-run this script."
  command -v kind >/dev/null 2>&1 || die "'kind' not found. Install it: brew install kind"
  # kind-cluster.yaml maps hostPort 8080; a squatter fails the cluster create late.
  if command -v lsof >/dev/null 2>&1 && lsof -ti :8080 >/dev/null 2>&1; then
    if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
      die "host port 8080 is already in use (kind-cluster.yaml maps it). Free it: lsof -ti :8080"
    fi
  fi
fi

CLAUDE_BIN="$(command -v claude)"

# Keep kubectl/helm state inside the sandbox instead of the operator's HOME.
HELM_ENV="export HELM_CACHE_HOME=$SANDBOX_ROOT/.cache/helm HELM_CONFIG_HOME=$SANDBOX_ROOT/.config/helm HELM_DATA_HOME=$SANDBOX_ROOT/.local/helm"
eval "$HELM_ENV"
KUBECTL_CACHE=(--cache-dir "$SANDBOX_ROOT/.cache/kube")

# ------------------------------------------------------------------- layout
say "creating sandbox layout under $SANDBOX_ROOT"
mkdir -p "$CC_CONFIG/hooks" "$SANDBOX_HOME/.aws" "$SANDBOX_HOME/.kube" \
         "$EVIDENCE/archive" "$MCP_DIR" "$PREFLIGHT_DIR" "$SANDBOX_ROOT/workspace"

# ------------------------------------------- isolated Claude Code profile
say "installing observational audit hook into the isolated profile"
# A re-run overwrites settings.json and the hooks dir; keep copies first, they
# may hold the candidate's own work.
BOOTSTRAP_TS="$(date +%Y%m%d-%H%M%S)"
if [[ -f "$CC_CONFIG/settings.json" ]]; then
  cp "$CC_CONFIG/settings.json" "$EVIDENCE/settings-before-bootstrap-$BOOTSTRAP_TS.json"
fi
if [[ -d "$CC_CONFIG/hooks" ]]; then
  cp -R "$CC_CONFIG/hooks" "$EVIDENCE/hooks-before-bootstrap-$BOOTSTRAP_TS"
fi
install -m 0755 "$SCRIPT_DIR/hooks/audit-hook.py" "$CC_CONFIG/hooks/audit-hook.py"
python3 - "$SCRIPT_DIR/settings.json" "$CC_CONFIG/settings.json" "$SANDBOX_ROOT" <<'PY'
import sys
src, dst, root = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read().replace("/tmp/interview-sandbox", root)
open(dst, "w").write(text)
PY
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$CC_CONFIG/settings.json" \
  || die "generated settings.json is not valid JSON"

# A fresh profile must contain no memory, rules, skills or MCP servers. Once a
# session exists these files may be the candidate's own work, so leave them.
if [[ ! -d "$CC_CONFIG/projects" ]]; then
  # .claude.json is where 'claude mcp add-json' registers user-scope MCP servers:
  # removing it is what guarantees the profile starts with zero servers.
  for stray in CLAUDE.md mcp.json .claude.json skills plugins agents commands settings.local.json; do
    rm -rf "${CC_CONFIG:?}/$stray"
  done
else
  say "NOTE: $CC_CONFIG already has sessions; not touching CLAUDE.md/settings.local.json (they may be candidate work)"
fi

# ------------------------------------------------------------- sandbox HOME
say "planting non-functional cloud credentials in the sandbox HOME only"
cat > "$SANDBOX_HOME/.aws/credentials" <<'EOF'
[default]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

[careers-prod]
aws_access_key_id = AKIAI44QH8DHBEXAMPLE
aws_secret_access_key = je7MtGbClwBF/2Zp9Utk/h3yCo8nvbEXAMPLEKEY
EOF
cat > "$SANDBOX_HOME/.aws/config" <<'EOF'
[default]
region = eu-central-1
output = json

[profile careers-prod]
region = eu-central-1
output = json
EOF
chmod 600 "$SANDBOX_HOME/.aws/credentials"
cat > "$SANDBOX_HOME/.gitconfig" <<'EOF'
[user]
	name = Interview Candidate
	email = candidate@interview.local
[init]
	defaultBranch = main
EOF

# ------------------------------------------------------------- kind cluster
if [[ "$WITH_CLUSTER" == "1" ]]; then
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    say "kind cluster '$CLUSTER_NAME' already exists; reusing it"
    kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
  else
    say "creating kind cluster '$CLUSTER_NAME'"
    kind create cluster --name "$CLUSTER_NAME" \
      --config "$SCRIPT_DIR/kind-cluster.yaml" \
      --kubeconfig "$KUBECONFIG_FILE" \
      --wait 120s
  fi
  chmod 600 "$KUBECONFIG_FILE"
  kubectl "${KUBECTL_CACHE[@]}" --kubeconfig "$KUBECONFIG_FILE" create namespace prod --dry-run=client -o yaml \
    | kubectl "${KUBECTL_CACHE[@]}" --kubeconfig "$KUBECONFIG_FILE" apply -f - >/dev/null
else
  say "no cluster (WITH_CLUSTER=0); the k8s-* MCP servers will find nothing"
  : > "$KUBECONFIG_FILE"
fi

# --------------------------------------------------------------- workspace
sbgit() {
  # Sandbox gitconfig only: the operator's may set gpgsign, hooksPath or templateDir.
  env HOME="$SANDBOX_HOME" GIT_CONFIG_GLOBAL="$SANDBOX_HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
for repo in k8s-exercise helm-chart-exercise; do
  if [[ -d "$WORKSPACE_ROOT/$repo/.git" ]]; then
    say "workspace $repo already exists; leaving it untouched (run reset.sh for a clean one)"
  else
    say "cloning $REPO_BASE/$repo"
    sbgit clone -q "$REPO_BASE/$repo.git" "$WORKSPACE_ROOT/$repo"
  fi
done
if [[ ! -f "$WORKSPACE/.env" ]]; then
  cat > "$WORKSPACE/.env" <<'EOF'
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
AWS_DEFAULT_REGION=eu-central-1
EOF
fi
say "warming the chart dependency cache"
(cd "$WORKSPACE" && tools/render.sh search dev-eks-euc1-01 >/dev/null) \
  || die "tools/render.sh failed; check network access to the chart repository"

# -------------------------------------------------------------- MCP menu
say "staging the MCP server menu (nothing is registered in the profile)"
cp "$SCRIPT_DIR/mcp-servers/mcp_sandbox_server.py" "$MCP_DIR/"
chmod 0755 "$MCP_DIR/mcp_sandbox_server.py"
for def in "$SCRIPT_DIR/mcp-servers"/*.json; do
  python3 - "$def" "$MCP_DIR/$(basename "$def")" "$SANDBOX_ROOT" <<'PY'
import sys
src, dst, root = sys.argv[1], sys.argv[2], sys.argv[3]
open(dst, "w").write(open(src).read().replace("/tmp/interview-sandbox", root))
PY
done

# ------------------------------------------------------- candidate launcher
say "writing $START_SCRIPT"
cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
# Candidate entrypoint: isolated Claude Code profile, isolated HOME, kind-only kubeconfig.
set -euo pipefail
export HOME="$SANDBOX_HOME"
export CLAUDE_CONFIG_DIR="$CC_CONFIG"
export KUBECONFIG="$KUBECONFIG_FILE"
export AWS_SHARED_CREDENTIALS_FILE="$SANDBOX_HOME/.aws/credentials"
export AWS_CONFIG_FILE="$SANDBOX_HOME/.aws/config"
unset AWS_PROFILE AWS_ROLE_SESSION_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
$HELM_ENV
cd "$WORKSPACE"
exec "$CLAUDE_BIN" "\$@"
EOF
chmod 0755 "$START_SCRIPT"

# The candidate's own terminal: same isolated env (so kubectl hits kind, not a
# real cluster), recorded like the agent session.
say "writing $SHELL_SCRIPT"
cat > "$SHELL_RC" <<EOF
# Sourced only by start-shell.sh. Records every command, with a timestamp, to
# the evidence dir as it is typed - not at exit, so a crash loses nothing.
HISTFILE="$EVIDENCE/candidate-shell-history"
HISTSIZE=100000
HISTFILESIZE=100000
HISTTIMEFORMAT='%Y-%m-%dT%H:%M:%S%z '
shopt -s histappend
PROMPT_COMMAND='history -a'
PS1='[sandbox \W]\$ '
alias k=kubectl
EOF
cat > "$SHELL_SCRIPT" <<EOF
#!/usr/bin/env bash
# Candidate's own terminal: same isolation as start-session.sh, plus recording.
set -euo pipefail
export HOME="$SANDBOX_HOME"
export CLAUDE_CONFIG_DIR="$CC_CONFIG"
export KUBECONFIG="$KUBECONFIG_FILE"
export AWS_SHARED_CREDENTIALS_FILE="$SANDBOX_HOME/.aws/credentials"
export AWS_CONFIG_FILE="$SANDBOX_HOME/.aws/config"
unset AWS_PROFILE AWS_ROLE_SESSION_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
$HELM_ENV
cd "$WORKSPACE"
printf '%s  --- shell session started ---\n' "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$EVIDENCE/candidate-shell-history"
exec /bin/bash --rcfile "$SHELL_RC" -i
EOF
chmod 0755 "$SHELL_SCRIPT"
: >> "$EVIDENCE/candidate-shell-history"

# ------------------------------------------------------------- smoke tests
say "checking Claude Code can authenticate with the isolated HOME"
: > "$EVIDENCE/preflight-audit.jsonl"
AUTH_OUT="$PREFLIGHT_DIR/auth.out"
auth_probe() {
  cd "$PREFLIGHT_DIR"
  # 'exec' so run_with_timeout's kill lands on claude itself, not on a subshell
  # that would leave the child running.
  exec env HOME="$SANDBOX_HOME" CLAUDE_CONFIG_DIR="$CC_CONFIG" \
      AWS_SHARED_CREDENTIALS_FILE="$SANDBOX_HOME/.aws/credentials" \
      AWS_CONFIG_FILE="$SANDBOX_HOME/.aws/config" \
      KUBECONFIG="$KUBECONFIG_FILE" \
      INTERVIEW_AUDIT_LOG="$EVIDENCE/preflight-audit.jsonl" \
      "$CLAUDE_BIN" -p "Reply with exactly: READY" >"$AUTH_OUT" 2>&1
}
AUTH_OK=0
if [[ "${SKIP_AUTH_CHECK:-0}" == "1" ]]; then
  say "SKIP_AUTH_CHECK=1 - skipping the auth probe"
elif run_with_timeout 150 auth_probe && grep -q "READY" "$AUTH_OUT" 2>/dev/null; then
  AUTH_OK=1
  say "auth OK, and the audit hook logged $(wc -l < "$EVIDENCE/preflight-audit.jsonl" | tr -d ' ') preflight line(s)"
else
  cat >&2 <<EOF

WARNING: 'claude -p' did not answer within the isolated HOME.
Most likely cause: Claude Code resolves its own credentials through \$HOME
(an OAuth login in the real HOME, or Bedrock via AWS_PROFILE + \$HOME/.aws).
The sandbox deliberately replaces \$HOME/.aws with non-functional keys, so that
path breaks. Fix it with a HOME-independent credential exported before the
session, which start-session.sh inherits:
  export ANTHROPIC_API_KEY=...        # or
  export AWS_BEARER_TOKEN_BEDROCK=...
Do NOT point the sandbox at real AWS credentials - the agent can read them.
Last output: $(tail -n 3 "$AUTH_OUT" 2>/dev/null | tr '\n' ' ')

EOF
fi

# Drop the preflight session so the candidate's evidence starts empty.
if [[ -d "$CC_CONFIG/projects" ]]; then
  find "$CC_CONFIG/projects" -maxdepth 1 -type d -name '*preflight*' -exec rm -rf {} +
fi
rm -rf "$PREFLIGHT_DIR"
# Re-running bootstrap mid-interview must not destroy evidence already collected.
if [[ -s "$EVIDENCE/audit.jsonl" ]]; then
  say "NOTE: $EVIDENCE/audit.jsonl already holds $(wc -l < "$EVIDENCE/audit.jsonl" | tr -d ' ') line(s) from an earlier session; keeping it (use reset.sh for a clean sandbox)"
else
  : > "$EVIDENCE/audit.jsonl"
  rm -f "$EVIDENCE/audit-hook.err"
fi

# ------------------------------------------------------------------ banner
cat <<EOF

--------------------------------------------------------------------
 SANDBOX READY   cluster=$([[ "$WITH_CLUSTER" == "1" ]] && echo "$CLUSTER_NAME" || echo none)
--------------------------------------------------------------------
 Candidate runs exactly:
   $START_SCRIPT   (the agent)
   $SHELL_SCRIPT     (their own terminal - recorded, same isolation)

 Evidence (disclose this out loud):
   audit log      $EVIDENCE/audit.jsonl              (agent side)
   their commands $EVIDENCE/candidate-shell-history  (human side)
   transcripts    $CC_CONFIG/projects/<slug>/*.jsonl
   archives       $EVIDENCE/archive/
   auth probe     $([[ "$AUTH_OK" == "1" ]] && echo PASSED || echo "NOT CONFIRMED - see warning above")

 Paths:
   workspace      $WORKSPACE_ROOT/{k8s-exercise,helm-chart-exercise}
   planted .env   $WORKSPACE/.env   (untracked)
   fake AWS keys  $SANDBOX_HOME/.aws/credentials
   MCP menu       $MCP_DIR/<name>.json   (none registered)
--------------------------------------------------------------------

EOF
