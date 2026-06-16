#!/usr/bin/env python3
"""PreToolUse hard-block guard for catastrophic, hard-to-undo operations.

Why this exists: the bridge can run in bypassPermissions mode (no per-tool
prompts) so it's hands-free from a phone. That convenience removes the human
"are you sure?" step, so a single bad command — from a model slip or a prompt
injection hidden in a forwarded document — could wipe a home directory or a
database before anyone notices. This guard restores one narrow backstop: it
hard-blocks a small set of UNAMBIGUOUSLY catastrophic shapes, and nothing else.

PreToolUse hooks still run (and their `deny` still blocks) even under
`--dangerously-skip-permissions` — the bypass flag skips permission *prompts*,
not hook evaluation — so this fires exactly where it's needed most.

What it blocks (Bash commands only):
  A. recursive `rm` hitting a protected path (home, ~/.claude, the bridge
     workdir) or a broad target (/, ~, $HOME, *, .)
  B. `git clean -f…d/x`  (irreversibly wipes untracked/ignored files)
  C. destructive SQL (DROP / TRUNCATE / DELETE FROM) in an execution context
  D. `dropdb`
  E. HTTP DELETE calls (curl -X DELETE, requests.delete(, method="DELETE")
  F. `find … -delete` targeting a protected path

Design guarantees:
  - FAIL OPEN: any internal error → allow. A guard that blocks every tool on a
    bug is worse than the risk it guards. Errors are logged, not raised.
  - Low false-positive bias: SQL only fires in an execution context, so grepping
    or documenting "drop table" is fine. Routine `rm -f file`, `rm -rf
    node_modules`, `rm -rf /tmp/x` all pass. A command whose leading program is a
    read-only/display tool (grep, echo, cat, …) is skipped, so searching FOR a
    dangerous string never trips the guard.
  - Path-agnostic: protected paths come from the running user's home and the
    bridge workdir (env BRIDGE_WORKDIR), not any hardcoded layout.

Contract: deny via permissionDecision JSON on stdout; allow via `{}`.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
from pathlib import Path

LOG = Path.home() / ".claude" / "channels" / "lark" / "destructive-guard.log"

# --- protected paths: the user's irreplaceable state. Built from the runtime
# environment so this works on any machine. .claude holds config/memory/sessions;
# the bridge workdir is where the agent operates. Broad targets (/, ~, $HOME, *)
# are matched separately by BROAD_TARGET. ---
_PROTECTED_NAMES = [r"\.claude", r"\.feishu-bridge"]
_workdir = os.environ.get("BRIDGE_WORKDIR", "").strip().rstrip("/")
if _workdir:
    _base = os.path.basename(_workdir)
    if _base and _base not in (".", "/"):
        _PROTECTED_NAMES.append(re.escape(_base))
PROTECTED = re.compile(
    r"""(?:^|[\s/~"'=(])"""
    r"(" + "|".join(_PROTECTED_NAMES) + r")"
    r"""(?:[/\s"'),;]|$)""",
    re.IGNORECASE | re.VERBOSE,
)
# rm rule: tie the protected name to an actual rm operand in the SAME command
# segment (stops at ; | & newline), so a recursive rm elsewhere + a protected name
# in an unrelated read (cat/grep on a path) no longer cross-trigger. PROTECTED
# (anywhere) is kept only for the find-delete rule, where the name is the operand.
PROTECTED_TARGET = re.compile(
    r"\brm\b[^\n;|&]*?\s(?:-\S+\s+)*[^\s;|&]*(" + "|".join(_PROTECTED_NAMES) + r")",
    re.IGNORECASE,
)

# Recursive flag must be an actual -FLAG token (right after rm, before operands) —
# NOT a dash inside a filename like "foo-run.sh". Consume leading flag tokens, then
# require a recursive flag token.
RM_RECURSIVE = re.compile(r"\brm\s+(?:-[a-zA-Z]*\s+)*(?:--recursive\b|-[a-zA-Z]*[rR])", re.IGNORECASE)
BROAD_TARGET = re.compile(r"\brm\b[^\n;|&]*?\s(?:-\S+\s+)*(/|~|\$HOME|\*|\.)(?:\s|$)", re.IGNORECASE)
GIT_CLEAN_DX = re.compile(r"\bgit\s+clean\b[^\n;|&]*-\w*[dx]", re.IGNORECASE)
GIT_CLEAN_F = re.compile(r"\bgit\s+clean\b[^\n;|&]*-\w*f", re.IGNORECASE)
SQL_DESTRUCTIVE = re.compile(
    r"\b(drop\s+(table|database|schema|index|view|materialized\s+view)|truncate\b|delete\s+from)\b",
    re.IGNORECASE,
)
SQL_EXEC_CTX = re.compile(
    r"\b(psql|mysql|sqlite3?|cursor|\.execute\s*\(|conn\.|engine\.|\.sql\b)|(-c\s)|(<<\s*['\"]?\w*EOF)",
    re.IGNORECASE,
)
DROPDB = re.compile(r"\bdropdb\b", re.IGNORECASE)
HTTP_DELETE = re.compile(
    r"(-X\s*DELETE\b|--request\s+DELETE\b|requests\.delete\s*\(|method\s*=\s*['\"]DELETE['\"])",
    re.IGNORECASE,
)
FIND_DELETE = re.compile(r"\bfind\b[^\n;|&]*\s-delete\b", re.IGNORECASE)

# If the command's leading program just reads/prints, the dangerous-looking text is
# data, not an operation — searching for "rm -rf /" must never trip the guard.
READONLY_LEAD = re.compile(
    r"^\s*(?:sudo\s+)?(?:grep|rg|ag|egrep|fgrep|echo|printf|cat|less|more|head|tail|awk|jq|ls)\b",
    re.IGNORECASE,
)


def find_hits(cmd: str) -> list[str]:
    # Skip commands whose primary verb only reads/prints (the documented
    # false-positive: grepping FOR a destructive string). Compound commands that
    # actually run a destructive op put it as the primary verb, so this is safe.
    if READONLY_LEAD.match(cmd):
        return []
    # Normalize shell-escaped spaces so a quoted path and a backslash-escaped one
    # (e.g. ~/My\ Files) match the same protected-name pattern.
    cmd = cmd.replace("\\ ", " ")
    hits = []
    if (RM_RECURSIVE.search(cmd)) and (BROAD_TARGET.search(cmd) or PROTECTED_TARGET.search(cmd)):
        hits.append("recursive `rm` on a protected path (home / .claude / workdir) or a broad target (/, ~, *, .)")
    if GIT_CLEAN_DX.search(cmd) and GIT_CLEAN_F.search(cmd):
        hits.append("`git clean -f…d/x` — irreversibly wipes untracked/ignored files")
    if SQL_DESTRUCTIVE.search(cmd) and SQL_EXEC_CTX.search(cmd):
        hits.append("destructive SQL (DROP / TRUNCATE / DELETE FROM) in an execution context")
    if DROPDB.search(cmd):
        hits.append("`dropdb` — drops an entire database")
    if HTTP_DELETE.search(cmd):
        hits.append("an HTTP DELETE call (deletes server-side data)")
    if FIND_DELETE.search(cmd) and (PROTECTED.search(cmd) or BROAD_TARGET.search(cmd)):
        hits.append("`find … -delete` targeting a protected path")
    return hits


def build_reason(cmd: str, hits: list[str]) -> str:
    shown = cmd if len(cmd) <= 400 else cmd[:400] + " …"
    bullets = "\n".join(f"  • {h}" for h in hits)
    return (
        "[DESTRUCTIVE-OP GUARD — BLOCKED]\n\n"
        "This command matches a catastrophic-deletion pattern and was stopped before it ran.\n\n"
        f"Matched:\n{bullets}\n\n"
        f"Command:\n  {shown}\n\n"
        "Why this guard exists: the bridge can run hands-free in bypass mode, so there is no "
        "human confirmation step. This blocks the few command shapes that can wipe a home "
        "directory or a database irreversibly.\n\n"
        "If this is genuinely intended:\n"
        "  - Narrow it — target a specific non-protected path, use an ID-scoped delete, add WHERE.\n"
        "  - Verify the blast radius first (count rows / read the endpoint semantics).\n"
        "  - Never bypass this guard for convenience."
    )


def log_block(cmd: str, hits: list[str]) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        with LOG.open("a", encoding="utf-8") as f:
            f.write(f"[{ts}] BLOCKED {hits} :: {cmd[:500]}\n")
    except Exception:
        pass


def main() -> int:
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            print("{}")
            return 0
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        hits = find_hits(cmd)
        if hits:
            reason = build_reason(cmd, hits)
            log_block(cmd, hits)
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                },
                "systemMessage": reason,
            }, ensure_ascii=False))
            return 0
        print("{}")
        return 0
    except Exception as e:  # FAIL OPEN — never block a tool because the guard errored
        try:
            LOG.parent.mkdir(parents=True, exist_ok=True)
            with LOG.open("a", encoding="utf-8") as f:
                f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] GUARD-ERROR(fail-open): {e!r}\n")
        except Exception:
            pass
        print("{}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
