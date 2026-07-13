"""Dependency-sync gate: dispatch-before-producer hazards under identity-aware tags.

Builds a synthetic multi-cluster stress DFG that used to reproduce the
counter-sharing hazard of the removed identity-blind matrix, runs the full
mini-compiler pipeline (including the per-edge tag allocator), then drives the
behavioral model over several seeded timings and reports every task that
DISPATCHES before a true DFG predecessor has COMPLETED. Violations are split
into CROSS-cluster (the unqualified-column hazard) and SAME-cluster
(within-cluster shared-cell aliasing). The tagged pipeline must be clean
(0 violations, no deadlock).

Runs as a pytest (the test_* function below) and also standalone as a CLI:
    python3 model/tests/test_dep_sync.py [--seeds N] [--clusters M] [--tag-width W]
"""
import argparse
import os
import sys

import networkx as nx

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.abspath(os.path.join(_HERE, "..", ".."))
sys.path.insert(0, _ROOT)                     # model.*
sys.path.insert(0, os.path.join(_ROOT, "sw")) # bingo_dfg / bingo_node

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor

GEMM, DMA, HOST = 0, 1, 2          # core ids (row/col of the dep matrix)


def build_stress_dfg(n_clusters=2):
    """A synthetic multi-cluster stress DFG that maximizes dep-matrix cell
    sharing. In each cluster: an entry root on the producer core gates a late
    producer pA AND feeds a queue-late consumer cLate through the SAME
    cell[CONS][PROD] -- the pinned-early stray. Across clusters: cluster k's
    producer also strays onto cluster 0's busy column (cross-cluster aliasing)."""
    d = BingoDFG()
    CONS, PROD = GEMM, DMA         # consumers on GEMM core, producers on DMA core
    per_cluster = {}

    def N(cl, core, name):
        n = BingoNode(0, cl, core, name)
        d.bingo_add_node(n)
        return n

    for cl in range(n_clusters):
        # entry sits on the PRODUCER core so its stray set lands on the SAME
        # cell[CONS][PROD] that cA waits on (that aliasing is the whole hazard).
        E  = N(cl, PROD, f"entry_c{cl}")
        A0 = N(cl, PROD, f"A0_c{cl}"); B0 = N(cl, PROD, f"B0_c{cl}")
        pA = N(cl, PROD, f"pA_late_c{cl}")
        cA = N(cl, CONS, f"cA_early_c{cl}"); cL = N(cl, CONS, f"cLate_c{cl}")
        d.bingo_add_edge(E, A0); d.bingo_add_edge(A0, pA)      # path 1 entry->pA
        d.bingo_add_edge(E, B0); d.bingo_add_edge(B0, pA)      # path 2 entry->pA
        d.bingo_add_edge(pA, cA)                               # cA waits on its real producer
        d.bingo_add_edge(E, cL)                                # entry stray into cell[CONS][PROD]
        d.bingo_add_edge(cA, cL)                               # queue order cA before cLate
        per_cluster[cl] = (E, pA, cA, cL)

    # Cross-cluster aliasing: each later cluster's producer also feeds cluster 0's
    # late consumer on cluster 0's column -> two clusters' producers collapse onto
    # cluster 0 cell[CONS][PROD].
    for cl in range(1, n_clusters):
        src_pA = per_cluster[cl][1]
        dst_cL = per_cluster[0][3]
        d.bingo_add_edge(src_pA, dst_cL)
    return d


def compile_dfg(d, tag_width):
    """Run the full mini-compiler pipeline, ending with the per-edge tag
    allocator."""
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=tag_width)


def _mask(cores):
    m = 0
    for c in cores:
        m |= (1 << c)
    return m


def _to_descriptors(d):
    try:
        ordered = list(nx.topological_sort(d))
    except nx.NetworkXUnfeasible:
        ordered = d.node_list
    per = {}
    for n in ordered:
        per.setdefault(n.assigned_chiplet_id, []).append(TaskDescriptor(
            task_type={"dummy": 1, "gating": 2}.get(n.node_type, 0),
            task_id=n.node_id, assigned_chiplet_id=n.assigned_chiplet_id,
            assigned_cluster_id=n.assigned_cluster_id, assigned_core_id=n.assigned_core_id,
            dep_check_en=n.dep_check_enable, dep_check_code=_mask(n.dep_check_list),
            dep_set_en=n.dep_set_enable, dep_set_all_chiplet=n.remote_dep_set_all,
            dep_set_chiplet_id=n.dep_set_chiplet_id, dep_set_cluster_id=n.dep_set_cluster_id,
            dep_set_code=_mask(n.dep_set_list),
            dep_check_tag=n.dep_check_tag, dep_set_tag=n.dep_set_tag))
    return per


def analyze(n_clusters, tag_width=3, seeds=20, work_delay_range=(20, 50)):
    """Compile the stress DFG and return the union of dispatch-before-producer
    violations over `seeds` seeded timings, split into
    (cross_cluster, same_cluster, deadlock_count, name_map)."""
    d = build_stress_dfg(n_clusters)
    orig_edges = [(u.node_id, v.node_id) for u, v in d.edges()]  # before dummy nodes
    loc = {n.node_id: (n.assigned_chiplet_id, n.assigned_cluster_id, n.assigned_core_id)
           for n in d.node_list}
    name = {n.node_id: n.node_name for n in d.node_list}
    compile_dfg(d, tag_width=tag_width)
    per = _to_descriptors(d)

    cross, same, deadlocks = {}, {}, 0
    for seed in range(1, seeds + 1):
        sim = BingoSimulator(SimConfig(num_chiplets=1, num_clusters_per_chiplet=n_clusters,
                                       num_cores_per_cluster=3, work_delay_range=work_delay_range,
                                       random_seed=seed))
        sim.load_tasks(per)
        res = sim.run(max_cycles=200000)
        if res.deadlock_detected:
            deadlocks += 1
        disp, done = {}, {}
        for e in res.trace.events:
            if e.event_type == "TASK_DISPATCHED" and e.task_id not in disp:
                disp[e.task_id] = e.time
            if e.event_type == "TASK_DONE":
                done[e.task_id] = e.time
        for u, v in orig_edges:
            if u in done and v in disp and disp[v] < done[u]:
                (cross if loc[u][1] != loc[v][1] else same).setdefault((u, v), (done[u], disp[v]))
    return cross, same, deadlocks, name


# ---------------------------------------------------------------------------
# Pytest
# ---------------------------------------------------------------------------
def test_tagged_pipeline_is_clean():
    """The identity-aware pipeline (per-edge tags) must drive ALL
    dispatch-before-producer violations to zero and never deadlock."""
    for n_clusters in (1, 2, 3):
        cross, same, deadlocks, _name = analyze(n_clusters=n_clusters, seeds=20)
        assert len(cross) == 0, f"{n_clusters} clusters: cross-cluster violations {cross}"
        assert len(same) == 0, f"{n_clusters} clusters: same-cluster violations {same}"
        assert deadlocks == 0, f"{n_clusters} clusters: {deadlocks} deadlocks"


# ---------------------------------------------------------------------------
# Standalone CLI
# ---------------------------------------------------------------------------
def _report(label, cross, same, deadlocks, name):
    print(f"\n=== {label} ===")
    print(f"  cross-cluster dispatch-before-producer violations = {len(cross)}")
    for (u, v), (du, dv) in sorted(cross.items(), key=lambda kv: kv[1][1]):
        print(f"    {name[v]} dispatched t={dv} BEFORE {name[u]} done t={du}")
    print(f"  same-cluster  dispatch-before-producer violations = {len(same)}")
    for (u, v), (du, dv) in sorted(same.items(), key=lambda kv: kv[1][1]):
        print(f"    {name[v]} dispatched t={dv} BEFORE {name[u]} done t={du}")
    if deadlocks:
        print(f"  WARNING: {deadlocks} seed(s) deadlocked")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--clusters", type=int, default=2)
    ap.add_argument("--tag-width", type=int, default=3)
    args = ap.parse_args()

    tc, ts, td, tn = analyze(args.clusters, tag_width=args.tag_width, seeds=args.seeds)
    _report(f"TAGGED (tags, W={args.tag_width}) | clusters={args.clusters} seeds={args.seeds}",
            tc, ts, td, tn)
    if len(tc) + len(ts) + td:
        print("\nFAIL: identity-aware pipeline still has hazard(s).")
        sys.exit(1)
    print("\nPASS: identity-aware pipeline is clean (0 cross + 0 same + no deadlock).")


if __name__ == "__main__":
    main()
