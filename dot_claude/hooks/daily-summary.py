#!/usr/bin/env python3
"""
Aggregate all Claude Code sessions for a given day.

Usage:
    daily-summary [DATE]           # DATE in YYYY-MM-DD format, defaults to today
    daily-summary --project PATH   # Filter to specific project path
    daily-summary --json           # Output as JSON instead of formatted text

Examples:
    daily-summary                  # Today's sessions
    daily-summary 2026-01-12       # Specific date
    daily-summary --project "Knowledge Base"  # Filter by project
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

# Import the existing parser
SCRIPT_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from pathlib import Path

def find_all_sessions(projects_dir: Path) -> list[Path]:
    """Find all .jsonl session files."""
    sessions = []

    for project_dir in projects_dir.iterdir():
        if not project_dir.is_dir():
            continue

        # Direct .jsonl files in project dir
        for jsonl in project_dir.glob("*.jsonl"):
            sessions.append(jsonl)

        # .jsonl files in UUID subdirectories (resumed sessions)
        for subdir in project_dir.iterdir():
            if subdir.is_dir():
                for jsonl in subdir.glob("*.jsonl"):
                    sessions.append(jsonl)

    return sessions


def get_session_date_range(jsonl_path: Path) -> tuple[str | None, str | None]:
    """Extract first and last timestamp from a session."""
    first_ts = None
    last_ts = None

    try:
        with open(jsonl_path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    data = json.loads(line)
                    ts = data.get("timestamp")
                    if ts:
                        if first_ts is None:
                            first_ts = ts
                        last_ts = ts
                except json.JSONDecodeError:
                    continue
    except Exception:
        pass

    return first_ts, last_ts


def timestamp_to_date(ts: str) -> str | None:
    """Extract date (YYYY-MM-DD) from ISO timestamp."""
    if not ts:
        return None
    try:
        return ts[:10]  # "2026-01-12T..." -> "2026-01-12"
    except:
        return None


def decode_project_path(encoded: str) -> str:
    """Decode project path from directory name."""
    # "-Users-seigiard-Projects-core" -> "/Users/seigiard/Projects/core"
    return encoded.replace("-", "/")


def parse_session(jsonl_path: Path) -> dict:
    """Parse a session using the existing parser logic."""
    messages = []

    try:
        with open(jsonl_path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    messages.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except Exception:
        return {}

    if not messages:
        return {}

    # Extract basic info
    user_count = sum(1 for m in messages if m.get("type") == "user")
    assistant_count = sum(1 for m in messages if m.get("type") == "assistant")

    # Get timestamps
    timestamps = [m.get("timestamp") for m in messages if m.get("timestamp")]
    first_ts = timestamps[0] if timestamps else None
    last_ts = timestamps[-1] if timestamps else None

    # Get session ID and cwd
    session_id = None
    cwd = None
    for m in messages:
        if not session_id and m.get("sessionId"):
            session_id = m.get("sessionId")
        if not cwd and m.get("cwd"):
            cwd = m.get("cwd")
        if session_id and cwd:
            break

    # Extract tool usage
    tool_counts = defaultdict(int)
    files_written = set()
    files_edited = set()

    for msg in messages:
        if msg.get("type") != "assistant":
            continue

        message_data = msg.get("message", {})
        content = message_data.get("content", [])

        if not isinstance(content, list):
            continue

        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_use":
                continue

            tool_name = item.get("name", "")
            tool_input = item.get("input", {})
            tool_counts[tool_name] += 1

            if tool_name == "Write":
                fp = tool_input.get("file_path", "")
                if fp:
                    files_written.add(fp)
            elif tool_name == "Edit":
                fp = tool_input.get("file_path", "")
                if fp:
                    files_edited.add(fp)

    # Extract user topics (first few meaningful messages)
    topics = []
    for msg in messages:
        if msg.get("type") != "user":
            continue
        message_data = msg.get("message", {})
        content = message_data.get("content", "")

        if isinstance(content, str) and len(content) > 20:
            # Clean and truncate
            clean = content.replace("\n", " ").strip()[:100]
            if clean and not clean.startswith("<"):  # Skip XML/system messages
                topics.append(clean)
                if len(topics) >= 3:
                    break

    # Determine session type
    if files_written or files_edited:
        session_type = "Implementation"
    elif tool_counts.get("Read", 0) > 3 or tool_counts.get("Grep", 0) > 0:
        session_type = "Research"
    elif tool_counts.get("Task", 0) > 0:
        session_type = "Research (agents)"
    else:
        session_type = "Discussion"

    return {
        "session_id": session_id,
        "cwd": cwd,
        "message_count": len(messages),
        "user_messages": user_count,
        "assistant_messages": assistant_count,
        "first_timestamp": first_ts,
        "last_timestamp": last_ts,
        "session_type": session_type,
        "tool_calls": sum(tool_counts.values()),
        "tools_used": list(tool_counts.keys()),
        "files_created": len(files_written),
        "files_modified": len(files_edited),
        "topics": topics,
    }


def format_time(iso_ts: str) -> str:
    """Format ISO timestamp to readable time."""
    if not iso_ts:
        return "?"
    try:
        dt = datetime.fromisoformat(iso_ts.replace("Z", "+00:00"))
        return dt.strftime("%H:%M")
    except:
        return iso_ts[:16]


def format_duration(first_ts: str, last_ts: str) -> str:
    """Calculate and format session duration."""
    if not first_ts or not last_ts:
        return "?"
    try:
        start = datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
        end = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
        delta = end - start
        minutes = int(delta.total_seconds() / 60)
        if minutes < 60:
            return f"{minutes}m"
        hours = minutes // 60
        mins = minutes % 60
        return f"{hours}h{mins}m" if mins else f"{hours}h"
    except:
        return "?"


def simplify_path(path: str) -> str:
    """Simplify path for display."""
    home = str(Path.home())
    if path and path.startswith(home):
        path = "~" + path[len(home):]
    return path


def main():
    parser = argparse.ArgumentParser(description="Aggregate Claude Code sessions for a day")
    parser.add_argument("date", nargs="?", default=datetime.now().strftime("%Y-%m-%d"),
                        help="Date in YYYY-MM-DD format (default: today)")
    parser.add_argument("--project", "-p", help="Filter to project containing this string")
    parser.add_argument("--json", "-j", action="store_true", help="Output as JSON")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show more details")

    args = parser.parse_args()
    target_date = args.date

    # Find all sessions
    projects_dir = Path.home() / ".claude" / "projects"
    if not projects_dir.exists():
        print(f"No sessions directory found: {projects_dir}", file=sys.stderr)
        sys.exit(1)

    all_sessions = find_all_sessions(projects_dir)

    # Filter sessions by date
    matching_sessions = []

    for session_path in all_sessions:
        first_ts, last_ts = get_session_date_range(session_path)

        # Check if session overlaps with target date
        first_date = timestamp_to_date(first_ts)
        last_date = timestamp_to_date(last_ts)

        if first_date == target_date or last_date == target_date:
            # Filter by project if specified
            if args.project:
                project_name = session_path.parent.name
                decoded = decode_project_path(project_name)
                if args.project.lower() not in decoded.lower():
                    continue

            session_data = parse_session(session_path)
            if session_data and session_data.get("message_count", 0) > 0:
                session_data["file_path"] = str(session_path)
                session_data["project"] = decode_project_path(session_path.parent.name)
                matching_sessions.append(session_data)

    # Sort by first timestamp
    matching_sessions.sort(key=lambda s: s.get("first_timestamp", ""))

    # Output
    if args.json:
        print(json.dumps(matching_sessions, indent=2))
        return

    # Formatted text output
    if not matching_sessions:
        print(f"No sessions found for {target_date}")
        return

    print(f"═══ Daily Summary: {target_date} ═══")
    print(f"Sessions: {len(matching_sessions)}")

    total_messages = sum(s.get("message_count", 0) for s in matching_sessions)
    total_tools = sum(s.get("tool_calls", 0) for s in matching_sessions)
    total_created = sum(s.get("files_created", 0) for s in matching_sessions)
    total_modified = sum(s.get("files_modified", 0) for s in matching_sessions)

    print(f"Total: {total_messages} messages, {total_tools} tool calls")
    print(f"Files: {total_created} created, {total_modified} modified")
    print()

    # Group by project
    by_project = defaultdict(list)
    for s in matching_sessions:
        by_project[s.get("project", "unknown")].append(s)

    for project, sessions in by_project.items():
        print(f"─── {simplify_path(project)} ({len(sessions)} sessions) ───")

        for s in sessions:
            time_range = f"{format_time(s.get('first_timestamp'))}–{format_time(s.get('last_timestamp'))}"
            duration = format_duration(s.get("first_timestamp"), s.get("last_timestamp"))

            print(f"  [{time_range}] ({duration}) {s.get('session_type')}")
            print(f"    {s.get('message_count')} msgs, {s.get('tool_calls')} tools")

            if args.verbose and s.get("topics"):
                for topic in s["topics"][:2]:
                    print(f"    • {topic[:60]}{'...' if len(topic) > 60 else ''}")

        print()


if __name__ == "__main__":
    main()
