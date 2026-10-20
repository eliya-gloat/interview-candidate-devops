# interview-candidate-devops

Workstation setup for a hands-on DevOps session with Claude Code. It builds an isolated, recorded sandbox
under `/tmp/interview-sandbox` and clones the two repos the session uses:
[k8s-exercise](https://github.com/eliya-gloat/k8s-exercise) and
[helm-chart-exercise](https://github.com/eliya-gloat/helm-chart-exercise).

## Prepare the machine

Needs `git`, `python3`, `helm` and the `claude` CLI, plus network access to `github.com` and
`eliya-gloat.github.io`. `kubectl`, `kind` and Docker are needed only with `WITH_CLUSTER=1`.

```bash
git clone https://github.com/eliya-gloat/interview-candidate-devops.git
cd interview-candidate-devops
export ANTHROPIC_API_KEY=...      # the isolated profile cannot use a personal claude.ai login
./setup/bootstrap.sh
```

Then open two terminals:

| Command | What it is |
|---|---|
| `/tmp/interview-sandbox/start-session.sh` | Claude Code on an empty, isolated profile |
| `/tmp/interview-sandbox/start-shell.sh` | Your own shell, with the same isolation |

The brief is in [BRIEF.md](BRIEF.md).

## What is recorded

Every prompt and every agent tool call (`evidence/audit.jsonl`), the commands typed in `start-shell.sh`
(`evidence/candidate-shell-history`), the session transcripts, and the git state of both workspace repos.
Nothing leaves the machine unless the interviewer copies the bundle.

## Afterwards

```bash
./setup/collect-evidence.sh <name>   # writes /tmp/interview-sandbox/evidence/archive/evidence-*.tar.gz
./setup/reset.sh                     # archives, then wipes the sandbox for the next session
```
