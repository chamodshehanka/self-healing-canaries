"""The AI SRE agent: OpenAI Agents SDK + Grafana MCP + GitHub MCP + the release ledger.

What it CAN do:   read telemetry (Grafana MCP, read-only), read code and history
                  (GitHub MCP), push a fix commit to a PR branch or open a new PR.
What it CANNOT do: merge, delete, change workflows or settings, touch the cluster.
                  Those tools are not exposed, the token can't do them, and
                  branch protection on main requires a human review anyway.
"""
import json
import os
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Literal

from agents import Agent, ItemHelpers, Runner, function_tool
from agents.mcp import MCPServerStreamableHttp, create_static_tool_filter
from pydantic import BaseModel

from ledger import Ledger

PLAYBOOK = (Path(__file__).parent / "playbook.md").read_text()

MODEL = os.environ.get("OPENAI_MODEL", "gpt-5.5")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "chamodshehanka/self-healing-canaries")
GRAFANA_MCP_URL = os.environ.get("GRAFANA_MCP_URL", "http://localhost:8000/mcp")
GITHUB_MCP_URL = os.environ.get("GITHUB_MCP_URL", "https://api.githubcopilot.com/mcp/")
DRY_RUN = os.environ.get("AI_SRE_DRY_RUN", "false").lower() == "true"

# Layer 1 of the safety boundary: tools the agent never even sees.
GITHUB_BLOCKED = [
    "merge_pull_request", "delete_file", "update_pull_request_branch", "create_repository",
    "fork_repository", "create_pull_request_with_copilot", "assign_copilot_to_issue",
    "delete_branch", "update_pull_request", "pull_request_review_write",
]
GITHUB_WRITE = ["create_or_update_file", "push_files", "create_branch", "create_pull_request", "add_issue_comment"]


class Report(BaseModel):
    root_cause: str
    offending_change: str
    evidence: list[str]
    environment_difference: str | None
    fix_summary: str
    action: Literal["pushed_fix_to_pr", "opened_pr", "diagnosis_only"]
    pr_url: str | None
    confidence: Literal["high", "medium", "low"]


def build_tools(ledger: Ledger):
    @function_tool
    def get_release_history(limit: int = 20) -> str:
        """Most recent canary verdicts across ALL environments, newest first.
        Each row: env, image, git_sha, pod_hash, verdict (passed|failed), source_pr, source_branch."""
        return json.dumps(ledger.releases(limit), default=str)

    @function_tool
    def compare_environments(image: str) -> str:
        """Every verdict recorded for one image, oldest first. Use it to answer:
        'did this exact image pass in another environment before failing here?'"""
        rows = ledger.image_history(image)
        summary = {}
        for r in rows:
            summary.setdefault(r["env"], []).append(r["verdict"])
        return json.dumps({"image": image, "verdicts_by_env": summary, "rows": rows}, default=str)

    return [get_release_history, compare_environments]


def task_prompt(ev: dict) -> str:
    mode = (
        "DRY RUN: GitHub write tools are disabled. Diagnose and describe the fix only; action=diagnosis_only."
        if DRY_RUN else
        "Follow the playbook through to the GitHub action that matches this environment."
    )
    return (
        "Argo Rollouts aborted a canary and rolled back. The notification it sent is below.\n"
        "Investigate, fix through GitHub, and return your Report.\n\n"
        f"GITHUB_REPO: {GITHUB_REPO}\n"
        f"Prometheus datasource: Prometheus-{ev['env']}   Loki datasource: Loki-{ev['env']}\n"
        f"Other environments' datasources follow the same naming (Prometheus-staging, Loki-prod, ...).\n\n"
        "<rollout_notification>\n" + json.dumps(ev, indent=2) + "\n</rollout_notification>\n\n"
        + mode
    )


async def investigate(ev: dict, ledger: Ledger, on_step: Callable[[dict], Awaitable[None] | None]) -> Report:
    token = os.environ["GITHUB_TOKEN"]
    blocked = GITHUB_BLOCKED + (GITHUB_WRITE if DRY_RUN else [])

    async with (
        MCPServerStreamableHttp(
            name="grafana",
            params={"url": GRAFANA_MCP_URL, "timeout": 30},
            cache_tools_list=True,
            client_session_timeout_seconds=60,
        ) as grafana,
        MCPServerStreamableHttp(
            name="github",
            params={
                "url": GITHUB_MCP_URL,
                "timeout": 30,
                "headers": {
                    "Authorization": f"Bearer {token}",
                    "X-MCP-Toolsets": "repos,pull_requests,issues",
                },
            },
            cache_tools_list=True,
            client_session_timeout_seconds=60,
            tool_filter=create_static_tool_filter(blocked_tool_names=blocked),
        ) as github,
    ):
        agent = Agent(
            name="AI SRE",
            instructions=PLAYBOOK,
            model=MODEL,
            mcp_servers=[grafana, github],
            tools=build_tools(ledger),
            output_type=Report,
        )
        run = Runner.run_streamed(agent, input=task_prompt(ev), max_turns=40)
        async for e in run.stream_events():
            if e.type != "run_item_stream_event":
                continue
            item = e.item
            if item.type == "tool_call_item":
                raw = item.raw_item
                name = getattr(raw, "name", None) or getattr(raw, "type", "tool")
                args = getattr(raw, "arguments", "") or ""
                await _emit(on_step, {"kind": "tool", "name": name, "args": args[:600]})
            elif item.type == "tool_call_output_item":
                out = str(getattr(item, "output", ""))
                await _emit(on_step, {"kind": "result", "text": out[:400]})
            elif item.type == "message_output_item":
                text = ItemHelpers.text_message_output(item)
                if text:
                    await _emit(on_step, {"kind": "thought", "text": text[:600]})
        return run.final_output


async def _emit(cb, step):
    r = cb(step)
    if hasattr(r, "__await__"):
        await r
