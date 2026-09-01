#!/usr/bin/env python3
"""Verify the package-based C1 experiment and write verification.json."""

from __future__ import annotations

import gzip
import hashlib
import json
import shutil
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any

import angr
import dgl


BINARY_NAME = "ZydisInfo"
PACKAGE_REVISION = "b24321b2f1041af560173d8036541fc8c376b849"


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def load_mapping(path: Path) -> dict[str, list[str]]:
    payload = load_json(path)
    if payload is None:
        return {}
    assert isinstance(payload, dict), f"expected an object or null: {path}"
    return payload


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def pairs(payload: dict[str, list[str]]) -> set[tuple[str, str]]:
    return {
        (source.lower(), target.lower())
        for source, targets in payload.items()
        for target in targets
    }


def verify(root: Path) -> dict[str, Any]:
    name = BINARY_NAME
    static_root = root / "static"
    sourceinfo = static_root / f"sourceinfo/{name}"
    result_dir = static_root / f"res/{name}"

    required = [
        root / "package-url.txt",
        root / "package-revision.txt",
        root / "package/zydis/wrapped-executions.tsv",
        root / "package/zydis/test.log",
        root / f"labeled/{name}",
        root / f"dynamic/{name}_icall.json",
        root / f"dynamic/{name}_ijump.json",
        root / f"stripped/{name}",
        root / "proof/text-before.bin",
        root / "proof/text-after.bin",
        sourceinfo / f"{name}_icallinstocallee.json",
        sourceinfo / f"{name}_jmptable.json",
        result_dir / f"{name}_icallbbtocallee.json",
        result_dir / f"{name}_correctjumptable.json",
        result_dir / f"{name}_itcbbtofunc.json",
        result_dir / f"{name}_ret.json",
        result_dir / f"{name}_nodelookup.json",
        result_dir / f"{name}_hubmeta.json",
        result_dir / f"{name}_graphstats.json",
        static_root / "graph/0.graph.gz",
        static_root / "bintoindex.json",
        static_root / "indextobin.json",
        static_root / "indextores.json",
    ]
    missing = [str(path.relative_to(root)) for path in required if not path.is_file()]
    assert not missing, f"missing required outputs: {missing}"

    revision = (root / "package-revision.txt").read_text(encoding="utf-8").strip()
    assert revision == PACKAGE_REVISION, f"unexpected PKGBUILD revision: {revision}"
    assert (root / "package/zydis/wrapped-executions.tsv").stat().st_size > 0
    test_log = (root / "package/zydis/test.log").read_text(
        encoding="utf-8", errors="replace"
    )
    assert "100% tests passed" in test_log, "the native Zydis test did not pass"

    text_before = sha256(root / "proof/text-before.bin")
    text_after = sha256(root / "proof/text-after.bin")
    assert text_before == text_after, ".text changed while stripping"

    dynamic_icall = load_mapping(root / f"dynamic/{name}_icall.json")
    dynamic_ijump = load_mapping(root / f"dynamic/{name}_ijump.json")
    static_icall = load_mapping(result_dir / f"{name}_icallbbtocallee.json")
    static_jump = load_mapping(result_dir / f"{name}_correctjumptable.json")
    static_tail = load_mapping(result_dir / f"{name}_itcbbtofunc.json")
    static_return = load_mapping(result_dir / f"{name}_ret.json")

    dynamic_instruction_pairs = pairs(dynamic_icall) | pairs(dynamic_ijump)
    static_pairs = (
        pairs(static_icall)
        | pairs(static_jump)
        | pairs(static_tail)
        | pairs(static_return)
    )
    assert dynamic_instruction_pairs, "dynamic ICF ground truth is empty"
    assert static_pairs, "static ICF ground truth is empty"
    assert pairs(static_jump), "static jump-table ground truth is empty"
    assert pairs(static_return), "static return ground truth is empty"

    project = angr.Project(str(root / f"stripped/{name}"), auto_load_libs=False)
    cfg = project.analyses.CFGFast(normalize=True, data_references=True)
    normalized_dynamic: dict[str, list[str]] = {}
    for source, targets in {**dynamic_icall, **dynamic_ijump}.items():
        node = cfg.model.get_any_node(int(source, 16), anyaddr=True)
        assert node is not None, f"dynamic source is absent from the ACFG: {source}"
        normalized_dynamic.setdefault(hex(node.addr), []).extend(targets)

    normalized_dynamic_pairs = pairs(normalized_dynamic)
    uncovered = normalized_dynamic_pairs - static_pairs
    assert not uncovered, f"dynamic pairs absent from static GT: {sorted(uncovered)}"

    node_lookup = {
        key.lower(): value
        for key, value in load_json(result_dir / f"{name}_nodelookup.json").items()
    }
    for source, target in normalized_dynamic_pairs:
        assert source in node_lookup, f"GT source is absent from graph nodes: {source}"
        assert target in node_lookup, f"GT target is absent from graph nodes: {target}"

    graph_gz = static_root / "graph/0.graph.gz"
    with tempfile.TemporaryDirectory(prefix="icflownet-e1-") as temporary:
        graph_path = Path(temporary) / "0.graph"
        with gzip.open(graph_gz, "rb") as source, graph_path.open("wb") as destination:
            shutil.copyfileobj(source, destination)
        graph = dgl.load_graphs(str(graph_path))[0][0]

    assert {"code", "data"}.issubset(graph.ntypes), graph.ntypes
    node_counts = {node_type: int(graph.num_nodes(node_type)) for node_type in graph.ntypes}
    assert node_counts["code"] > 0, "graph has no code nodes"
    assert node_counts["data"] > 0, "graph has no data nodes"

    edge_counts = {
        f"{source}:{relation}:{target}": int(graph.num_edges((source, relation, target)))
        for source, relation, target in graph.canonical_etypes
    }
    relations = {relation for _, relation, _ in graph.canonical_etypes}
    required_relations = {"code2code_edges", "codecall_edges", "codejump_edges"}
    assert required_relations.issubset(relations), relations
    code_to_data = sum(
        count
        for canonical, count in edge_counts.items()
        if canonical.startswith("code:") and canonical.endswith(":data")
    )
    assert code_to_data > 0, "graph has no code-to-data cross-reference edges"

    graph_stats = load_json(result_dir / f"{name}_graphstats.json")
    assert graph_stats["code_nodes"] == node_counts["code"]
    assert graph_stats["data_nodes"] == node_counts["data"]

    return {
        "status": "PASS",
        "sample": "zydis",
        "binary": name,
        "package_revision": revision,
        "text_sha256": text_before,
        "dynamic": {
            "instruction_sites": len(dynamic_icall) + len(dynamic_ijump),
            "instruction_pairs": len(dynamic_instruction_pairs),
            "normalized_pairs": len(normalized_dynamic_pairs),
            "icall_pairs": len(pairs(dynamic_icall)),
            "ijump_pairs": len(pairs(dynamic_ijump)),
        },
        "static": {
            "total_pairs": len(static_pairs),
            "icall_pairs": len(pairs(static_icall)),
            "jump_table_pairs": len(pairs(static_jump)),
            "tail_call_pairs": len(pairs(static_tail)),
            "return_pairs": len(pairs(static_return)),
        },
        "dynamic_pairs_covered_by_static_gt": len(normalized_dynamic_pairs),
        "graph": {
            "compressed_sha256": sha256(graph_gz),
            "node_counts": node_counts,
            "edge_counts": edge_counts,
            "total_edges": int(sum(edge_counts.values())),
            "code_to_data_edges": code_to_data,
        },
    }


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {Path(sys.argv[0]).name} OUTPUT_DIRECTORY", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    report_path = root / "verification.json"
    try:
        report = verify(root)
    except Exception as error:
        report = {
            "status": "FAIL",
            "error": str(error),
            "traceback": traceback.format_exc(),
        }
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2), file=sys.stderr)
        return 1

    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
