"""Adaptive scheduling with runtime load monitoring feedback loop.

Implements the online scheduling loop:

1. Run a batch with current placement + activation weights.
2. Observe per-expert activation frequency from the trace.
3. Update activation weights (exponential moving average).
4. Re-build and re-schedule the DFG with updated weights.
5. Repeat.

This models the hardware load monitor
(``bingo_hw_manager_load_monitor.sv``) reading per-core pending
counters and the host using that information to refine placement.

Usage::

    loop = AdaptiveSchedulingLoop(model_factory, hw_config, sim_config)
    for batch in batches:
        result = loop.step(active_experts=batch.top_k_experts)
        # result contains latency, utilization, placement quality
    history = loop.history  # full convergence trace
"""

from __future__ import annotations

import contextlib
import io
from dataclasses import dataclass, field
from typing import Callable, Optional

import sys
import os

_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_root, "sw"))
sys.path.insert(0, _root)

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor


def _bitmask(core_list):
    mask = 0
    for c in core_list:
        mask |= 1 << c
    return mask


@dataclass
class BatchResult:
    """Result of one batch execution in the adaptive loop."""
    batch_idx: int
    latency: int
    tasks_executed: int
    tasks_skipped: int
    avg_utilization: float
    deadlock: bool
    activation_weights: dict[str, float]  # expert_name → observed frequency
    placement_changed: bool


@dataclass
class HWConfig:
    n_chiplets: int = 1
    n_clusters: int = 2
    n_cores: int = 3


class AdaptiveSchedulingLoop:
    """Online adaptive scheduling with load monitor feedback.

    The loop maintains per-expert activation weights that are updated
    after each batch based on observed execution traces.  When the
    weights change significantly, the DFG is re-scheduled with updated
    placement.

    This models the hardware feedback path:
        load_monitor counters → host reads CSR → host re-computes placement
        → host pushes new task descriptors with updated core assignments.
    """

    def __init__(
        self,
        model_factory: Callable[..., tuple[BingoDFG, dict, dict[str, int]]],
        hw: HWConfig,
        sim_config: SimConfig,
        ema_alpha: float = 0.3,
        rebalance_threshold: float = 0.1,
    ):
        """
        Args:
            model_factory: Callable(auto_place, activation_weights, hw) →
                (dfg, expert_node_map, work_delays).
                The factory must return a FRESH (uncompiled) DFG each call.
                expert_node_map: {expert_name: BingoNode} for all conditional nodes.
            hw: Hardware configuration.
            sim_config: Simulator configuration.
            ema_alpha: Exponential moving average weight for new observations.
                0.0 = ignore new data, 1.0 = use only latest batch.
            rebalance_threshold: Re-schedule when any expert's weight
                changes by more than this fraction.
        """
        self.model_factory = model_factory
        self.hw = hw
        self.sim_config = sim_config
        self.ema_alpha = ema_alpha
        self.rebalance_threshold = rebalance_threshold

        # Running EMA of per-expert activation weights.
        # Initialised to None → first batch uses uniform weights.
        self._weights: Optional[dict[str, float]] = None
        self._batch_idx = 0
        self.history: list[BatchResult] = []

    def step(
        self,
        active_nodes: set[BingoNode] | None = None,
        active_node_names: set[str] | None = None,
    ) -> BatchResult:
        """Execute one batch and update weights.

        Provide EITHER active_nodes (set of BingoNode references from the
        returned expert_node_map) OR active_node_names (set of node name
        strings).  The loop will set the corresponding CERF groups.
        """
        # -- Build DFG with current weights ---------------------------
        dfg, expert_map, work_delays = self.model_factory(
            activation_weights=self._weights,
            hw=self.hw,
        )

        # -- Compile --------------------------------------------------
        with contextlib.redirect_stdout(io.StringIO()):
            dfg.bingo_compile_conditional_regions()
            # Identity-aware deps: allocate one per-edge tag per (R,C) cell after
            # dep-info assignment (min-chain-cover reuses tags across non-overlapping
            # edges, so it fits DepTagWidth without a separate bounding pass).
            dfg.bingo_transform_dfg_add_dummy_set_nodes()
            dfg.bingo_transform_dfg_add_dummy_check_nodes()
            dfg.bingo_assign_normal_node_dep_check_info()
            dfg.bingo_assign_normal_node_dep_set_info()
            dfg.bingo_transform_dfg_allocate_dep_tags(tag_width=4)

        # -- Resolve active nodes -------------------------------------
        if active_nodes is not None:
            active = active_nodes
        elif active_node_names is not None:
            active = {expert_map[n] for n in active_node_names if n in expert_map}
        else:
            active = None  # static: all experts

        # -- Convert to task descriptors ------------------------------
        node_to_group = getattr(dfg, "_node_to_cerf_group", {})
        if active is not None:
            active_groups = {node_to_group[n] for n in active if n in node_to_group}
        else:
            active_groups = None

        per_chiplet = {}
        all_chiplets = sorted(set(n.assigned_chiplet_id for n in dfg.node_list))
        for chip_id in all_chiplets:
            per_chiplet[chip_id] = []
            ordered = dfg._core_balanced_topological_sort(chip_id)
            for node in ordered:
                type_map = {"dummy": 1, "gating": 2}
                tt = type_map.get(node.node_type, 0)
                controlled = set(node.cerf_write_groups)
                if controlled:
                    activated = controlled if active_groups is None else (controlled & active_groups)
                    cerf_mask = sum(1 << g for g in activated)
                    cerf_ctrl = sum(1 << g for g in controlled)
                else:
                    cerf_mask = 0
                    cerf_ctrl = 0
                task = TaskDescriptor(
                    task_type=tt,
                    task_id=node.node_id,
                    assigned_chiplet_id=node.assigned_chiplet_id,
                    assigned_cluster_id=node.assigned_cluster_id,
                    assigned_core_id=node.assigned_core_id,
                    dep_check_en=node.dep_check_enable,
                    dep_check_code=_bitmask(node.dep_check_list),
                    dep_set_en=node.dep_set_enable,
                    dep_set_all_chiplet=node.remote_dep_set_all,
                    dep_set_chiplet_id=node.dep_set_chiplet_id,
                    dep_set_cluster_id=node.dep_set_cluster_id,
                    dep_set_code=_bitmask(node.dep_set_list),
                    cond_exec_en=node.cond_exec_en,
                    cond_exec_group_id=node.cond_exec_group_id,
                    cond_exec_invert=node.cond_exec_invert,
                    cerf_write_mask=cerf_mask,
                    cerf_controlled_mask=cerf_ctrl,
                )
                if node.node_name in work_delays:
                    task.work_delay = work_delays[node.node_name]
                per_chiplet[chip_id].append(task)

        # -- Simulate -------------------------------------------------
        sim = BingoSimulator(self.sim_config)
        sim.load_tasks(per_chiplet)
        result = sim.run()

        # -- Observe: count per-expert activations --------------------
        # Build task_id → expert_name mapping.
        id_to_expert: dict[int, str] = {}
        for name, node in expert_map.items():
            id_to_expert[node.node_id] = name

        executed: dict[str, int] = {n: 0 for n in expert_map}
        skipped: dict[str, int] = {n: 0 for n in expert_map}
        for ev in result.trace.events:
            name = id_to_expert.get(ev.task_id)
            if name is None:
                continue
            if ev.event_type == "TASK_DONE":
                executed[name] = executed.get(name, 0) + 1
            elif ev.event_type == "TASK_SKIPPED":
                skipped[name] = skipped.get(name, 0) + 1

        # Compute observed activation frequency per expert.
        observed: dict[str, float] = {}
        for name in expert_map:
            total = executed.get(name, 0) + skipped.get(name, 0)
            observed[name] = executed.get(name, 0) / max(total, 1)

        # -- Update weights with EMA ---------------------------------
        placement_changed = False
        if self._weights is None:
            self._weights = dict(observed)
            placement_changed = True
        else:
            alpha = self.ema_alpha
            max_delta = 0.0
            for name in observed:
                old = self._weights.get(name, 0.5)
                new = alpha * observed[name] + (1.0 - alpha) * old
                max_delta = max(max_delta, abs(new - old))
                self._weights[name] = new
            placement_changed = max_delta > self.rebalance_threshold

        # -- Record ---------------------------------------------------
        n_done = sum(1 for e in result.trace.events if e.event_type == "TASK_DONE")
        n_skip = sum(1 for e in result.trace.events if e.event_type == "TASK_SKIPPED")
        utils = result.per_core_utilization
        avg_util = sum(utils.values()) / max(len(utils), 1) if utils else 0.0

        br = BatchResult(
            batch_idx=self._batch_idx,
            latency=result.total_latency,
            tasks_executed=n_done,
            tasks_skipped=n_skip,
            avg_utilization=avg_util,
            deadlock=result.deadlock_detected,
            activation_weights=dict(self._weights),
            placement_changed=placement_changed,
        )
        self.history.append(br)
        self._batch_idx += 1
        return br


# ════════════════════════════════════════════════════════════
#  Convenience: Mixtral model factory for the adaptive loop
# ════════════════════════════════════════════════════════════


def make_mixtral_factory(
    n_layers: int = 4,
    n_experts: int = 8,
    expert_latency: int = 200,
    attention_latency: int = 300,
    gate_latency: int = 50,
    aggregator_latency: int = 100,
):
    """Return a model_factory callable for AdaptiveSchedulingLoop.

    Each call returns a fresh (uncompiled) DFG with auto-placement
    using the provided activation weights.
    """

    def factory(activation_weights=None, hw=None):
        hw = hw or HWConfig()
        dfg = BingoDFG()
        work_delays = {}
        expert_map = {}  # expert_name → BingoNode

        prev = None
        for layer_idx in range(n_layers):
            # Attention
            attn = BingoNode(node_name=f"attn_{layer_idx}")
            dfg.bingo_add_node(attn)
            work_delays[attn.node_name] = attention_latency
            if prev is not None:
                dfg.bingo_add_edge(prev, attn)

            # Router
            router = BingoNode(node_name=f"router_{layer_idx}")
            dfg.bingo_add_node(router)
            dfg.bingo_add_edge(attn, router)
            work_delays[router.node_name] = gate_latency

            # Experts
            experts = []
            for i in range(n_experts):
                exp = BingoNode(node_name=f"expert_{layer_idx}_{i}")
                dfg.bingo_add_node(exp)
                dfg.bingo_add_edge(router, exp, cond=True)
                work_delays[exp.node_name] = expert_latency
                experts.append(exp)
                expert_map[exp.node_name] = exp

            # Aggregator
            agg = BingoNode(node_name=f"agg_{layer_idx}")
            dfg.bingo_add_node(agg)
            for exp in experts:
                dfg.bingo_add_edge(exp, agg)
            work_delays[agg.node_name] = aggregator_latency

            prev = agg

        # Auto-schedule with activation weights
        node_weights = None
        if activation_weights:
            node_weights = {}
            for name, w in activation_weights.items():
                if name in expert_map:
                    node_weights[expert_map[name]] = w

        dfg.bingo_auto_assign(
            n_chiplets=hw.n_chiplets,
            n_clusters=hw.n_clusters,
            n_cores=hw.n_cores,
            work_delays=work_delays,
            activation_weights=node_weights,
        )

        return dfg, expert_map, work_delays

    return factory
