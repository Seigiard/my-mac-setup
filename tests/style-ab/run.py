#!/usr/bin/env python3
"""Run a style A/B matrix and leave a run directory.

Three arms answer the same prompts: an empty control, a baseline, and a
candidate. The only difference between arms is the file appended to the system
prompt, so a difference in the responses is attributable to that file.

This module owns execution and the run directory. `score.py` turns a run
directory into counts and the mechanical half of the report; `rating.py` owns
the blind human leg. Neither is invoked from here.

Usage:
  python3 tests/style-ab/run.py --limit 2 --runs 1 --lang both
  python3 tests/style-ab/run.py --baseline 0c5c33a^ --candidate 0c5c33a --lang en
  python3 tests/style-ab/run.py --baseline HEAD --candidate HEAD --allow-identical
"""

import argparse
import concurrent.futures as futures
import hashlib
import importlib.machinery
import importlib.util
import json
import random
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[1]
RUNS = HERE / "runs"
PROMPTS = HERE / "prompts"

# Both flags are load-bearing and are attested in the manifest (KTD5).
# --settings neutralises the operator's deployed output style, which would
# otherwise leak into all three arms and stop the control being a control.
# --allowed-tools keeps every arm tool-free.
SETTINGS_FLAG = '{"outputStyle":"default"}'
JOB_TIMEOUT_SECONDS = 300


def load_variants():
    path = HERE / "variants.py"
    loader = importlib.machinery.SourceFileLoader("style_ab_variants", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


variants = load_variants()


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_prompts(languages):
    """Return [(prompt_id, language, text)] in file order, English first."""
    rows = []
    for language in languages:
        source = PROMPTS / f"core-{language}.tsv"
        for line_number, line in enumerate(source.read_text().splitlines(), 1):
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) != 3:
                raise SystemExit(f"{source}:{line_number}: expected 3 tab-separated fields")
            prompt_id, declared, text = parts
            if declared != language:
                raise SystemExit(
                    f"{source}:{line_number}: row declares language {declared!r} "
                    f"but lives in the {language!r} set"
                )
            rows.append((prompt_id, declared, text))
    return rows


def build_matrix(prompts, arms, repeats, seed):
    """Prompt-major, arm-minor, so one prompt's arms land adjacent in time (KTD6).

    Arms of the same prompt are the paired unit. Executing them far apart in
    wall-clock time would let drift in the service sit inside the pair.
    """
    jobs = []
    for prompt_id, language, text in prompts:
        for repeat in range(1, repeats + 1):
            for arm_name in arms:
                jobs.append({
                    "prompt_id": prompt_id,
                    "language": language,
                    "text": text,
                    "arm": arm_name,
                    "repeat": repeat,
                })
    random.Random(seed).shuffle(jobs)
    jobs.sort(key=lambda job: (prompts.index((job["prompt_id"], job["language"], job["text"])),
                               job["repeat"]))
    return jobs


def response_path(run_dir, job):
    return run_dir / "responses" / (
        f"{job['language']}__{job['prompt_id']}__{job['arm']}__r{job['repeat']}.txt"
    )


def run_job(job, run_dir, arm_files, model):
    """Run one `claude` invocation in a fresh empty directory outside any repo.

    The working directory matters: run from the repository root, `claude` would
    auto-discover this repository's CLAUDE.md and the user's global one into
    every arm (R6). The scratchpad harness got this right by accident.
    """
    target = response_path(run_dir, job)
    if target.exists() and target.stat().st_size > 0:
        return {"job": job, "status": "skipped"}

    command = [
        "claude", "-p", job["text"],
        "--model", model,
        "--allowed-tools", "",
        "--settings", SETTINGS_FLAG,
    ]
    arm_file = arm_files[job["arm"]]
    if arm_file is not None:
        command += ["--append-system-prompt-file", str(arm_file)]

    workdir = tempfile.mkdtemp(prefix="style-ab-job-")
    started = time.time()
    try:
        completed = subprocess.run(
            command, cwd=workdir, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=JOB_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return {"job": job, "status": "timeout",
                "reason": f"exceeded {JOB_TIMEOUT_SECONDS}s"}
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if completed.returncode != 0:
        return {"job": job, "status": "failed",
                "reason": f"exit {completed.returncode}",
                "stderr_tail": completed.stderr[-400:]}
    if not completed.stdout.strip():
        return {"job": job, "status": "failed", "reason": "empty response"}

    target.write_text(completed.stdout)
    return {"job": job, "status": "ok", "seconds": round(time.time() - started, 1)}


def claude_version():
    try:
        out = subprocess.run(["claude", "--version"], capture_output=True,
                             text=True, timeout=30)
        return out.stdout.strip() or "unknown"
    except Exception as error:  # noqa: BLE001 - the version is metadata, never a gate
        return f"unavailable: {error}"


def resolve_arms(args):
    base = variants.resolve("base", REPOSITORY)
    baseline = variants.resolve(args.baseline, REPOSITORY)
    candidate = variants.resolve(args.candidate, REPOSITORY)

    if variants.identical(baseline, candidate) and not args.allow_identical:
        raise SystemExit(
            "baseline and candidate resolve to identical bytes, so this run would "
            "measure nothing.\n"
            f"  baseline  {args.baseline!r} -> {baseline.source} "
            f"sha256 {baseline.sha256[:16]}\n"
            f"  candidate {args.candidate!r} -> {candidate.source} "
            f"sha256 {candidate.sha256[:16]}\n"
            "Pass --allow-identical to take this as an A/A calibration run."
        )
    return {"base": base, "baseline": baseline, "candidate": candidate}


def write_arm_files(run_dir, arms):
    """Materialise each arm's text so `claude` can read it, and record the bytes."""
    directory = run_dir / "arms"
    directory.mkdir(parents=True, exist_ok=True)
    files = {}
    for name, arm in arms.items():
        if name == "base":
            files[name] = None
            continue
        path = directory / f"{name}.md"
        path.write_text(arm.text)
        files[name] = path
    return files


def build_manifest(args, arms, prompts, jobs, results, run_id, started_at):
    counts = {}
    for result in results:
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    score_path = HERE / "score.py"
    return {
        "run_id": run_id,
        "started_at": started_at,
        "finished_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "model": args.model,
        "claude_version": claude_version(),
        "arms": {
            name: {
                "spec": arm.spec, "kind": arm.kind, "source": arm.source,
                "sha256": arm.sha256, "commit": arm.commit, "tokens": arm.tokens,
            }
            for name, arm in arms.items()
        },
        "prompt_sets": [
            {"path": str((PROMPTS / f"core-{language}.tsv").relative_to(REPOSITORY)),
             "sha256": sha256_file(PROMPTS / f"core-{language}.tsv")}
            for language in args.languages
        ],
        "prompt_count": len(prompts),
        "repeats": args.runs,
        "job_count": len(jobs),
        "job_seed": args.seed,
        "rating_seed": args.rating_seed,
        "job_cwd": "a fresh empty temporary directory per job, outside any repository",
        "scorer_sha256": sha256_file(score_path) if score_path.exists() else None,
        "status_counts": counts,
        "attestation": {
            "settings_flag": SETTINGS_FLAG,
            "allowed_tools": "",
            "applied_to_every_invocation": True,
        },
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--baseline", default="HEAD",
                        help="git ref, file path, 'worktree', or 'base' (default: HEAD)")
    parser.add_argument("--candidate", default="worktree",
                        help="git ref, file path, 'worktree', or 'base' (default: worktree)")
    parser.add_argument("--allow-identical", action="store_true",
                        help="permit identical arms; this is how an A/A calibration is taken")
    parser.add_argument("--lang", choices=["en", "ru", "both"], default="both")
    parser.add_argument("--runs", type=int, default=2, help="repeats per prompt per arm")
    parser.add_argument("--limit", type=int, default=0,
                        help="use only the first N prompts of each language")
    parser.add_argument("--model", default="sonnet")
    parser.add_argument("--seed", type=int, default=1729, help="job-order seed")
    parser.add_argument("--rating-seed", type=int, default=4242,
                        help="pair-order seed for the human leg; independent of --seed")
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args(argv)

    args.languages = ["en", "ru"] if args.lang == "both" else [args.lang]

    arms = resolve_arms(args)
    prompts = read_prompts(args.languages)
    if args.limit:
        kept = []
        for language in args.languages:
            in_language = [row for row in prompts if row[1] == language]
            kept.extend(in_language[:args.limit])
        prompts = kept

    jobs = build_matrix(prompts, list(arms), args.runs, args.seed)

    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    started_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    run_dir = RUNS / run_id
    (run_dir / "responses").mkdir(parents=True, exist_ok=True)
    arm_files = write_arm_files(run_dir, arms)

    print(f"run {run_id}: {len(jobs)} jobs, {len(prompts)} prompts, "
          f"{len(arms)} arms, {args.runs} repeat(s)")
    for name, arm in arms.items():
        print(f"  {name:<10} {arm.source} sha256 {arm.sha256[:16]} tokens {arm.tokens}")

    results = []
    with futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = [pool.submit(run_job, job, run_dir, arm_files, args.model) for job in jobs]
        for done in futures.as_completed(pending):
            result = done.result()
            results.append(result)
            job = result["job"]
            marker = {"ok": ".", "skipped": "-", "failed": "F", "timeout": "T"}[result["status"]]
            print(marker, end="", flush=True)
    print()

    # A failed or timed-out job is recorded, never silently absent: score.py globs
    # the files that exist, and a vanished job would quietly shrink the denominator.
    failures = [r for r in results if r["status"] in ("failed", "timeout")]
    if failures:
        with (run_dir / "failures.jsonl").open("w") as handle:
            for failure in failures:
                handle.write(json.dumps(failure) + "\n")

    manifest = build_manifest(args, arms, prompts, jobs, results, run_id, started_at)
    (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False))

    print(f"\n{run_dir.relative_to(REPOSITORY)}")
    print(f"  {manifest['status_counts']}")
    if failures:
        print(f"  {len(failures)} job(s) recorded in failures.jsonl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
