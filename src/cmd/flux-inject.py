##############################################################
# Copyright 2024 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
##############################################################
#
# flux-inject: inject arbitrary custom resource vertices into a Flux resource
# set (R). Fluxion's resource type is an interned string, so any type name is
# legal and is matched by string equality; this command adds such vertices (and
# arbitrary subtrees of them) to R's JGF scheduling graph so they can be
# scheduled like any built-in resource.
#
# Input may be (a) a raw R from `flux kvs get resource.R` (no scheduling key --
# it is encoded first, same as `flux ion-R encode`), (b) an already-encoded R
# with a .scheduling key, or (c) a bare JGF graph ({"graph": ...}) with
# --scheduling-only. Output is the same shape as the input.
#
# A subtree is described by a recursive spec (JSON):
#
#   {"type": T,                # required: interned resource type string
#    "count": N,               # optional (default 1): how many of this vertex
#    "name": BASENAME,         # optional (default = type): basename for paths
#    "properties": {k: v,...}, # optional: fluxion vertex properties
#    "with": [ <spec>, ... ]}  # optional: child subtrees (arbitrary depth)
#
# Examples:
#   # nest 2 qpus under an IBM vendor vertex at the cluster root
#   flux kvs get resource.R | flux inject --spec \
#     '{"type":"qvendor_ibm","properties":{"ibm":""},
#       "with":[{"type":"qpu","count":2,"properties":{"ibm":""}}]}'
#
#   # add 3 flat custom "widget" vertices at the root (convenience flags)
#   flux inject --input R.json --type widget --count 3
#
#   # attach a qpu under an EXISTING vertex selected by type
#   flux inject --at qvendor_ibm --spec '{"type":"qpu","count":1}'
#
import argparse
import sys
import json
import logging

import flux
from fluxion.resourcegraph.V1 import FluxionResourceGraphV1

LOGGER = logging.getLogger("flux-inject")


def ensure_scheduling(doc, scheduling_only):
    #  Return the JGF graph dict, encoding R first if necessary.
    if scheduling_only:
        return doc["graph"]
    if "scheduling" not in doc:
        doc["scheduling"] = FluxionResourceGraphV1(doc).to_JSON()
    return doc["scheduling"]["graph"]


def find_parent(graph, at):
    #  Resolve the parent vertex to attach under. 'at' may be None (the graph
    #  root: the unique vertex with no incoming containment edge), a containment
    #  path (begins with '/'), or a resource type (first vertex of that type).
    nodes = graph["nodes"]
    if at is not None and at.startswith("/"):
        for n in nodes:
            if n["metadata"]["paths"].get("containment") == at:
                return n
        raise ValueError("no vertex with containment path '{}'".format(at))
    if at is not None:
        for n in nodes:
            if n["metadata"].get("type") == at:
                return n
        raise ValueError("no vertex of type '{}'".format(at))
    targets = {e["target"] for e in graph["edges"]}
    roots = [n for n in nodes if n["id"] not in targets]
    if len(roots) != 1:
        raise ValueError("expected exactly 1 root vertex, found {}".format(len(roots)))
    return roots[0]


def next_id(graph):
    return max(int(n["id"]) for n in graph["nodes"]) + 1


def count_children_of_type(graph, parent_path, vtype):
    #  How many <vtype> vertices already sit directly under parent_path, for
    #  stable sequential naming across repeated injections.
    pfx = parent_path + "/"
    n = 0
    for node in graph["nodes"]:
        m = node["metadata"]
        if m.get("type") != vtype:
            continue
        path = m["paths"].get("containment", "")
        if path.startswith(pfx) and "/" not in path[len(pfx) :]:
            n += 1
    return n


def inject_spec(graph, parent, spec):
    #  Recursively add spec (and its 'with' children) under parent vertex.
    if "type" not in spec:
        raise ValueError("resource spec missing required 'type'")
    vtype = spec["type"]
    count = int(spec.get("count", 1))
    basename = spec.get("name", vtype)
    props = spec.get("properties")
    children = spec.get("with", [])
    parent_id = parent["id"]
    parent_path = parent["metadata"]["paths"]["containment"]

    start = count_children_of_type(graph, parent_path, vtype)
    for i in range(count):
        idx = start + i
        name = "{}{}".format(basename, idx)
        vid = next_id(graph)
        meta = {
            "type": vtype,
            "id": idx,
            "rank": -1,
            "paths": {"containment": "{}/{}".format(parent_path, name)},
        }
        if props:
            meta["properties"] = dict(props)
        newv = {"id": str(vid), "metadata": meta}
        graph["nodes"].append(newv)
        graph["edges"].append({"source": parent_id, "target": str(vid)})
        for child in children:
            inject_spec(graph, newv, child)


def spec_from_flags(args):
    #  Build a single spec from the convenience flags (--type/--count/--property
    #  and one level of --child/--child-property).
    def props(pairs):
        out = {}
        for p in pairs or []:
            k, _, v = p.partition("=")
            out[k] = v
        return out

    spec = {"type": args.type, "count": args.count}
    p = props(args.property)
    if p:
        spec["properties"] = p
    if args.child:
        ctype, _, ccount = args.child.partition(":")
        child = {"type": ctype, "count": int(ccount) if ccount else 1}
        cp = props(args.child_property)
        if cp:
            child["properties"] = cp
        spec["with"] = [child]
    return spec


@flux.util.CLIMain(LOGGER)
def main():
    p = argparse.ArgumentParser(
        prog="flux-inject", formatter_class=flux.util.help_formatter()
    )
    p.add_argument(
        "--spec",
        action="append",
        default=[],
        help="JSON resource subtree to inject (repeatable). See flux-inject(1).",
    )
    p.add_argument(
        "--at",
        help="parent to attach under: a containment path (/cluster0) or a "
        "resource type (first vertex of that type). Default: graph root.",
    )
    #  convenience flags (build one spec) for the common flat/one-level case
    p.add_argument("--type", help="resource type for the convenience form")
    p.add_argument("--count", type=int, default=1, help="count for --type")
    p.add_argument(
        "--property",
        action="append",
        help="KEY or KEY=VALUE property for --type (repeatable)",
    )
    p.add_argument("--child", help="one-level child as TYPE[:COUNT] for --type")
    p.add_argument(
        "--child-property",
        action="append",
        help="KEY or KEY=VALUE property for --child (repeatable)",
    )
    p.add_argument(
        "--scheduling-only",
        action="store_true",
        help="input is a bare JGF graph ({graph:...}), not a full R",
    )
    p.add_argument(
        "--input", dest="ifn", metavar="FILENAME", help="read R from FILENAME"
    )
    p.add_argument(
        "--output", dest="ofn", metavar="FILENAME", help="write R to FILENAME"
    )
    args = p.parse_args()

    specs = [json.loads(s) for s in args.spec]
    if args.type:
        specs.append(spec_from_flags(args))
    if not specs:
        raise ValueError("nothing to inject: give --spec or --type")

    infile = open(args.ifn, "r") if args.ifn else sys.stdin
    outfile = open(args.ofn, "w") if args.ofn else sys.stdout
    try:
        doc = json.loads(infile.read())
        graph = ensure_scheduling(doc, args.scheduling_only)
        parent = find_parent(graph, args.at)
        for spec in specs:
            inject_spec(graph, parent, spec)
        print(json.dumps(doc), file=outfile)
    finally:
        if args.ofn:
            outfile.close()
        if args.ifn:
            infile.close()


if __name__ == "__main__":
    main()
