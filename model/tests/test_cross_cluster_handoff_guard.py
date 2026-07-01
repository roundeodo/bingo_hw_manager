"""Compile-time guard: reject cross-cluster core-1 (DMA) hand-offs.

The per-cluster dependency matrix's column is the BARE producer core id (not
cluster-qualified). All DMA/xDMA/convert/store/load ops are HW-bound to core 1, so a
CROSS-cluster producer on core 1 aliases the consumer cluster's own core-1 traffic and
the consumer can dispatch before its real remote producer wrote L3 -> RTL hang. The
guard `bingo_assert_no_cross_cluster_samecore_handoff` fails compilation on any such edge.
"""
import os
import sys

import pytest

_HERE = os.path.dirname(__file__)
_ROOT = os.path.abspath(os.path.join(_HERE, '..', '..'))
sys.path.insert(0, os.path.join(_ROOT, 'sw'))   # bingo_dfg / bingo_node / bingo_utils

from bingo_dfg import BingoDFG, DMA_CORE
from bingo_node import BingoNode

GEMM_CORE = 0


def _dfg(edges):
    """edges: list of ((chip,clu,core,name), (chip,clu,core,name))."""
    d = BingoDFG()
    nodes = {}

    def node(spec):
        if spec not in nodes:
            chip, clu, core, name = spec
            n = BingoNode(chip, clu, core, name)
            d.bingo_add_node(n)
            nodes[spec] = n
        return nodes[spec]

    for u, v in edges:
        d.bingo_add_edge(node(u), node(v))
    return d


def test_cross_cluster_core1_to_core1_raises():
    # producer (cluster 0, core 1) -> consumer (cluster 1, core 1): the aliasing hazard.
    d = _dfg([((0, 0, DMA_CORE, "StoreD"), (0, 1, DMA_CORE, "XdmaD2Rm"))])
    with pytest.raises(ValueError, match="cross-cluster DMA-core"):
        d.bingo_assert_no_cross_cluster_samecore_handoff()


def test_cross_cluster_core1_to_host_core2_raises():
    # core1 producer -> host core2 on another cluster: a core1->host store->dequant is also caught.
    d = _dfg([((0, 0, DMA_CORE, "StoreD"), (0, 1, 2, "Dequant"))])
    with pytest.raises(ValueError, match="cross-cluster DMA-core"):
        d.bingo_assert_no_cross_cluster_samecore_handoff()


def test_same_cluster_core1_chain_ok():
    # same-cluster core1->core1 is safe serial sequencing -> must NOT raise.
    d = _dfg([((0, 0, DMA_CORE, "StoreD"), (0, 0, DMA_CORE, "XdmaD2Rm"))])
    d.bingo_assert_no_cross_cluster_samecore_handoff()


def test_cross_cluster_gemm_core0_producer_ok():
    # cross-cluster edge whose producer is on core 0 (GEMM) is NOT a DMA-core hand-off.
    d = _dfg([((0, 0, GEMM_CORE, "Gemm"), (0, 1, GEMM_CORE, "Gemm2"))])
    d.bingo_assert_no_cross_cluster_samecore_handoff()
