#!/usr/bin/env python3
"""Verify the one-binary C1 smoke experiment and write verification.json."""

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

import dgl


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


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
    static_root = root / "static"
    sourceinfo = static_root / "sourceinfo/testlink"
    angrinfo = static_root / "angrinfo/testlink"
    result_dir = static_root / "res/testlink"

    required = [
        root / "labeled/testlink",
        root / "dynamic/testlink_icall.json",
        root / "dynamic/testlink_ijump.json",
        root / "stripped/testlink",
        root / "proof/text-before.bin",
        root / "proof/text-after.bin",
        sourceinfo / "testlink_icallinstocallee.json",
        angrinfo / "testlink_callinstobb.json",
        result_dir / "testlink_icallbbtocallee.json",
        result_dir / "testlink_ret.json",
        result_dir / "testlink_correctjumptable.json",
        result_dir / "testlink_itcbbtofunc.json",
        result_dir / "testlink_nodelookup.json",
        result_dir / "testlink_hubmeta.json",
        result_dir / "testlink_graphstats.json",
        static_root / "graph/0.graph.gz",
        static_root / "bintoindex.json",
        static_root / "indextobin.json",
        static_root / "indextores.json",
    ]
    missing = [str(path.relative_to(root)) for path in required if not path.is_file()]
    assert not missing, f"missing required outputs: {missing}"

    text_before = sha256(root / "proof/text-before.bin")
    text_after = sha256(root / "proof/text-after.bin")
    assert text_before == text_after, ".text changed while stripping"

    dynamic = load_json(root / "dynamic/testlink_icall.json")
    raw_static = load_json(sourceinfo / "testlink_icallinstocallee.json")
    call_to_bb = load_json(angrinfo / "testlink_callinstobb.json")
    static = load_json(result_dir / "testlink_icallbbtocallee.json")

    dynamic_pairs = pairs(dynamic)
    raw_static_pairs = pairs(raw_static)
    assert len(dynamic) == 1, f"expected one dynamic call site, got {len(dynamic)}"
    assert len(dynamic_pairs) == 2, f"expected two dynamic pairs, got {len(dynamic_pairs)}"
    assert dynamic_pairs == raw_static_pairs, (
        "instruction-level dynamic and compiler-label static pairs differ"
    )

    normalized_dynamic: dict[str, list[str]] = {}
    for source, targets in dynamic.items():
        assert source in call_to_bb, f"dynamic call site is absent from callinstobb: {source}"
        normalized_dynamic.setdefault(call_to_bb[source], []).extend(targets)

    normalized_pairs = pairs(normalized_dynamic)
    static_pairs = pairs(static)
    assert normalized_pairs == static_pairs, (
        "basic-block-normalized dynamic and final static GT pairs differ"
    )

    node_lookup = {key.lower(): value for key, value in load_json(
        result_dir / "testlink_nodelookup.json"
    ).items()}
    for source, target in static_pairs:
        assert source in node_lookup, f"GT source is absent from nodelookup: {source}"
        assert target in node_lookup, f"GT target is absent from nodelookup: {target}"

    ret_gt = load_json(result_dir / "testlink_ret.json")
    assert ret_gt, "return GT is empty"

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

    graph_stats = load_json(result_dir / "testlink_graphstats.json")
    assert graph_stats["code_nodes"] == node_counts["code"]
    assert graph_stats["data_nodes"] == node_counts["data"]

    return {
        "status": "PASS",
        "sample": "testlink",
        "text_sha256": text_before,
        "dynamic_instruction_pairs": len(dynamic_pairs),
        "static_basic_block_pairs": len(static_pairs),
        "dynamic_instruction_gt": dynamic,
        "normalized_dynamic_gt": normalized_dynamic,
        "static_basic_block_gt": static,
        "return_gt_entries": len(ret_gt),
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
