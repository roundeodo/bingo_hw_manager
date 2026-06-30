"""Unit tests for the per-edge dep-tag allocator
(``BingoDFG.bingo_transform_dfg_allocate_dep_tags``).

The allocator is the software half of the identity-aware dependency fix: it
gives every producer->consumer edge a small tag so the hardware scoreboard lets
a consumer drain only ITS producer's increment. These tests check the allocator
in isolation (structural invariants), independent of the cycle-accurate model.
"""
import sys, os
import pytest
import networkx as nx

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, '..', '..'))
sys.path.insert(0, _ROOT)
sys.path.insert(0, os.path.join(_ROOT, 'sw'))

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor

CONS, PROD = 0, 1


def _compile(d, tag_width=3):
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_serialize_shared_counter_consumers()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=tag_width)
    return d


def _dep_edges(d):
    """Return the (set_node, check_node, cell) triples the allocator targets."""
    out = []
    for u, v in d.edges():
        if not (u.dep_set_enable and v.dep_check_enable):
            continue
        C, R = u.assigned_core_id, v.assigned_core_id
        if C not in v.dep_check_list or R not in u.dep_set_list:
            continue
        cell = (v.assigned_chiplet_id, v.assigned_cluster_id, R, C)
        out.append((u, v, cell))
    return out


def _shared_cell_dfg():
    """The pinned-early stray DFG: entry gates pA via two same-core paths and
    also feeds a queue-late consumer through the same cell[0][1]."""
    d = BingoDFG()
    def N(core, name):
        n = BingoNode(0, 0, core, name); d.bingo_add_node(n); return n
    E = N(PROD, "entry"); A0 = N(PROD, "A0"); B0 = N(PROD, "B0"); pA = N(PROD, "pA")
    cA = N(CONS, "cA"); cL = N(CONS, "cLate")
    d.bingo_add_edge(E, A0); d.bingo_add_edge(A0, pA)
    d.bingo_add_edge(E, B0); d.bingo_add_edge(B0, pA)
    d.bingo_add_edge(pA, cA); d.bingo_add_edge(E, cL); d.bingo_add_edge(cA, cL)
    return d


def test_every_edge_is_paired():
    """Each dependency edge gets one tag, stamped identically on producer and
    consumer (so the consumer waits for exactly that producer)."""
    d = _compile(_shared_cell_dfg())
    edges = _dep_edges(d)
    assert edges, "expected dependency edges"
    for su, cv, _ in edges:
        assert su.dep_set_tag is not None
        assert cv.dep_check_tag is not None
        assert su.dep_set_tag == cv.dep_check_tag


def test_shared_cell_edges_get_distinct_tags():
    """Two edges that may be simultaneously live on the same cell must not share
    a tag -- otherwise a consumer could drain the wrong producer's increment."""
    d = _compile(_shared_cell_dfg())
    by_cell = {}
    for su, cv, cell in _dep_edges(d):
        by_cell.setdefault(cell, []).append((su, cv))
    for cell, edges in by_cell.items():
        for i in range(len(edges)):
            for j in range(i + 1, len(edges)):
                (sa, ca), (sb, cb) = edges[i], edges[j]
                if sa.dep_set_tag != sb.dep_set_tag:
                    continue
                # same tag is only allowed if the two edges can never overlap:
                # one consumer happens-before the other producer.
                ordered = nx.has_path(d, ca, sb) or nx.has_path(d, cb, sa)
                assert ordered, (
                    f"cell {cell}: edges share tag {sa.dep_set_tag} but are not "
                    f"happens-before ordered (could alias)")


def test_capacity_backstop_raises():
    """If a cell needs more concurrent tags than 2^tag_width, the allocator must
    fail loudly rather than silently reintroduce the aliasing bug."""
    d = _shared_cell_dfg()
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_serialize_shared_counter_consumers()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    with pytest.raises(ValueError):
        d.bingo_transform_dfg_allocate_dep_tags(tag_width=0)  # only 1 tag available


def _parallel_cell_dfg(k):
    """k independent producer->consumer edges that all map to ONE cell (CONS,PROD)
    -> k pairwise-overlapping live ranges -> needs k distinct tags without spill."""
    d = BingoDFG()
    pairs = []
    def N(core, name):
        n = BingoNode(0, 0, core, name); d.bingo_add_node(n); return n
    for i in range(k):
        p = N(PROD, f"p{i}"); c = N(CONS, f"c{i}")
        d.bingo_add_edge(p, c)
        pairs.append((p.node_id, c.node_id))
    return d, pairs


def _run_pipeline(d, tag_width, spill):
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_serialize_shared_counter_consumers()
    if spill:
        d.bingo_transform_dfg_spill_for_tag_capacity(tag_width=tag_width)
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=tag_width)
    return d


def test_overflow_without_spill_raises():
    """6 independent edges on one cell need 6 tags; at tag_width=2 (4 tags) the
    allocator must refuse rather than alias."""
    d, _ = _parallel_cell_dfg(6)
    with pytest.raises(ValueError):
        _run_pipeline(d, tag_width=2, spill=False)


def test_spill_fits_small_tag_width_and_runs_clean():
    """With auto-spill the same 6-edge cell fits tag_width=2, and the model runs
    to completion with every consumer dispatching only after its producer."""
    d, pairs = _parallel_cell_dfg(6)
    _run_pipeline(d, tag_width=2, spill=True)   # must NOT raise

    # Drive the behavioral model and check no dispatch-before-producer + no deadlock.
    def mask(cores):
        m = 0
        for c in cores:
            m |= (1 << c)
        return m
    per = {}
    for n in nx.topological_sort(d):
        per.setdefault(n.assigned_chiplet_id, []).append(TaskDescriptor(
            task_type={"dummy": 1, "gating": 2}.get(n.node_type, 0),
            task_id=n.node_id, assigned_chiplet_id=n.assigned_chiplet_id,
            assigned_cluster_id=n.assigned_cluster_id, assigned_core_id=n.assigned_core_id,
            dep_check_en=n.dep_check_enable, dep_check_code=mask(n.dep_check_list),
            dep_set_en=n.dep_set_enable, dep_set_all_chiplet=n.remote_dep_set_all,
            dep_set_chiplet_id=n.dep_set_chiplet_id, dep_set_cluster_id=n.dep_set_cluster_id,
            dep_set_code=mask(n.dep_set_list),
            dep_check_tag=n.dep_check_tag, dep_set_tag=n.dep_set_tag))
    sim = BingoSimulator(SimConfig(num_chiplets=1, num_clusters_per_chiplet=1,
                                   num_cores_per_cluster=2, work_delay_range=(5, 25),
                                   random_seed=7))
    sim.load_tasks(per)
    res = sim.run(max_cycles=20000)
    assert not res.deadlock_detected, "spill throttle must not deadlock"
    disp, done = {}, {}
    for e in res.trace.events:
        if e.event_type == "TASK_DISPATCHED":
            disp.setdefault(e.task_id, e.time)
        if e.event_type == "TASK_DONE":
            done.setdefault(e.task_id, e.time)
    for prod_id, cons_id in pairs:
        assert disp[cons_id] >= done[prod_id], (
            f"consumer {cons_id} dispatched at {disp[cons_id]} before producer "
            f"{prod_id} done at {done[prod_id]}")


def test_tag_reuse_on_serial_chain():
    """A long serial chain of cross-core hand-offs reuses one tag: each edge's
    consumer happens-before the next edge's producer, so 1 tag (tag_width=0)
    suffices -- the allocator must not allocate a fresh tag per edge."""
    d = BingoDFG()
    def N(core, name):
        n = BingoNode(0, 0, core, name); d.bingo_add_node(n); return n
    # ping-pong between two cores: p0->c0->p1->c1->p2 ... all on cell (0,1)/(1,0)
    prev = N(PROD, "p0")
    nodes = [prev]
    for i in range(4):
        cons = N(CONS, f"c{i}"); d.bingo_add_edge(prev, cons)
        prod = N(PROD, f"p{i+1}"); d.bingo_add_edge(cons, prod)
        nodes += [cons, prod]; prev = prod
    # tag_width=0 (1 tag) must succeed because edges are fully serialized.
    _compile(d, tag_width=0)
    for su, cv, _ in _dep_edges(d):
        assert su.dep_set_tag == cv.dep_check_tag == 0
