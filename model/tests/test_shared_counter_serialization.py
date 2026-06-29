"""Mini-compiler corner case: two+ consumers on one core sharing a dep-matrix
counter cell.

The dependency matrix keeps one saturating counter per
(consumer_core, producer_core) pair, and a dep_check passes at counter >= 1 (it
knows the COUNT of signals from the producer core, not which producer raised
them). When several normal consumers live on the SAME core and each waits, cross
-core, on the SAME producer core, they all check the SAME counter cell -- and
every producer feeding any of them increments it. A consumer can then drain a
*different* consumer's producer increment and dispatch before its own (later)
input is ready.

`bingo_transform_dfg_serialize_shared_counter_consumers` orders the producers so
each consumer's producers complete before the next consumer's. When a producer is
already sequenced the wrong way by a pre-existing same-core chain, the pass
re-splices around it. This test runs both shapes through the real compiler +
behavioral model and checks the late operand is consumed before its consumer.
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
            dep_set_code=mask(n.dep_set_list)))
    return per


def _build(conflict):
    """consumer_A needs {pA1 early, pA2 LATE}, consumer_B needs {pB1 early}; all
    three producers on one core -> share counter[CONS][PROD]. pA2 is gated behind
    a same-core latency chain. If `conflict`, a pre-existing same-core chain also
    sequences pB1 before that chain (before pA2) -- forcing the re-splice path."""
    d = BingoDFG()
    def N(core, name):
        n = BingoNode(0, 0, core, name); d.bingo_add_node(n); return n
    pA1 = N(PROD, "pA1_early"); pB1 = N(PROD, "pB1_early")
    L1 = N(PROD, "lat1"); L2 = N(PROD, "lat2"); pA2 = N(PROD, "pA2_late")
    cA = N(CONS, "consumer_A"); cB = N(CONS, "consumer_B")
    d.bingo_add_edge(L1, L2); d.bingo_add_edge(L2, pA2)       # latency chain -> pA2 late
    d.bingo_add_edge(pA1, cA); d.bingo_add_edge(pA2, cA)      # A <- pA1, pA2
    d.bingo_add_edge(pB1, cB)                                 # B <- pB1
    d.bingo_add_edge(cA, cB)                                  # consumer-core queue order
    if conflict:
        d.bingo_add_edge(pA1, pB1); d.bingo_add_edge(pB1, L1)  # pre-existing chain: pB1 before pA2
    return d, pA2.node_id, cA.node_id


def _run(conflict, apply_fix):
    d, late_id, consA_id = _build(conflict)
    d.bingo_compile_conditional_regions()
    if apply_fix:
        d.bingo_transform_dfg_serialize_shared_counter_consumers()
    d.bingo_transform_dfg_add_dummy_set_nodes()
    d.bingo_transform_dfg_add_dummy_check_nodes()
    d.bingo_assign_normal_node_dep_check_info()
    d.bingo_assign_normal_node_dep_set_info()
    per = _to_descriptors(d)
    for t in per[0]:
        t.work_delay = 10
    sim = BingoSimulator(SimConfig(num_chiplets=1, num_clusters_per_chiplet=1,
                                   num_cores_per_cluster=2, work_delay_range=(10, 10),
                                   random_seed=1))
    sim.load_tasks(per)
    return sim.run(max_cycles=5000).trace.task_completion_order(), late_id, consA_id


def test_serialized_no_conflict():
    order, late_id, consA_id = _run(conflict=False, apply_fix=True)
    assert order.index(late_id) < order.index(consA_id)


def test_serialized_with_preexisting_chain_resplice():
    """A pre-existing same-core chain sequences pB1 before pA2; the pass must
    re-splice so consumer_A still waits for its late operand."""
    order, late_id, consA_id = _run(conflict=True, apply_fix=True)
    assert order.index(late_id) < order.index(consA_id)


def test_corner_case_present_without_pass():
    order, late_id, consA_id = _run(conflict=False, apply_fix=False)
    assert order.index(consA_id) < order.index(late_id)
