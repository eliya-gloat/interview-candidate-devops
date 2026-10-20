# Brief

## Your task

You have clones of two repos: `k8s-exercise` (12 applications, each with its own ConfigMap of environment
variables) and `helm-chart-exercise` (the shared `devops_infra` chart they depend on).

The shared chart now renders every internal service URL from one catalog,
`apps/_shared/serviceRegistry.yaml`, into a ConfigMap called `<app>-common-env-vars`. Apps on the chart mount
it **before** their own `<app>-env-vars`, so the app's own ConfigMap still wins on any key both define.

**The ticket:** remove the hand-written service-URL keys that the registry now provides. **No rendered value may
change without you saying so.** Where the registry's value and the hand-written one differ, that is a finding:
decide what to do about it and say why.

**Deliverable:** commits on one or more local branches, grouped however you think is right, plus — for every
app and every key you did **not** change — a one-line reason. You cannot push; we will walk through your
branches together.

**Then be ready to defend it as if it were going to production tomorrow:** what each change does, what could go
wrong, how you would test or simulate it before prod, and how you would roll it out.

`tools/render.sh <app> <cluster>` renders an app the way ArgoCD would. The repo's README has the rest.

## The environment

- **Use the terminal we've given you**, both for the agent and for your own commands. Both are recorded.
- The Claude Code profile is empty: no memory, no rules, no skills, no MCP servers. Whatever you want, you
  set up.
- Both repos are public at `github.com/eliya-gloat`. Your clones have no push access, and you don't need any.
- About 30 minutes of working time. I won't answer questions about the task itself — I'll answer questions about the environment.
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
