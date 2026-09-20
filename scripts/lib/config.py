#!/usr/bin/env python3
"""Managed-fragment edits for a Herdr endpoint config.toml.

The plugin writes no configuration at runtime. The endpoint deploy manages exactly two
marked fragments and never touches anything else:

  * the sidebar rows block that must reference ``$agent_tree_row`` so the plugin's
    decoration has a cell to render into, and
  * the documented ``prefix+t`` shortcut that invokes ``agent-tree.toggle``.

Both are idempotent. An existing matching fragment is preserved byte-for-byte. A managed
shortcut fragment is migrated to the canonical ``prefix+t`` key; a foreign
``[ui.sidebar.agents]`` block that does not reference ``$agent_tree_row`` and a foreign
binding that already occupies the canonical shortcut key are refused before any mutation;
nothing in this file ever overwrites them.
"""
from __future__ import annotations

import argparse
import json
import re
import sys

SIDEBAR_BEGIN = "# >>> agent-tree sidebar rows >>>"
SIDEBAR_END = "# <<< agent-tree sidebar rows <<<"
SHORTCUT_BEGIN = "# >>> agent-tree toggle shortcut >>>"
SHORTCUT_END = "# <<< agent-tree toggle shortcut <<<"
SIDEBAR_HEADER = "[ui.sidebar.agents]"
TOKEN = "$agent_tree_row"
DEFAULT_KEY = "prefix+t"
DEFAULT_COMMAND = "herdr plugin action invoke agent-tree.toggle"
DEFAULT_ROWS = '[["state_icon", "$agent_tree_row", "terminal_title_stripped"]]'

# A TOML table header is a bare [name] or [[name]] line; an array element such as
# ["state_icon", ...] or [{ token = ... }] must never be mistaken for one.
TABLE_RE = re.compile(r"^\s*\[\[?[^,\[\]]*\]\]?\s*$")
KEY_RE = re.compile(r'^\s*key\s*=\s*"([^"]*)"\s*$')
COMMAND_RE = re.compile(r'^\s*command\s*=\s*"(.*)"\s*$')


class Refused(Exception):
    """A config state the deploy must refuse instead of overwriting."""


def read_lines(path: str) -> list[str]:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read().splitlines(keepends=True)


def write_text(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def section(lines: list[str], header: str) -> tuple[int, int] | None:
    start = None
    for index, line in enumerate(lines):
        if line.strip() == header:
            start = index
            break
    if start is None:
        return None
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if TABLE_RE.match(lines[index]):
            end = index
            break
    return start, end


def managed_block(lines: list[str], begin: str, end: str) -> tuple[tuple[int, int] | None, bool]:
    begins = [i for i, line in enumerate(lines) if line.strip() == begin]
    ends = [i for i, line in enumerate(lines) if line.strip() == end]
    if not begins and not ends:
        return None, False
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        return None, True
    return (begins[0], ends[0]), False


def key_commands(lines: list[str]) -> list[dict]:
    """Parse every ``[[keys.command]]`` block that has a key and a command."""
    blocks = []
    starts = [i for i, line in enumerate(lines) if line.strip() == "[[keys.command]]"]
    for index, start in enumerate(starts):
        end = len(lines)
        for cursor in range(start + 1, len(lines)):
            if TABLE_RE.match(lines[cursor]):
                end = cursor
                break
        key = None
        command = None
        for line in lines[start:end]:
            match = KEY_RE.match(line)
            if match:
                key = match.group(1)
            match = COMMAND_RE.match(line)
            if match:
                command = match.group(1)
        if key is not None:
            blocks.append({"key": key, "command": command or ""})
    return blocks


def toml_string(value: str) -> str:
    """Encode a value as a TOML basic string (escapes backslashes, quotes, controls)."""
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def sidebar_block(key: str, rows: str) -> str:
    return (
        f"{SIDEBAR_BEGIN}\n"
        f"{SIDEBAR_HEADER}\n"
        f"rows = {rows}\n"
        f"{SIDEBAR_END}\n"
    )


def shortcut_block(key: str, command: str) -> str:
    return (
        f"{SHORTCUT_BEGIN}\n"
        f"[[keys.command]]\n"
        f'key = {toml_string(key)}\n'
        f'type = "shell"\n'
        f'description = "Toggle Agent Tree ordering on or off"\n'
        f"command = {toml_string(command)}\n"
        f"{SHORTCUT_END}\n"
    )


def append_fragment(text: str, fragment: str) -> str:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    return text + fragment


def inspect(lines: list[str], key: str) -> dict:
    sidebar = section(lines, SIDEBAR_HEADER)
    token_present = sidebar is not None and any(
        TOKEN in lines[i] for i in range(sidebar[0], sidebar[1])
    )
    sidebar_managed, sidebar_damaged = managed_block(lines, SIDEBAR_BEGIN, SIDEBAR_END)
    shortcut_managed, shortcut_damaged = managed_block(lines, SHORTCUT_BEGIN, SHORTCUT_END)
    blocks = key_commands(lines)
    matching = [block for block in blocks if block["key"] == key and "agent-tree.toggle" in block["command"]]
    occupied = [block for block in blocks if block["key"] == key and "agent-tree.toggle" not in block["command"]]
    return {
        "sidebar_section_present": sidebar is not None,
        "sidebar_token_present": token_present,
        "sidebar_managed_block_present": sidebar_managed is not None,
        "sidebar_managed_block_damaged": sidebar_damaged,
        "foreign_sidebar_block_without_token": sidebar is not None and not token_present,
        "shortcut_key": key,
        "shortcut_matching_present": bool(matching),
        "shortcut_managed_block_present": shortcut_managed is not None,
        "shortcut_managed_block_damaged": shortcut_damaged,
        "shortcut_key_occupied": bool(occupied),
    }


def ensure(lines: list[str], rows: str, key: str, command: str) -> tuple[list[str], dict]:
    work = list(lines)
    changed = {"added_sidebar": False, "added_shortcut": False}

    sidebar = section(work, SIDEBAR_HEADER)
    sidebar_managed, sidebar_damaged = managed_block(work, SIDEBAR_BEGIN, SIDEBAR_END)
    if sidebar_managed is not None:
        body = [f"{SIDEBAR_HEADER}\n", f"rows = {rows}\n"]
        if work[sidebar_managed[0] + 1 : sidebar_managed[1]] != body:
            work[sidebar_managed[0] + 1 : sidebar_managed[1]] = body
            changed["added_sidebar"] = True
    elif sidebar_damaged:
        raise Refused("a damaged agent-tree sidebar block (need exactly one begin and one end marker, in order)")
    elif sidebar is not None:
        if not any(TOKEN in work[i] for i in range(sidebar[0], sidebar[1])):
            raise Refused(
                "a foreign [ui.sidebar.agents] block that does not reference $agent_tree_row"
            )
    else:
        text = append_fragment("".join(work), sidebar_block(key, rows))
        work = text.splitlines(keepends=True)
        changed["added_sidebar"] = True

    shortcut_managed, shortcut_damaged = managed_block(work, SHORTCUT_BEGIN, SHORTCUT_END)
    if shortcut_managed is not None:
        body = [
            "[[keys.command]]\n",
            f"key = {toml_string(key)}\n",
            'type = "shell"\n',
            'description = "Toggle Agent Tree ordering on or off"\n',
            f"command = {toml_string(command)}\n",
        ]
        if work[shortcut_managed[0] + 1 : shortcut_managed[1]] != body:
            # Migrating the managed block to the canonical key must never collide with a
            # foreign binding that already owns that key. Refuse before any mutation.
            if any(
                block["key"] == key and "agent-tree.toggle" not in block["command"]
                for block in key_commands(work)
            ):
                raise Refused(f"an occupied shortcut key {key!r} bound to another command")
            work[shortcut_managed[0] + 1 : shortcut_managed[1]] = body
            changed["added_shortcut"] = True
    elif shortcut_damaged:
        raise Refused("a damaged agent-tree shortcut block (need exactly one begin and one end marker, in order)")
    else:
        blocks = key_commands(work)
        if any(block["key"] == key and "agent-tree.toggle" not in block["command"] for block in blocks):
            raise Refused(f"an occupied shortcut key {key!r} bound to another command")
        if any(block["key"] == key and "agent-tree.toggle" in block["command"] for block in blocks):
            pass
        else:
            text = append_fragment("".join(work), shortcut_block(key, command))
            work = text.splitlines(keepends=True)
            changed["added_shortcut"] = True

    return work, changed


def remove(lines: list[str]) -> tuple[list[str], dict]:
    changed = {"removed_sidebar": False, "removed_shortcut": False}
    for begin, end, flag in (
        (SIDEBAR_BEGIN, SIDEBAR_END, "removed_sidebar"),
        (SHORTCUT_BEGIN, SHORTCUT_END, "removed_shortcut"),
    ):
        block, damaged = managed_block(lines, begin, end)
        if damaged:
            raise Refused(
                "a damaged agent-tree managed fragment (need exactly one begin and one end "
                "marker, in order); refusing to remove around it"
            )
        if block is None:
            continue
        del lines[block[0] : block[1] + 1]
        changed[flag] = True
    text = "".join(lines).rstrip("\n")
    if text:
        text += "\n"
    return text.splitlines(keepends=True), changed


def emit_error(message: str) -> int:
    sys.stderr.write(f"config: {message}\n")
    print(json.dumps({"error": message}))
    return 3


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    p_inspect = sub.add_parser("inspect")
    p_inspect.add_argument("--file", required=True)
    p_inspect.add_argument("--key", default=DEFAULT_KEY)
    p_ensure = sub.add_parser("ensure")
    p_ensure.add_argument("--file", required=True)
    p_ensure.add_argument("--out", required=True)
    p_ensure.add_argument("--rows", default=DEFAULT_ROWS)
    p_ensure.add_argument("--key", default=DEFAULT_KEY)
    p_ensure.add_argument("--command", default=DEFAULT_COMMAND)
    p_remove = sub.add_parser("remove")
    p_remove.add_argument("--file", required=True)
    p_remove.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.action == "inspect":
        print(json.dumps(inspect(read_lines(args.file), args.key), sort_keys=True))
        return 0

    if args.action == "ensure":
        try:
            work, changed = ensure(read_lines(args.file), args.rows, args.key, args.command)
        except Refused as exc:
            return emit_error(str(exc))
        write_text(args.out, "".join(work))
        print(json.dumps({"changed": any(changed.values()), **changed}, sort_keys=True))
        return 0

    try:
        work, changed = remove(read_lines(args.file))
    except Refused as exc:
        return emit_error(str(exc))
    write_text(args.out, "".join(work))
    print(json.dumps({"changed": any(changed.values()), **changed}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
