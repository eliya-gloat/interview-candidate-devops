# Brief

## Your task

You have clones of two repos: `k8s-exercise` (12 applications, each rendering its own ConfigMap of environment
variables) and `helm-chart-exercise` (the shared `devops_infra` chart most of them depend on).

**The ticket:** today every app hand-writes the URLs of the services it calls, in its own ConfigMap. Make each
internal service URL defined **once, in one place**, and available to **every** app. Adding a new service later
should mean adding its URL in that one place, after which every app gets the same value.

Pay attention: most services are **regional** (they run in every region), but `recommender` and
`model-serving` are **global** — they run only in euc1, and other regions must reach them through their euc1
address. The repo README describes both address forms.

**Deliverable:** commits on local branches in either or both repos, plus a short written design: where the URLs
live, how they reach the apps, and why there. You cannot push or publish a chart release; we will walk through
your branches together.

**Then be ready to defend it as if it were going to production tomorrow:** what each change does, what could go
wrong, how you would test or simulate it before prod, and how you would roll it out.

`tools/render.sh <app> <cluster>` renders an app the way ArgoCD would. The repo's README has the rest.

## The environment

- **Use the terminal we've given you**, both for the agent and for your own commands. Both are recorded.
- The Claude Code profile is empty: no memory, no rules, no skills, no MCP servers. Whatever you want, you
  set up.
- Both repos are public at `github.com/eliya-gloat`. Your clones have no push access, and you don't need any.
- About 12 minutes of working time. I won't answer questions about the task itself — I'll answer questions about the environment.
- **Everything is recorded**: your prompts, the agent's tool calls, and your own shell history. We keep it
  only until the hiring decision closes.

You are not being scored on finishing. You are being scored on how you worked and what you can defend.

---
## MCP servers available on this machine — connect whichever you want, none are pre-installed

| # | Server | What it does | Credentials behind it |
|---|---|---|---|
| 1 | `filesystem-workspace` | Read/write files | The task workspace directory only |
| 2 | `filesystem-home` | Read/write files | The whole home directory on this machine |
| 3 | `github-repo` | Read — files, commits, PRs | **The two exercise repositories** |
| 4 | `github-org` | Read and write — branches, PRs, merges | An org-wide token, 89 repositories |
| 5 | `k8s-readonly` | `get`, `list`, `watch` | The local cluster, all namespaces |
| 6 | `k8s-admin` | Full read/write, all verbs | The local cluster, including `prod` |
| 7 | `aws-prod-readonly` | `Describe*`, `Get*`, `List*` | The production AWS account |
| 8 | `jira` | Read and comment on tickets | The real Jira instance |
| 9 | `web-fetch` | Fetch a URL | None |
| 10 | `postgres-analytics` | Arbitrary SQL, read-only | The production analytics replica |
