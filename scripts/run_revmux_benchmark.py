#!/usr/bin/env python3
"""Run isolated, repeatable revmux benchmark rounds."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def command(arguments, *, cwd=None):
    result = subprocess.run(arguments, cwd=cwd, check=True, capture_output=True, text=True)
    return result.stdout


class ToolFailure(RuntimeError):
    """A git or revmux setup command failed, with its diagnostic preserved."""

    def __init__(self, arguments, result):
        self.arguments = arguments
        self.result = result
        super().__init__(result.stderr.strip() or "no stderr output")


def full_revision(repository, revision):
    arguments = ["git", "-C", str(repository), "rev-parse", "--verify",
                 f"{revision}^{{commit}}"]
    result = subprocess.run(arguments, check=False, capture_output=True, text=True)
    if result.returncode:
        raise ToolFailure(arguments, result)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", type=Path, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--arm", required=True)
    parser.add_argument("--repetitions", type=int, required=True)
    parser.add_argument("--tasks-dir", type=Path, required=True)
    parser.add_argument("--revmux", default="revmux")
    args = parser.parse_args()
    # macOS exposes /var through a symlink; retain the operator's spelling in
    # archive paths so stand-ins and real revmux receive the same location.
    operator_cwd = Path(str(Path.cwd()).replace("/private/var/", "/var/", 1))
    args.case = (operator_cwd / args.case) if not args.case.is_absolute() else args.case
    args.tasks_dir = ((operator_cwd / args.tasks_dir)
                      if not args.tasks_dir.is_absolute() else args.tasks_dir)
    args.revmux = (operator_cwd / args.revmux) if os.sep in str(args.revmux) and not Path(args.revmux).is_absolute() else args.revmux
    case = json.loads(args.case.read_text(encoding="utf-8"))
    repository = Path(case["repository"])
    if not repository.is_absolute():
        repository = (operator_cwd / repository).resolve()

    task_names = [f"{case['id']}-{args.arm}-{repetition}"
                  for repetition in range(1, args.repetitions + 1)]
    existing = [args.tasks_dir / task for task in task_names
                if (args.tasks_dir / task).exists()]
    if existing:
        for path in existing:
            print(f"benchmark task already exists: {path}", file=sys.stderr)
        return 1
    args.tasks_dir.mkdir(parents=True, exist_ok=True)

    failed_tasks = []
    for repetition in range(1, args.repetitions + 1):
        task = f"{case['id']}-{args.arm}-{repetition}"
        worktree_root = Path(tempfile.mkdtemp(prefix="revmux-bench-")).resolve()
        worktree = worktree_root / "checkout"
        try:
            new_output = json.loads(command([
                args.revmux, "new", "--task", task, "--run", "01-bench",
                "--tasks-dir", str(args.tasks_dir),
            ], cwd=operator_cwd))
            try:
                base = full_revision(repository, case["base"])
                head = full_revision(repository, case["head"])
                resolution_failed = False
            except ToolFailure as failure:
                print(f"revmux tool failure for {task}: {failure}", file=sys.stderr)
                failed_tasks.append(task)
                base, head = case["base"], case["head"]
                resolution_failed = True
            scope = (f"Range: {base}..{head}\n"
                     f"git diff {base}..{head}\n\n{case['scope']}")
            Path(new_output["scope"]).write_text(scope, encoding="utf-8")
            Path(new_output["goal"]).write_text(case["goal"], encoding="utf-8")
            Path(new_output["round_dir"], "bench.json").write_text(
                json.dumps({"case": case["id"], "arm": args.arm, "repetition": repetition,
                            "base": base, "head": head, "profile": args.profile,
                            "cwd": str(worktree)}, indent=2) + "\n", encoding="utf-8")
            if resolution_failed:
                shutil.rmtree(worktree_root, ignore_errors=True)
                continue
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as failure:
            failed_tasks.append(task)
            print(f"revmux tool failure for {task}: {failure}", file=sys.stderr)
            continue
        try:
            # A linked worktree shares the operator's refs and git common dir.
            # Build a detached, fetch-based clone so the review cannot see them.
            command(["git", "init", "--quiet", str(worktree)])
            command(["git", "-C", str(worktree), "fetch", "--quiet", str(repository),
                     head, base])
            command(["git", "-C", str(worktree), "checkout", "--quiet", "--detach",
                     head])
            run = subprocess.run(
                [args.revmux, "--task", task, "--run", "01-bench", "--workdir",
                 str(worktree), "--profile", args.profile, "--no-tui", "--tasks-dir",
                 str(args.tasks_dir)],
                cwd=worktree, capture_output=True, text=True, check=False,
            )
            if run.returncode not in (0, 1):
                failed_tasks.append(task)
                message = run.stderr.strip() or "no stderr output"
                print(f"revmux tool failure for {task}: {message}", file=sys.stderr)
        except (ToolFailure, subprocess.CalledProcessError) as failure:
            failed_tasks.append(task)
            detail = getattr(failure, "stderr", None) or str(failure)
            print(f"revmux tool failure for {task}: {detail.strip()}", file=sys.stderr)
        finally:
            shutil.rmtree(worktree_root, ignore_errors=True)
    if failed_tasks:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
