#!/usr/bin/env python3
"""Compare unique MyPinTool indirect-call pairs between two runs."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


Pair = tuple[str, int, int]


def discover_icall_files(root: Path) -> list[tuple[str, Path]]:
    resolved = root.resolve(strict=True)
    if resolved.is_file():
        if not resolved.name.endswith("_icall.json"):
            raise ValueError(f"Expected an *_icall.json file: {resolved}")
        return [(resolved.name, resolved)]
    if not resolved.is_dir():
        raise ValueError(f"Expected a file or directory: {resolved}")
    files = sorted(resolved.rglob("*_icall.json"))
    if not files:
        raise ValueError(f"No *_icall.json files found under: {resolved}")
    return [(path.relative_to(resolved).as_posix(), path) for path in files]


def parse_address(value: Any, *, label: str, path: Path) -> int:
    if not isinstance(value, str):
        raise ValueError(f"{path}: {label} address must be a string")
    try:
        return int(value, 0)
    except ValueError as error:
        raise ValueError(f"{path}: invalid {label} address {value!r}") from error


def load_pairs(root: Path) -> tuple[set[Pair], list[str]]:
    pairs: set[Pair] = set()
    identities: list[str] = []
    for identity, path in discover_icall_files(root):
        identities.append(identity)
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"{path}: top-level JSON value must be an object")
        for source_text, targets in payload.items():
            source = parse_address(source_text, label="source", path=path)
            if not isinstance(targets, list):
                raise ValueError(f"{path}: targets for {source_text!r} must be a list")
            for target_text in targets:
                target = parse_address(target_text, label="target", path=path)
                pairs.add((identity, source, target))
    return pairs, identities


def compare_pair_sets(baseline: set[Pair], candidate: set[Pair]) -> dict[str, Any]:
    new_pairs = candidate - baseline
    missing_pairs = baseline - candidate
    union = baseline | candidate
    return {
        "baseline_pair_count": len(baseline),
        "candidate_pair_count": len(candidate),
        "new_pair_count": len(new_pairs),
        "union_pair_count": len(union),
        "baseline_pairs_not_replayed": len(missing_pairs),
        "new_pair_examples": [
            {
                "binary": identity,
                "call_site": f"0x{source:x}",
                "target": f"0x{target:x}",
            }
            for identity, source, target in sorted(new_pairs)[:20]
        ],
    }


def nonnegative_int(value: str) -> int:
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return parsed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compare unique (binary, indirect-call-site, target) tuples in two "
            "MyPinTool runs. Use the same non-PIE binaries in both runs."
        )
    )
    parser.add_argument("baseline", type=Path, help="Baseline *_icall.json or directory")
    parser.add_argument("candidate", type=Path, help="Generated-test result or directory")
    parser.add_argument(
        "--require-new",
        type=nonnegative_int,
        default=0,
        help="Exit nonzero unless at least this many new pairs are observed",
    )
    parser.add_argument("--json-output", type=Path, help="Write the summary as JSON")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    baseline, baseline_files = load_pairs(args.baseline)
    candidate, candidate_files = load_pairs(args.candidate)
    summary = compare_pair_sets(baseline, candidate)
    summary["baseline_files"] = baseline_files
    summary["candidate_files"] = candidate_files

    rendered = json.dumps(summary, indent=2)
    print(rendered)
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(rendered + "\n", encoding="utf-8", newline="\n")
    if summary["new_pair_count"] < args.require_new:
        print(
            f"error: required at least {args.require_new} new pairs, "
            f"observed {summary['new_pair_count']}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
