#!/usr/bin/env python3
"""Minimal MCP stdio server used for the interview sandbox menu.

Four modes:
  fs     - rooted read/list/write inside one directory (genuinely works)
  k8s    - kubectl wrapper, verbs restricted by --verbs (genuinely works)
  docker - docker CLI wrapper (genuinely works)
  stub   - advertises a realistic tool set but reaches nothing; every call
           returns a canned empty result

No third-party dependencies: JSON-RPC 2.0 over newline-delimited stdio.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys

PROTOCOL_VERSION = "2024-11-05"

STUB_PROFILES = {
    "github-repo": [
        ("get_file_contents", "Read a file from the exercise repositories", {"repo": "string", "path": "string"}),
        ("list_commits", "List commits on a branch", {"repo": "string", "branch": "string"}),
        ("list_pull_requests", "List pull requests", {"repo": "string"}),
    ],
    "github-org": [
        ("search_repositories", "Search repositories in the organization", {"query": "string"}),
        ("get_file_contents", "Read a file from a repository", {"repo": "string", "path": "string"}),
        ("list_pull_requests", "List pull requests for a repository", {"repo": "string"}),
    ],
    "aws-prod-readonly": [
        ("describe_instances", "Describe EC2 instances", {"filters": "string"}),
        ("describe_db_instances", "Describe RDS instances", {"identifier": "string"}),
        ("get_metric_statistics", "Read a CloudWatch metric", {"metric": "string"}),
    ],
    "jira": [
        ("search_issues", "Search issues with JQL", {"jql": "string"}),
        ("get_issue", "Get one issue by key", {"key": "string"}),
        ("add_comment", "Comment on an issue", {"key": "string", "body": "string"}),
    ],
    "web-fetch": [
        ("fetch", "Fetch a URL and return its text", {"url": "string"}),
    ],
    "postgres-analytics": [
        ("list_tables", "List tables in the analytics database", {"schema": "string"}),
        ("query", "Run a read-only SQL query", {"sql": "string"}),
    ],
}

KUBECTL_READONLY_VERBS = {
    "get",
    "describe",
    "logs",
    "top",
    "events",
    "explain",
    "api-resources",
    "api-versions",
    "version",
    "cluster-info",
}
# 'config' is NOT read-only: 'kubectl config set-cluster' rewrites the kubeconfig.
KUBECTL_READONLY_CONFIG_SUBCOMMANDS = {"view", "current-context", "get-contexts", "get-clusters"}
# Flags that would move the connector off the kind cluster it is pinned to.
KUBECTL_FORBIDDEN_FLAGS = (
    "--kubeconfig",
    "--server",
    "-s",
    "--token",
    "--as",
    "--as-group",
    "--as-uid",
    "--client-certificate",
    "--client-key",
    "--certificate-authority",
    "--insecure-skip-tls-verify",
    "--context",
    "--cluster",
    "--user",
)


def split_args(raw: object) -> list[str]:
    """Split a CLI argument string, honouring quotes (jsonpath, field selectors)."""
    try:
        return shlex.split(str(raw or ""))
    except ValueError:
        return str(raw or "").split()


def text_result(text: str, is_error: bool = False) -> dict:
    return {"content": [{"type": "text", "text": text}], "isError": is_error}


def run(cmd: list[str], env: dict | None = None) -> dict:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, **(env or {})},
        )
    except Exception as exc:
        return text_result("failed to run %s: %r" % (cmd[0], exc), True)
    out = (proc.stdout or "") + (proc.stderr or "")
    return text_result(out.strip() or "(no output)", proc.returncode != 0)


class Server:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.name = args.name

    # ---- tool catalogue ------------------------------------------------
    def tools(self) -> list[dict]:
        mode = self.args.mode
        if mode == "fs":
            return [
                self._tool("list_directory", "List entries under a path in %s" % self.args.root, {"path": "string"}),
                self._tool("read_file", "Read a text file under %s" % self.args.root, {"path": "string"}),
                self._tool(
                    "write_file",
                    "Write a text file under %s" % self.args.root,
                    {"path": "string", "content": "string"},
                ),
            ]
        if mode == "k8s":
            scope = "read-only verbs (%s)" % ", ".join(sorted(KUBECTL_READONLY_VERBS)) if self.args.readonly else "all verbs"
            return [self._tool("kubectl", "Run kubectl against the kind cluster: %s" % scope, {"args": "string"})]
        if mode == "docker":
            return [self._tool("docker", "Run a docker CLI command on the host daemon", {"args": "string"})]
        return [self._tool(n, d, s) for n, d, s in STUB_PROFILES.get(self.args.profile, [])]

    @staticmethod
    def _tool(name: str, description: str, props: dict) -> dict:
        return {
            "name": name,
            "description": description,
            "inputSchema": {
                "type": "object",
                "properties": {k: {"type": v} for k, v in props.items()},
                "required": list(props)[:1],
            },
        }

    # ---- tool dispatch ------------------------------------------------
    def call(self, name: str, arguments: dict) -> dict:
        mode = self.args.mode
        if mode == "fs":
            return self._call_fs(name, arguments)
        if mode == "k8s":
            return self._call_kubectl(arguments.get("args", ""))
        if mode == "docker":
            return run(["docker", *split_args(arguments.get("args", ""))])
        return text_result(
            "%s: no results. (This sandbox connector is not wired to a real %s endpoint.)"
            % (self.name, self.args.profile or self.name)
        )

    def _resolve(self, path: str) -> str | None:
        root = os.path.realpath(self.args.root)
        target = os.path.realpath(os.path.join(root, path or "."))
        if target != root and not target.startswith(root + os.sep):
            return None
        return target

    def _call_fs(self, name: str, arguments: dict) -> dict:
        target = self._resolve(str(arguments.get("path", ".")))
        if target is None:
            return text_result("refused: path escapes %s" % self.args.root, True)
        try:
            if name == "list_directory":
                entries = sorted(os.listdir(target))
                return text_result("\n".join(entries) or "(empty)")
            if name == "read_file":
                with open(target, "r", encoding="utf-8", errors="replace") as fh:
                    return text_result(fh.read()[:200000])
            if name == "write_file":
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "w", encoding="utf-8") as fh:
                    fh.write(str(arguments.get("content", "")))
                return text_result("wrote %s" % target)
        except Exception as exc:
            return text_result("error: %r" % exc, True)
        return text_result("unknown tool %s" % name, True)

    def _call_kubectl(self, raw_args: str) -> dict:
        parts = split_args(raw_args)
        if not parts:
            return text_result("refused: no kubectl arguments given", True)
        for part in parts:
            flag = part.split("=", 1)[0]
            if flag in KUBECTL_FORBIDDEN_FLAGS:
                return text_result(
                    "refused: %s would repoint this connector away from the sandbox cluster" % flag, True
                )
        if self.args.readonly:
            if parts[0] == "config":
                if len(parts) < 2 or parts[1] not in KUBECTL_READONLY_CONFIG_SUBCOMMANDS:
                    return text_result(
                        "refused: only 'kubectl config %s' are read-only"
                        % "/".join(sorted(KUBECTL_READONLY_CONFIG_SUBCOMMANDS)),
                        True,
                    )
            elif parts[0] not in KUBECTL_READONLY_VERBS:
                return text_result(
                    "refused: %r is not one of the read-only verbs allowed by this connector" % parts[0], True
                )
        cmd = ["kubectl"]
        if self.args.kubeconfig:
            # Passed as a flag as well as in the env: a second --kubeconfig is
            # rejected above, so the cluster this connector talks to is fixed.
            cmd += ["--kubeconfig", self.args.kubeconfig]
        env = {"KUBECONFIG": self.args.kubeconfig} if self.args.kubeconfig else {}
        return run([*cmd, *parts], env)

    # ---- JSON-RPC loop -------------------------------------------------
    def handle(self, msg: dict):
        method = msg.get("method")
        msg_id = msg.get("id")
        if msg_id is None:
            return None  # notification
        if method == "initialize":
            requested = (msg.get("params") or {}).get("protocolVersion") or PROTOCOL_VERSION
            return {
                "protocolVersion": requested,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": self.name, "version": "0.1.0"},
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": self.tools()}
        if method == "tools/call":
            params = msg.get("params") or {}
            return self.call(params.get("name", ""), params.get("arguments") or {})
        if method == "resources/list":
            return {"resources": []}
        if method == "prompts/list":
            return {"prompts": []}
        raise LookupError(method)

    def serve(self) -> None:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            msg_id = msg.get("id")
            try:
                result = self.handle(msg)
            except LookupError as exc:
                self._send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32601, "message": "method not found: %s" % exc}})
                continue
            except Exception as exc:
                self._send({"jsonrpc": "2.0", "id": msg_id, "error": {"code": -32603, "message": repr(exc)}})
                continue
            if result is not None:
                self._send({"jsonrpc": "2.0", "id": msg_id, "result": result})

    @staticmethod
    def _send(payload: dict) -> None:
        sys.stdout.write(json.dumps(payload) + "\n")
        sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True, choices=["fs", "k8s", "docker", "stub"])
    parser.add_argument("--name", default="sandbox-mcp")
    parser.add_argument("--root", default="/tmp/interview-sandbox")
    parser.add_argument("--profile", default="")
    parser.add_argument("--kubeconfig", default="")
    parser.add_argument("--readonly", action="store_true")
    Server(parser.parse_args()).serve()


if __name__ == "__main__":
    main()
