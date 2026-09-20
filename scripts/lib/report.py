#!/usr/bin/env python3
"""Assemble the read-only endpoint doctor report from gathered raw facts.

Input is a JSONL file with one raw endpoint object per line (produced by
scripts/doctor.sh). Output is either the human report or a stable JSON document.

Every fact is either observed (Herdr API JSON, a config file, or a /proc probe) or absent.
Pane classification uses only pane-published tokens: a pane that declares ``role``
worker/subagent but lacks a complete relationship is reported separately from an ordinary
Pi pane whose role is unknown. Nothing is inferred from a title, name, or cwd.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config  # noqa: E402

NON_PI = "agent-tree"
ROLES = ("worker", "subagent")


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def self_hash(session_path: str) -> str:
    # Serde/json! and JSON.stringify both emit compact JSON; match that byte-for-byte.
    tuple_text = json.dumps(["pi", "path", session_path], separators=(",", ":"))
    return sha256_hex(tuple_text)


def is_lower_hex64(value) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def classify_panes(agents) -> dict:
    result = {
        "pi": 0,
        "declared_delegated": 0,
        "relationship_bearing": 0,
        "relationship_valid": 0,
        "ranked": 0,
        "delegated_missing_relationship": 0,
        "ordinary_pi": 0,
    }
    for agent in agents or []:
        tokens = agent.get("tokens") or {}
        session = ((agent.get("agent_session") or {}).get("value")) if agent.get("agent_session") else None
        result["pi"] += 1
        role = tokens.get("role")
        self_token = tokens.get("agency_self")
        parent_token = tokens.get("agency_parent")
        declared = role in ROLES
        complete = declared and is_lower_hex64(self_token) and is_lower_hex64(parent_token)
        if declared:
            result["declared_delegated"] += 1
        if complete:
            result["relationship_bearing"] += 1
            if session and self_hash(session) == self_token:
                result["relationship_valid"] += 1
        if declared and not complete:
            result["delegated_missing_relationship"] += 1
        if not declared and not self_token and not parent_token:
            result["ordinary_pi"] += 1
        if isinstance(tokens.get("agent_tree_rank"), str) and tokens.get("agent_tree_rank"):
            result["ranked"] += 1
    return result


def triple(value: str):
    core = str(value or "").split("-")[0].split("+")[0]
    parts = core.split(".")
    while len(parts) < 3:
        parts.append("0")
    numbers = []
    for part in parts[:3]:
        try:
            numbers.append(int(part))
        except ValueError:
            return (0, 0, 0)
    return tuple(numbers)


def build_endpoint(raw: dict) -> dict:
    status = raw.get("status")
    plugin = raw.get("plugin")
    config_text = raw.get("config") or ""
    probe = raw.get("probe") or {}
    min_version = raw.get("min_version") or "0.9.0"

    report = {
        "name": raw.get("name"),
        "kind": raw.get("kind"),
        "label": raw.get("label") or None,
        "id": raw.get("id") or None,
        "target": raw.get("target") or None,
        "session": raw.get("session") or None,
        "socket": raw.get("socket"),
        "herdr": None,
        "plugin": None,
        "staged": {"path": None, "present": False, "sha256": None},
        "subscriber": {"count": 0, "pids": [], "sha256": [], "matches_staged": None, "replaced_stage": 0},
        "toggle": {"action_available": False, "tree_off": probe.get("tree_off")},
        "shortcut": {"present": False, "key": None, "occupied": False, "managed": False},
        "sidebar": {
            "section_present": False,
            "agent_tree_row_present": False,
            "managed_block_present": False,
            "foreign_without_token": False,
        },
        "panes": classify_panes(raw.get("agents")),
        "verdict": "unreachable",
        "issues": [],
        "notes": [],
    }

    if raw.get("status_error") or not status:
        report["issues"].append("Herdr status is unavailable: %s" % (raw.get("status_error") or "no response"))
        return report
    if not status.get("running"):
        report["issues"].append("the Herdr server is not running")
    version_ok = triple(status.get("version")) >= triple(min_version)
    compatible = bool(status.get("compatible"))
    report["herdr"] = {
        "reachable": True,
        "running": bool(status.get("running")),
        "version": status.get("version"),
        "protocol": status.get("protocol"),
        "compatible": compatible,
        "version_ok": version_ok,
        "min_version": min_version,
    }
    if not compatible:
        report["issues"].append("the endpoint protocol is incompatible with this client")
    if not version_ok:
        report["issues"].append("Herdr %s is older than the plugin minimum %s" % (status.get("version"), min_version))

    if plugin:
        actions = [action.get("id") for action in plugin.get("actions") or []]
        report["plugin"] = {
            "registered": True,
            "enabled": bool(plugin.get("enabled")),
            "plugin_root": plugin.get("plugin_root"),
            "manifest_path": plugin.get("manifest_path"),
            "version": plugin.get("version"),
            "name": plugin.get("name"),
            "source_kind": (plugin.get("source") or {}).get("kind"),
            "actions": actions,
            "toggle_available": "toggle" in actions,
        }
        if not plugin.get("enabled"):
            report["issues"].append("the agent-tree plugin is registered but disabled")
        if "toggle" not in actions:
            report["issues"].append("the agent-tree.toggle action is not registered")
        stage_binary = os.path.join(plugin.get("plugin_root") or "", "src", "agent-tree")
    else:
        report["plugin"] = {
            "registered": False,
            "enabled": False,
            "plugin_root": None,
            "manifest_path": None,
            "version": None,
            "name": None,
            "source_kind": None,
            "actions": [],
            "toggle_available": False,
        }
        report["issues"].append("the agent-tree plugin is not registered")
        stage_binary = raw.get("stage_binary")

    stage = probe.get("stage") or {}
    if stage.get("path") and stage.get("path") != stage_binary:
        # The probe ran against the registered root's binary; keep the probe's own path.
        pass
    report["staged"] = {
        "path": stage.get("path") or stage_binary,
        "present": bool(stage.get("present")),
        "sha256": stage.get("sha256"),
    }
    if not report["staged"]["present"]:
        report["issues"].append("no staged plugin binary is present")

    subscribers = probe.get("subscribers") or []
    replaced = probe.get("replaced_stage_subscribers") or []
    report["subscriber"] = {
        "count": len(subscribers),
        "pids": [entry.get("pid") for entry in subscribers],
        "sha256": [entry.get("sha256") for entry in subscribers],
        "matches_staged": bool(subscribers)
        and all(entry.get("sha256") and entry.get("sha256") == report["staged"]["sha256"] for entry in subscribers),
        "replaced_stage": len(replaced),
    }
    if replaced:
        report["issues"].append("a subscriber is still running from a replaced .stage-old.* directory")
    if len(subscribers) != 1:
        report["issues"].append("expected exactly one live subscriber, found %d" % len(subscribers))
    elif not report["subscriber"]["matches_staged"]:
        report["issues"].append("the running subscriber SHA-256 does not match the staged binary")
    report["toggle"]["action_available"] = bool(report["plugin"] and report["plugin"]["toggle_available"])

    inspected = config.inspect(config_text.splitlines(keepends=True), config.DEFAULT_KEY)
    report["sidebar"] = {
        "section_present": inspected["sidebar_section_present"],
        "agent_tree_row_present": inspected["sidebar_token_present"],
        "managed_block_present": inspected["sidebar_managed_block_present"],
        "foreign_without_token": inspected["foreign_sidebar_block_without_token"],
    }
    report["shortcut"] = {
        "present": inspected["shortcut_matching_present"],
        "key": inspected["shortcut_key"],
        "occupied": inspected["shortcut_key_occupied"],
        "managed": inspected["shortcut_managed_block_present"],
    }
    if not inspected["sidebar_token_present"]:
        report["issues"].append("[ui.sidebar.agents] does not reference $agent_tree_row; the tree cannot render")
    if inspected["foreign_sidebar_block_without_token"]:
        report["notes"].append("a foreign [ui.sidebar.agents] block lacks the token and is left untouched")
    if not inspected["shortcut_matching_present"]:
        report["notes"].append("the documented %s toggle shortcut is not present" % inspected["shortcut_key"])

    panes = report["panes"]
    if panes["relationship_bearing"] == 0:
        report["notes"].append("no pane currently publishes a complete delegation relationship")
    if panes["delegated_missing_relationship"]:
        report["notes"].append(
            "%d pane(s) declare role worker/subagent but lack a complete relationship"
            % panes["delegated_missing_relationship"]
        )
    if panes["ordinary_pi"]:
        report["notes"].append("%d ordinary Pi pane(s) declare no role (not delegated-looking)" % panes["ordinary_pi"])

    if not report["issues"]:
        report["verdict"] = "healthy"
    elif report["herdr"] and report["herdr"]["reachable"] and report["herdr"]["running"] and report["herdr"]["compatible"]:
        report["verdict"] = "degraded"
    else:
        report["verdict"] = "unusable"
    return report


def split_state(reports) -> bool:
    verdicts = {report["verdict"] for report in reports}
    return "healthy" in verdicts and bool(verdicts - {"healthy"})


def render_text(reports, split: bool) -> str:
    lines = []
    for report in reports:
        head = "endpoint: %s (kind: %s" % (report["name"], report["kind"])
        if report["kind"] == "remote":
            head += ", machine %s, ssh %s, session %s" % (report["label"], report["target"], report["session"])
        head += ")"
        lines.append(head)
        if report["herdr"]:
            herdr = report["herdr"]
            lines.append(
                "  herdr:       running %s (protocol %s, compatible=%s, min %s)"
                % (herdr["version"], herdr["protocol"], herdr["compatible"], herdr["min_version"])
            )
        else:
            lines.append("  herdr:       unreachable (%s)" % "; ".join(report["issues"]))
        plugin = report["plugin"]
        if plugin and plugin["registered"]:
            lines.append(
                "  plugin:      %s %s %s at %s (source %s)"
                % (
                    plugin["name"],
                    plugin["version"],
                    "enabled" if plugin["enabled"] else "disabled",
                    plugin["plugin_root"],
                    plugin["source_kind"],
                )
            )
        else:
            lines.append("  plugin:      NOT registered")
        lines.append(
            "  staged:      %s%s"
            % (
                report["staged"]["sha256"] or "absent",
                "" if not report["staged"]["sha256"] else "  " + (report["staged"]["path"] or ""),
            )
        )
        subscriber = report["subscriber"]
        lines.append(
            "  subscriber:  %d running%s (sha256 %s)"
            % (
                subscriber["count"],
                "" if subscriber["count"] == 0 else " pids " + ",".join(str(pid) for pid in subscriber["pids"]),
                "matches staged" if subscriber["matches_staged"] else "does not match staged",
            )
        )
        lines.append(
            "  toggle:      action %s, tree-off %s"
            % ("available" if report["toggle"]["action_available"] else "unavailable", report["toggle"]["tree_off"])
        )
        lines.append(
            "  shortcut:    %s %s%s"
            % (
                "present" if report["shortcut"]["present"] else "absent",
                report["shortcut"]["key"],
                " (occupied by another command)" if report["shortcut"]["occupied"] else "",
            )
        )
        lines.append(
            "  sidebar:     $agent_tree_row %s"
            % ("present" if report["sidebar"]["agent_tree_row_present"] else "ABSENT")
        )
        panes = report["panes"]
        lines.append(
            "  panes:       relationship-bearing %d (valid %d), ranked %d, delegated-without-relationship %d, ordinary Pi %d"
            % (
                panes["relationship_bearing"],
                panes["relationship_valid"],
                panes["ranked"],
                panes["delegated_missing_relationship"],
                panes["ordinary_pi"],
            )
        )
        lines.append("  verdict:     %s" % report["verdict"])
        for issue in report["issues"]:
            lines.append("    issue: %s" % issue)
        for note in report["notes"]:
            lines.append("    note:  %s" % note)
    if split:
        lines.append("")
        lines.append("split state: one endpoint is healthy while another is degraded or unusable")
    lines.append("")
    lines.append(
        "routing: every line above targets the endpoint named on the command line; a machine "
        "selected in the TUI never retargets these commands."
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    reports = []
    with open(args.raw, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                reports.append(build_endpoint(json.loads(line)))

    split = split_state(reports)
    if args.json:
        print(json.dumps({"endpoints": reports, "split_state": split}, indent=2, sort_keys=True))
    else:
        sys.stdout.write(render_text(reports, split))
    return 0


if __name__ == "__main__":
    sys.exit(main())
