# cursor-governance-managed:1.0.0
"""Cursor beforeShellExecution adapter. Policy stays in scripts/preflight.sh."""
import json
import os
import re
import subprocess
import sys

PUSH = re.compile(
    r"(?:^|[|&;\n]|&&|\|\|)\s*(?:[\w.\\/:-]*git(?:\.exe)?(?:\s+-C\s+\S+)?\s+push\b)",
    re.I,
)
PR = re.compile(
    r"(?:^|[|&;\n]|&&|\|\|)\s*(?:[\w.\\/:-]*gh(?:\.exe)?\s+pr\s+(?:create|merge)\b)",
    re.I,
)
MIGRATE = re.compile(
    r"(?:^|[|&;\n]|&&|\|\|)\s*(?:[\w.\\/:-]+\s+)*(?:npx\s+)?(?:prisma\s+migrate|alembic\s+revision|django-admin\s+makemigrations|python(?:3)?\s+manage\.py\s+makemigrations|dotnet\s+ef\s+migrations\s+add|knex\s+migrate:make|typeorm\s+migration:generate)\b",
    re.I,
)
RECORD = re.compile(
    r"(?:^|[|&;\n]|&&|\|\|)\s*.*\b(?:RecordScreen|record-screen)\b",
    re.I,
)


def emit(payload, code):
    sys.stdout.buffer.write(json.dumps(payload, ensure_ascii=False).encode("utf-8") + b"\n")
    sys.stdout.buffer.flush()
    raise SystemExit(code)


def allow():
    emit({"permission": "allow"}, 0)


def deny(message):
    text = (message or "PREFLIGHT_BLOCK").strip()
    if len(text) > 1500:
        text = text[:1500]
    emit(
        {
            "permission": "deny",
            "user_message": "Governance blocked this command.",
            "agent_message": text,
        },
        2,
    )


def normalize(path):
    if not path or not isinstance(path, str):
        return ""
    path = path.strip().strip('"')
    if path.startswith("file:///"):
        path = path[8:]
        path = path.replace("/", os.sep)
    if len(path) >= 4 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    try:
        return os.path.abspath(path)
    except OSError:
        return ""


def find_root(start):
    start = normalize(start)
    if not start or not os.path.isdir(start):
        return ""
    cur = start
    while True:
        git_path = os.path.join(cur, ".git")
        if os.path.isdir(git_path) or os.path.isfile(git_path):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return ""
        cur = parent


def load_input():
    raw = sys.stdin.buffer.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    if not raw.strip():
        return {}
    return json.loads(raw.decode("utf-8"))


def bash_bin():
    if os.name != "nt":
        for candidate in ("/bin/bash", "/usr/bin/bash"):
            if os.path.isfile(candidate):
                return candidate
    for candidate in (
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
    ):
        if os.path.isfile(candidate):
            return candidate
    return ""


def mode_for(command):
    if MIGRATE.search(command):
        return "migrate"
    if RECORD.search(command):
        return "record"
    if PR.search(command):
        return "pr"
    if PUSH.search(command):
        return "push"
    return ""


def main():
    try:
        data = load_input()
    except (json.JSONDecodeError, UnicodeError):
        allow()
    command = data.get("command") or ""
    mode = mode_for(command)
    if not mode:
        allow()
    roots = []
    cwd = normalize(data.get("cwd") or "")
    if cwd:
        roots.append(cwd)
    for item in data.get("workspace_roots") or []:
        roots.append(normalize(item))
    root = ""
    for start in roots:
        root = find_root(start)
        if root and os.path.isfile(os.path.join(root, ".cursor", "governance.json")):
            break
        root = ""
    if not root:
        allow()
    script = os.path.join(root, "scripts", "guard-push.sh")
    if not os.path.isfile(script):
        allow()
    bash = bash_bin()
    if not bash:
        deny("PREFLIGHT_BLOCK\nreason=BASH_MISSING")
    env = os.environ.copy()
    env["GOVERNANCE_MODE"] = mode
    env["GOVERNANCE_COMMAND"] = command
    try:
        proc = subprocess.run(
            [bash, script],
            cwd=root,
            env=env,
            capture_output=True,
            text=True,
            timeout=45,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        deny("PREFLIGHT_BLOCK\nreason=GUARD_FAILED\n" + str(exc))
    if proc.returncode == 0:
        allow()
    message = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
    deny(message)


if __name__ == "__main__":
    main()
