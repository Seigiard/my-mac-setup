#!/usr/bin/env python3
"""Module-level evidence for analyse-architecture: co-change and import graph.

Both subcommands map files to modules first. A module is the longest matching
--module prefix; without --module, it is the first --depth directory segments.
Files outside every --module prefix, or outside --scope in depth mode, are out
of scope and ignored.
"""

import argparse
from collections import Counter, defaultdict
from itertools import combinations
import json
import subprocess
import sys


def module_mapper(modules, depth, scopes):
    prefixes = sorted((m.strip("/") for m in modules), key=len, reverse=True)
    scopes = [s.strip("/") for s in scopes]

    def under(path, prefix):
        return path == prefix or path.startswith(prefix + "/")

    def to_module(path):
        path = path.strip("/")
        if prefixes:
            return next((p for p in prefixes if under(path, p)), None)
        if scopes and not any(under(path, s) for s in scopes):
            return None
        parts = path.split("/")
        return "/".join(parts[:min(depth, len(parts) - 1)]) or "(root)"

    return to_module


def git_commits(repo, since):
    cmd = ["git", "-C", repo, "log", "--no-merges", "--name-only", "--format=%x00%H"]
    if since:
        cmd.append(f"--since={since}")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"git log failed: {result.stderr.strip()}")
    for block in result.stdout.split("\0")[1:]:
        lines = [line for line in block.splitlines() if line.strip()]
        yield lines[0], lines[1:]


def cochange(args, to_module):
    per_module = Counter()
    together = Counter()
    analysed = skipped = 0
    for _sha, files in git_commits(args.repo, args.since):
        if len(files) > args.max_files:
            skipped += 1
            continue
        touched = {m for m in map(to_module, files) if m}
        if not touched:
            continue
        analysed += 1
        per_module.update(touched)
        together.update(combinations(sorted(touched), 2))
    pairs = []
    for (a, b), count in together.items():
        if count < args.min_together:
            continue
        ratio = count / min(per_module[a], per_module[b])
        pairs.append({"a": a, "b": b, "together": count, "ratio": round(ratio, 2)})
    pairs.sort(key=lambda p: (-p["ratio"], -p["together"], p["a"], p["b"]))
    return {
        "commits_analysed": analysed,
        "commits_skipped_bulk": skipped,
        "modules": dict(sorted(per_module.items(), key=lambda kv: (-kv[1], kv[0]))),
        "pairs": pairs[: args.top],
    }


def strongly_connected(nodes, edges):
    index, low, stack, on_stack, groups = {}, {}, [], set(), []

    def visit(node):
        index[node] = low[node] = len(index)
        stack.append(node)
        on_stack.add(node)
        for nxt in edges.get(node, ()):
            if nxt not in index:
                visit(nxt)
                low[node] = min(low[node], low[nxt])
            elif nxt in on_stack:
                low[node] = min(low[node], index[nxt])
        if low[node] == index[node]:
            group = []
            while True:
                member = stack.pop()
                on_stack.discard(member)
                group.append(member)
                if member == node:
                    break
            if len(group) > 1:
                groups.append(sorted(group))

    sys.setrecursionlimit(max(1000, 4 * len(nodes)))
    for node in sorted(nodes):
        if node not in index:
            visit(node)
    return sorted(groups)


def imports(args, to_module):
    with open(args.graph) as handle:
        graph = json.load(handle)
    prefix = args.prefix.strip("/")

    def full(path):
        return f"{prefix}/{path}" if prefix else path

    edges = Counter()
    internal = Counter()
    nodes = set()
    for source, deps in graph.items():
        src = to_module(full(source))
        if not src:
            continue
        nodes.add(src)
        for dep in deps:
            dst = to_module(full(dep))
            if not dst:
                continue
            nodes.add(dst)
            if dst == src:
                internal[src] += 1
            else:
                edges[(src, dst)] += 1

    adjacency = defaultdict(set)
    for (a, b) in edges:
        adjacency[a].add(b)
    two_way = sorted(
        ({"a": a, "b": b, "a_to_b": n, "b_to_a": edges[(b, a)]}
         for (a, b), n in edges.items() if a < b and (b, a) in edges),
        key=lambda p: (p["a"], p["b"]),
    )
    modules = {}
    for node in sorted(nodes):
        outgoing = sum(n for (a, _), n in edges.items() if a == node)
        modules[node] = {
            "fan_in": sum(1 for (_, b) in edges if b == node),
            "fan_out": len(adjacency[node]),
            "internal_imports": internal[node],
            "external_imports": outgoing,
        }
    return {
        "modules": modules,
        "edges": [
            {"from": a, "to": b, "imports": n}
            for (a, b), n in sorted(edges.items(), key=lambda kv: (-kv[1], kv[0]))
        ],
        "two_way": two_way,
        "cycles": strongly_connected(nodes, adjacency),
    }


def print_cochange(data):
    print(f"commits analysed: {data['commits_analysed']}, "
          f"skipped as bulk: {data['commits_skipped_bulk']}")
    print("\ncommits per module:")
    for module, count in data["modules"].items():
        print(f"  {count:5}  {module}")
    print("\npairs changed together (ratio = together / commits of the smaller module):")
    for p in data["pairs"]:
        print(f"  {p['ratio']:.2f}  {p['together']:4}  {p['a']}  <->  {p['b']}")


def print_imports(data):
    print("modules (fan-in, fan-out, internal imports, external imports):")
    for module, m in data["modules"].items():
        print(f"  {m['fan_in']:3} {m['fan_out']:3} {m['internal_imports']:5} "
              f"{m['external_imports']:5}  {module}")
    print("\nedges (imports from -> to):")
    for e in data["edges"]:
        print(f"  {e['imports']:5}  {e['from']}  ->  {e['to']}")
    print("\ntwo-way pairs:")
    for p in data["two_way"]:
        print(f"  {p['a']} -> {p['b']}: {p['a_to_b']}, back: {p['b_to_a']}")
    print("\ncycles between modules:")
    for group in data["cycles"]:
        print("  " + "  ".join(group))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("cochange", "imports"):
        p = sub.add_parser(name)
        p.add_argument("--module", action="append", default=[],
                       help="module path prefix; repeat for each module")
        p.add_argument("--depth", type=int, default=2,
                       help="directory segments that name a module when --module is absent")
        p.add_argument("--scope", action="append", default=[],
                       help="in depth mode, only count files under this prefix")
        p.add_argument("--json", action="store_true")
    co = sub.choices["cochange"]
    co.add_argument("--repo", default=".")
    co.add_argument("--since", default="12 months ago")
    co.add_argument("--max-files", type=int, default=50,
                    help="skip commits touching more files (renames, formatting)")
    co.add_argument("--min-together", type=int, default=3)
    co.add_argument("--top", type=int, default=40)
    im = sub.choices["imports"]
    im.add_argument("graph", help="JSON object {file: [imported files]}, as madge --json prints")
    im.add_argument("--prefix", default="",
                    help="prepend to every graph path so it matches repository paths")
    args = parser.parse_args()

    to_module = module_mapper(args.module, args.depth, args.scope)
    if args.command == "cochange":
        data = cochange(args, to_module)
        printer = print_cochange
    else:
        data = imports(args, to_module)
        printer = print_imports
    if args.json:
        json.dump(data, sys.stdout, indent=2)
        print()
    else:
        printer(data)


if __name__ == "__main__":
    main()
