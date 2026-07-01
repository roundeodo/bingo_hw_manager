"""Identity bug: a pinned-early STRAY increment on a shared counter cell lets a
consumer dispatch before its OWN producer is done.

The dependency matrix keeps one saturating counter per (consumer_core,
producer_core) cell. The check passes at counter >= 1 -- it knows the COUNT of
signals from the producer core, not WHICH producer raised them. So a "+1" raised
for one consumer can be drained by an unrelated consumer that shares the cell.

This test reproduces the worked example from COUNTER_SHARING_BUG.md (the DAG
"entry node" stray increment) inside the in-repo model: the entry root `E` both
gates the producer chain that feeds consumer cA AND feeds a queue-late consumer
through the SAME cell[CONS][PROD], so its early "+1" is a stray on cA's cell.

Invariant under test (the correct, identity-aware behavior): a consumer must not
dispatch before every one of its real producers is DONE. The per-edge tags make
cA wait for ITS producer's tag, not the stray's -- so this passes only because of
the identity-aware allocation.
"""
import sys, os
import networkx as nx

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, '..', '..'))
sys.path.insert(0, _ROOT)                       # model.*
sys.path.insert(0, os.path.join(_ROOT, 'sw'))   # bingo_dfg / bingo_node / bingo_utils

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor

CONS, PROD = 0, 1   # consumer core, producer core


def _to_descriptors(dfg):
    def mask(cores):
        m = 0
        for c in cores:
            m |= (1 << c)
        return m
    try:
        ordered = list(nx.topological_sort(dfg))
    except nx.NetworkXUnfeasible:
        ordered = dfg.node_list
    per = {}
    for n in ordered:
        per.setdefault(n.assigned_chiplet_id, []).append(TaskDescriptor(
            task_type={"dummy": 1, "gating": 2}.get(n.node_type, 0),
            task_id=n.node_id, assigned_chiplet_id=n.assigned_chiplet_id,
            assigned_cluster_id=n.assigned_cluster_id, assigned_core_id=n.assigned_core_id,
            dep_check_en=n.dep_check_enable, dep_check_code=mask(n.dep_check_list),
            dep_set_en=n.dep_set_enable, dep_set_all_chiplet=n.remote_dep_set_all,
            dep_set_chiplet_id=n.dep_set_chiplet_id, dep_set_cluster_id=n.dep_set_cluster_id,
            dep_set_code=mask(n.dep_set_list),
            dep_check_tag=n.dep_check_tag, dep_set_tag=n.dep_set_tag))
    return per


def _build():
    """Entry root E (PROD) gates pA (via E->A0->pA / E->B0->pA) AND feeds a
    queue-late consumer cLate (CONS). pA feeds the early consumer cA (CONS). cA and
    cLate share counter[CONS][PROD]; E's early +1 (meant for cLate) would be drained
    by cA before pA is done on the identity-blind matrix. The per-edge tags give
    cA's and cLate's edges distinct tags, so cA waits for pA specifically."""
    d = BingoDFG()
    def N(core, name):
        n = BingoNode(0, 0, core, name); d.bingo_add_node(n); return n
    E = N(PROD, "entry")
    A0 = N(PROD, "A0"); B0 = N(PROD, "B0"); pA = N(PROD, "pA_late")
    cA = N(CONS, "cA_early"); cLate = N(CONS, "cLate")
    d.bingo_add_edge(E, A0); d.bingo_add_edge(A0, pA)   # path 1: E -> pA
    d.bingo_add_edge(E, B0); d.bingo_add_edge(B0, pA)   # path 2: E -> pA (un-cuttable in one edge)
    d.bingo_add_edge(pA, cA)        # cA waits on its real producer pA
    d.bingo_add_edge(E, cLate)      # E's stray +1 targets cell[CONS][PROD] for cLate
    d.bingo_add_edge(cA, cLate)     # consumer-core queue order: cA before cLate
    return d, pA.node_id, cA.node_id


def _dispatch_done_times(trace):
    dispatch, done = {}, {}
    for e in trace.events:
        if e.event_type == "TASK_DISPATCHED":
            dispatch.setdefault(e.task_id, e.time)
        elif e.event_type == "TASK_DONE":
            done.setdefault(e.task_id, e.time)
    return dispatch, done


def _run():
    d, prod_id, cons_id = _build()
    d.bingo_compile_conditional_regions()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    d.bingo_transform_dfg_allocate_dep_tags(tag_width=3)   # the identity-aware fix
    per = _to_descriptors(d)
    for t in per[0]:
        t.work_delay = 10
    sim = BingoSimulator(SimConfig(num_chiplets=1, num_clusters_per_chiplet=1,
                                   num_cores_per_cluster=2, work_delay_range=(10, 10),
                                   random_seed=1))
    sim.load_tasks(per)
    res = sim.run(max_cycles=5000)
    return res, prod_id, cons_id


def test_consumer_waits_for_its_own_producer():
    """cA must not dispatch before pA (its real producer) is DONE.

    FAILS on today's identity-blind model (cA drains E's stray +1 and dispatches
    early); the per-edge tag fix must make it pass.
    """
    res, prod_id, cons_id = _run()
    dispatch, done = _dispatch_done_times(res.trace)
    assert cons_id in dispatch, "cA never dispatched"
    assert prod_id in done, "pA never completed"
    assert dispatch[cons_id] >= done[prod_id], (
        f"cA dispatched at t={dispatch[cons_id]} but its producer pA was not done "
        f"until t={done[prod_id]} -- consumer drained a stray increment "
        f"(identity-blind counter-sharing bug)."
    )
