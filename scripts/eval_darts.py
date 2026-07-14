#!/usr/bin/env python3
"""DARTS Evaluation Suite — generates experimental data for the DATE 2027 paper.

Experiments:
  1. MoE single-chiplet: static vs DARTS (N=8, k={1,2,4}), two HW configs
  2. MoE multi-chiplet: 2 chiplets, balanced vs skewed expert activation
  3. Early exit: 4-stage network, exit at different stages
  4. N/k sweep: N={4,8,16}, k={1,2,4,8} on a constrained 3-core config

Output:
  - CSV files per experiment in <output_dir>/
  - Summary tables printed to stdout

Usage:
  python3 eval_darts.py                    # Full evaluation suite
  python3 eval_darts.py --moe              # MoE experiments only
  python3 eval_darts.py --early-exit       # Early exit only
  python3 eval_darts.py --sweep            # N/k sweep only
  python3 eval_darts.py --output results/  # Custom output directory
"""

import argparse
import contextlib
import csv
import io
import os
import sys
from dataclasses import dataclass

# ─── Path setup ─────────────────────────────────────────────
_script_dir = os.path.dirname(os.path.abspath(__file__))
_root = os.path.dirname(_script_dir)
_bingo_root = os.path.dirname(_root)
sys.path.insert(0, os.path.join(_root, "sw"))
sys.path.insert(0, _bingo_root)
sys.path.insert(0, _root)

from bingo_dfg import BingoDFG
from bingo_node import BingoNode
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor

# ─── Delay Parameters (cycles) ─────────────────────────────
EXPERT_DELAY = 200  # Expert FFN compute
ROUTER_DELAY = 50  # Gating network
AGGREGATOR_DELAY = 100  # Output aggregation
INPUT_DELAY = 50  # Input preprocessing
STAGE_DELAY = 200  # Early exit per-stage compute
CLASSIFIER_DELAY = 50  # Early exit classifier
DRAFT_DELAY = 100  # Speculative decoding: draft model step
VERIFY_DELAY = 500  # Speculative decoding: verify (full model forward)
ACCEPT_DELAY = 50  # Speculative decoding: per-token accept/commit
BLOCK_DELAY = 500  # Mixture of Depths: transformer block (attn+FFN)
MOD_ROUTER_DELAY = 50  # Mixture of Depths: per-layer router
MERGE_DELAY = 50  # Mixture of Depths: residual merge
DEFAULT_DELAY = 100  # Fallback for unnamed tasks


# ════════════════════════════════════════════════════════════
#  Helpers
# ════════════════════════════════════════════════════════════


def _bitmask(core_list):
    mask = 0
    for c in core_list:
        mask |= 1 << c
    return mask


def compile_dfg(dfg):
    """Compile DFG: resolve conditional edges, then 4-step transform."""
    dfg.bingo_compile_conditional_regions()
    with contextlib.redirect_stdout(io.StringIO()):
        dfg.bingo_transform_dfg_add_dummy_set_nodes()
        dfg.bingo_transform_dfg_add_dummy_check_nodes()
        dfg.bingo_assign_normal_node_dep_check_info()
        dfg.bingo_assign_normal_node_dep_set_info()


def dfg_to_task_descriptors(dfg, work_delays=None, active_nodes=None):
    """Convert compiled DFG to per-chiplet TaskDescriptor lists.

    Gating tasks (node_type='gating') get task_type=2 and cerf_write_mask
    encoding which CERF groups to activate on completion.

    Args:
        active_nodes: Set of BingoNode objects that should execute. The
                      compiler resolves these to CERF group IDs via
                      dfg._node_to_cerf_group. If None, all conditional
                      tasks execute (static mode).
    """
    # Resolve active_nodes → active_groups via compiler mapping
    node_to_group = getattr(dfg, "_node_to_cerf_group", {})
    if active_nodes is not None:
        active_groups = {node_to_group[n] for n in active_nodes if n in node_to_group}
    else:
        active_groups = None

    per_chiplet = {}
    work_delays = work_delays or {}
    all_chiplets = sorted(set(n.assigned_chiplet_id for n in dfg.node_list))

    for chip_id in all_chiplets:
        per_chiplet[chip_id] = []
        ordered = dfg._resource_balanced_topological_sort(chip_id)
        for node in ordered:
            type_map = {"dummy": 1, "gating": 2}
            tt = type_map.get(node.node_type, 0)

            # Compute cerf_write_mask and cerf_controlled_mask for gating tasks
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

    return per_chiplet


# ════════════════════════════════════════════════════════════
#  DFG Generators
# ════════════════════════════════════════════════════════════


def make_moe_dfg(n_experts=8, n_chiplets=1, n_clusters=2, n_cores=3):
    """Build a Mixture-of-Experts DFG with CERF annotations.

    Structure: input_prep → router → [expert_0 … expert_{N-1}] → aggregator

    The router is a gating task. Each expert gets its own CERF group.
    When the router completes on a core, the hardware writes the CERF groups
    specified by cerf_write_mask, activating the selected experts.

    Returns (dfg, expert_nodes, work_delays).
    """
    dfg = BingoDFG()

    # Input preprocessing
    inp = BingoNode(0, 0, 0, "input_prep")
    dfg.bingo_add_node(inp)

    # Router — auto-promoted to gating task by conditional edges
    router_co = min(1, n_cores - 1)
    router = BingoNode(0, 0, router_co, "router")
    dfg.bingo_add_node(router)
    dfg.bingo_add_edge(inp, router)

    # Experts — distributed round-robin across chiplets, then (cl, co)
    experts = []
    for i in range(n_experts):
        chip = i % n_chiplets
        rem = i // n_chiplets
        cl = (rem // n_cores) % n_clusters
        co = rem % n_cores
        exp = BingoNode(chip, cl, co, f"expert_{i}")
        dfg.bingo_add_node(exp)
        dfg.bingo_add_edge(router, exp, cond=True)  # conditional edge
        experts.append(exp)

    # Aggregator — unconditional (always waits for all deps)
    agg_co = min(2, n_cores - 1)
    agg = BingoNode(0, 0, agg_co, "aggregator")
    dfg.bingo_add_node(agg)
    for exp in experts:
        dfg.bingo_add_edge(exp, agg)

    # Work delays
    work_delays = {
        "input_prep": INPUT_DELAY,
        "router": ROUTER_DELAY,
        "aggregator": AGGREGATOR_DELAY,
    }
    for exp in experts:
        work_delays[exp.node_name] = EXPERT_DELAY

    return dfg, experts, work_delays


def make_early_exit_dfg(n_stages=4, n_cores=3):
    """Build an early-exit multi-stage DFG with CERF annotations.

    Structure:
      stage_0 → classifier_0 → stage_1 → classifier_1 → … → output

    classifier_i is a gating task that controls [stage_{i+1}, classifier_{i+1}].
    Activating its CERF group means "continue past stage i".
    The output node is unconditional (always executes).

    Returns (dfg, stage_pairs, work_delays).
    """
    dfg = BingoDFG()
    stage_pairs = []  # [(stage_node, classifier_node), …]
    work_delays = {}
    prev = None

    for s in range(n_stages):
        co = s % n_cores
        compute = BingoNode(0, 0, co, f"stage_{s}")
        dfg.bingo_add_node(compute)
        work_delays[compute.node_name] = STAGE_DELAY

        if prev is not None:
            dfg.bingo_add_edge(prev, compute)

        cls_co = (co + 1) % n_cores
        classifier = BingoNode(0, 0, cls_co, f"classifier_{s}")
        dfg.bingo_add_node(classifier)
        dfg.bingo_add_edge(compute, classifier)
        work_delays[classifier.node_name] = CLASSIFIER_DELAY

        stage_pairs.append((compute, classifier))
        prev = classifier

    # Conditional edges: classifier_i gates stage_{i+1} and classifier_{i+1}
    for s in range(n_stages - 1):
        _, gating_cls = stage_pairs[s]
        next_compute, next_cls = stage_pairs[s + 1]
        dfg.bingo_add_edge(gating_cls, next_compute, cond=True)
        dfg.bingo_add_edge(gating_cls, next_cls, cond=True)

    # Output — always executes
    output = BingoNode(0, 0, 0, "output")
    dfg.bingo_add_node(output)
    dfg.bingo_add_edge(prev, output)
    work_delays["output"] = INPUT_DELAY

    return dfg, stage_pairs, work_delays


def make_spec_decode_dfg(n_draft=5, n_cores=3):
    """Build a speculative decoding DFG with CERF annotations.

    Structure:
      draft_0 → draft_1 → … → draft_{K-1} → verify(gating)
                                                  ↓ (cond)
                                    accept_0, accept_1, … accept_{K-1}
                                                  ↓ (uncond)
                                                output

    The verify task is a gating task. Each accept_i has its own CERF group.
    Activating groups 0..j-1 means "accept the first j draft tokens."

    Returns (dfg, accept_nodes, work_delays).
    """
    dfg = BingoDFG()
    work_delays = {}

    # Draft chain: sequential steps on alternating cores
    draft_nodes = []
    prev = None
    for i in range(n_draft):
        co = i % n_cores
        d = BingoNode(0, 0, co, f"draft_{i}")
        dfg.bingo_add_node(d)
        work_delays[d.node_name] = DRAFT_DELAY
        if prev is not None:
            dfg.bingo_add_edge(prev, d)
        draft_nodes.append(d)
        prev = d

    # Verify task (gating) — runs the full model on all K candidates
    verify_co = (n_draft % n_cores)
    verify = BingoNode(0, 0, verify_co, "verify")
    dfg.bingo_add_node(verify)
    dfg.bingo_add_edge(draft_nodes[-1], verify)
    work_delays["verify"] = VERIFY_DELAY

    # Accept nodes — each conditionally executes (commit token to KV cache)
    accept_nodes = []
    for i in range(n_draft):
        co = i % n_cores
        a = BingoNode(0, 0, co, f"accept_{i}")
        dfg.bingo_add_node(a)
        work_delays[a.node_name] = ACCEPT_DELAY
        dfg.bingo_add_edge(verify, a, cond=True)  # conditional on verify
        accept_nodes.append(a)

    # Output — unconditional, waits for all accepts (skipped ones propagate deps)
    output = BingoNode(0, 0, 0, "output")
    dfg.bingo_add_node(output)
    work_delays["output"] = INPUT_DELAY
    for a in accept_nodes:
        dfg.bingo_add_edge(a, output)

    return dfg, accept_nodes, work_delays


def make_mod_dfg(n_layers=12, n_cores=3):
    """Build a Mixture-of-Depths DFG with CERF annotations.

    Structure per layer:
      prev → router_l →(cond)→ block_l →(uncond)→ merge_l → next
                       →(uncond)→ merge_l  (residual path)

    Each router_l is a gating task controlling block_l.  If the router
    decides to skip, block_l is skipped and merge_l just passes the
    residual.  Each layer uses one CERF group (max 32 layers supported).

    Returns (dfg, block_nodes, work_delays).
    """
    dfg = BingoDFG()
    work_delays = {}
    block_nodes = []
    prev = None

    for l in range(n_layers):
        co_router = l % n_cores
        co_block = (l + 1) % n_cores
        co_merge = (l + 2) % n_cores

        router = BingoNode(0, 0, co_router, f"router_{l}")
        block = BingoNode(0, 0, co_block, f"block_{l}")
        merge = BingoNode(0, 0, co_merge, f"merge_{l}")

        dfg.bingo_add_node(router)
        dfg.bingo_add_node(block)
        dfg.bingo_add_node(merge)

        work_delays[router.node_name] = MOD_ROUTER_DELAY
        work_delays[block.node_name] = BLOCK_DELAY
        work_delays[merge.node_name] = MERGE_DELAY

        if prev is not None:
            dfg.bingo_add_edge(prev, router)

        dfg.bingo_add_edge(router, block, cond=True)  # conditional path
        dfg.bingo_add_edge(router, merge)               # residual path
        dfg.bingo_add_edge(block, merge)                 # block output

        block_nodes.append(block)
        prev = merge

    return dfg, block_nodes, work_delays


# ════════════════════════════════════════════════════════════
#  Simulation Runner
# ════════════════════════════════════════════════════════════


@dataclass
class EvalResult:
    label: str
    latency: int = 0
    tasks_executed: int = 0
    tasks_skipped: int = 0
    avg_utilization: float = 0.0
    deadlock: bool = False


def run_sim(dfg, config, active_nodes=None, work_delays=None, label=""):
    """Run simulation. Gating tasks write CERF on completion.

    Args:
        active_nodes: Set of BingoNode objects that should execute, or None
                      for static mode (all conditional nodes active).
    """
    per_chiplet = dfg_to_task_descriptors(dfg, work_delays, active_nodes)
    sim = BingoSimulator(config)
    sim.load_tasks(per_chiplet)
    result = sim.run()

    n_done = sum(1 for e in result.trace.events if e.event_type == "TASK_DONE")
    n_skip = sum(1 for e in result.trace.events if e.event_type == "TASK_SKIPPED")

    utils = result.per_core_utilization
    avg_util = sum(utils.values()) / max(len(utils), 1) if utils else 0.0

    return EvalResult(
        label=label,
        latency=result.total_latency,
        tasks_executed=n_done,
        tasks_skipped=n_skip,
        avg_utilization=avg_util,
        deadlock=result.deadlock_detected,
    )


# ════════════════════════════════════════════════════════════
#  Experiment 1 — MoE Single Chiplet
# ════════════════════════════════════════════════════════════


def experiment_moe_single_chiplet(output_dir, verbose=True):
    """Static vs DARTS on a single chiplet with two hardware configs."""
    hw_configs = [
        # (n_clusters, n_cores, label)
        (1, 3, "1cl_3co"),  # Constrained: 3 cores
        (2, 3, "2cl_6co"),  # Rich: 6 cores
    ]
    n_experts = 8
    top_k_values = [1, 2, 4]
    rows = []

    for n_cl, n_co, hw_label in hw_configs:
        sim_config = SimConfig(
            num_chiplets=1,
            num_clusters_per_chiplet=n_cl,
            num_cores_per_cluster=n_co,
            work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
            random_seed=42,
        )

        # ── Static baseline ──
        dfg_s, experts_s, wd_s = make_moe_dfg(n_experts, 1, n_cl, n_co)
        compile_dfg(dfg_s)
        static = run_sim(dfg_s, sim_config, None, wd_s,
                         label=f"static_N{n_experts}_{hw_label}")

        if verbose:
            print(f"\n  [{hw_label}] N={n_experts}, static: "
                  f"latency={static.latency}, util={static.avg_utilization:.1%}, "
                  f"exec={static.tasks_executed}, "
                  f"{'DEADLOCK!' if static.deadlock else 'OK'}")

        rows.append({
            "hw": hw_label, "n_experts": n_experts, "top_k": n_experts,
            "mode": "static", "latency": static.latency,
            "tasks_executed": static.tasks_executed,
            "tasks_skipped": static.tasks_skipped,
            "utilization": f"{static.avg_utilization:.4f}",
            "speedup": "1.00", "deadlock": static.deadlock,
        })

        # ── DARTS for each top-k ──
        for k in top_k_values:
            if k >= n_experts:
                continue
            dfg_k, experts_k, wd_k = make_moe_dfg(n_experts, 1, n_cl, n_co)
            compile_dfg(dfg_k)
            active = set(experts_k[:k])  # Activate first k experts
            darts = run_sim(dfg_k, sim_config, active, wd_k,
                            label=f"darts_N{n_experts}_k{k}_{hw_label}")
            speedup = static.latency / max(darts.latency, 1)

            if verbose:
                print(f"  [{hw_label}] N={n_experts}, k={k}: "
                      f"latency={darts.latency}, util={darts.avg_utilization:.1%}, "
                      f"skip={darts.tasks_skipped}, speedup={speedup:.2f}x, "
                      f"{'DEADLOCK!' if darts.deadlock else 'OK'}")

            rows.append({
                "hw": hw_label, "n_experts": n_experts, "top_k": k,
                "mode": "darts", "latency": darts.latency,
                "tasks_executed": darts.tasks_executed,
                "tasks_skipped": darts.tasks_skipped,
                "utilization": f"{darts.avg_utilization:.4f}",
                "speedup": f"{speedup:.2f}", "deadlock": darts.deadlock,
            })

    _save_csv(os.path.join(output_dir, "moe_single_chiplet.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 2 — MoE Multi-Chiplet
# ════════════════════════════════════════════════════════════


def experiment_moe_multi_chiplet(output_dir, verbose=True):
    """Static vs DARTS on 2 chiplets with balanced/skewed activation."""
    n_experts = 8
    n_chiplets = 2
    n_clusters = 1
    n_cores = 3
    rows = []

    sim_config = SimConfig(
        num_chiplets=n_chiplets,
        num_clusters_per_chiplet=n_clusters,
        num_cores_per_cluster=n_cores,
        work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
        h2h_latency=10,
        random_seed=42,
    )

    # Expert placement (round-robin across chiplets):
    # chip 0: experts 0,2,4,6 (cores 0,1,2,0)
    # chip 1: experts 1,3,5,7 (cores 0,1,2,0)
    # Scenarios: (name, expert_indices_to_activate, description)
    scenarios = [
        ("static", None, "all 8 experts active"),
        ("darts_balanced", [0, 1], "experts 0(chip0),1(chip1) — cross-chiplet"),
        ("darts_spread", [0, 3], "experts 0(chip0,co0),3(chip1,co1) — diff cores"),
        ("darts_skewed", [0, 2], "experts 0(chip0,co0),2(chip0,co1) — same chiplet"),
        ("darts_worst", [0, 6], "experts 0(chip0,co0),6(chip0,co0) — same core"),
    ]

    static_latency = None
    for scenario_name, active_idx, desc in scenarios:
        dfg, experts, wd = make_moe_dfg(n_experts, n_chiplets, n_clusters, n_cores)
        compile_dfg(dfg)
        active = None if active_idx is None else set(experts[i] for i in active_idx)
        result = run_sim(dfg, sim_config, active, wd, label=scenario_name)

        if static_latency is None:
            static_latency = result.latency
        speedup = static_latency / max(result.latency, 1)

        if verbose:
            print(f"  {scenario_name}: {desc}")
            print(f"    latency={result.latency}, skip={result.tasks_skipped}, "
                  f"speedup={speedup:.2f}x, util={result.avg_utilization:.1%}, "
                  f"{'DEADLOCK!' if result.deadlock else 'OK'}")

        rows.append({
            "scenario": scenario_name, "description": desc,
            "active_experts": "all" if active_idx is None else ",".join(map(str, active_idx)),
            "latency": result.latency,
            "tasks_executed": result.tasks_executed,
            "tasks_skipped": result.tasks_skipped,
            "utilization": f"{result.avg_utilization:.4f}",
            "speedup": f"{speedup:.2f}", "deadlock": result.deadlock,
        })

    _save_csv(os.path.join(output_dir, "moe_multi_chiplet.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 3 — Early Exit
# ════════════════════════════════════════════════════════════


def experiment_early_exit(output_dir, verbose=True):
    """Speedup vs exit point on a 4-stage early-exit network."""
    n_stages = 4
    n_cores = 3
    rows = []

    sim_config = SimConfig(
        num_chiplets=1,
        num_clusters_per_chiplet=1,
        num_cores_per_cluster=n_cores,
        work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
        random_seed=42,
    )

    # Static: all stages execute (all conditional nodes active)
    dfg_s, pairs_s, wd_s = make_early_exit_dfg(n_stages, n_cores)
    compile_dfg(dfg_s)
    static = run_sim(dfg_s, sim_config, None, wd_s, label="static_exit")

    if verbose:
        print(f"\n  Static (all {n_stages} stages): latency={static.latency}, "
              f"{'DEADLOCK!' if static.deadlock else 'OK'}")

    rows.append({
        "exit_after": "none(static)", "stages_executed": n_stages,
        "latency": static.latency, "tasks_skipped": 0,
        "speedup": "1.00", "deadlock": static.deadlock,
    })

    # DARTS: exit at different stages
    for exit_after in range(n_stages):
        dfg_e, pairs_e, wd_e = make_early_exit_dfg(n_stages, n_cores)
        compile_dfg(dfg_e)

        # Activate conditional nodes for stages 1..exit_after
        if exit_after > 0:
            active = set()
            for s in range(1, exit_after + 1):
                active.add(pairs_e[s][0])  # stage compute node
                active.add(pairs_e[s][1])  # classifier node
        else:
            active = set()  # No nodes → only stage 0 + classifier 0 run

        result = run_sim(dfg_e, sim_config, active, wd_e,
                         label=f"exit_after_{exit_after}")
        speedup = static.latency / max(result.latency, 1)
        stages_run = exit_after + 1

        if verbose:
            print(f"  Exit after stage {exit_after} ({stages_run}/{n_stages} stages): "
                  f"latency={result.latency}, skip={result.tasks_skipped}, "
                  f"speedup={speedup:.2f}x, "
                  f"{'DEADLOCK!' if result.deadlock else 'OK'}")

        rows.append({
            "exit_after": exit_after, "stages_executed": stages_run,
            "latency": result.latency, "tasks_skipped": result.tasks_skipped,
            "speedup": f"{speedup:.2f}", "deadlock": result.deadlock,
        })

    _save_csv(os.path.join(output_dir, "early_exit.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 4 — N/k Sweep
# ════════════════════════════════════════════════════════════


def experiment_nk_sweep(output_dir, verbose=True):
    """Comprehensive N/k sweep on a constrained 3-core config."""
    n_values = [4, 8, 16]
    k_values = [1, 2, 4, 8]
    n_clusters = 1
    n_cores = 3
    rows = []

    sim_config = SimConfig(
        num_chiplets=1,
        num_clusters_per_chiplet=n_clusters,
        num_cores_per_cluster=n_cores,
        work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
        random_seed=42,
    )

    for N in n_values:
        # Static baseline for this N
        dfg_s, experts_s, wd_s = make_moe_dfg(N, 1, n_clusters, n_cores)
        compile_dfg(dfg_s)
        static = run_sim(dfg_s, sim_config, None, wd_s,
                         label=f"static_N{N}")

        for k in k_values:
            if k > N:
                continue
            if k == N:
                lat = static.latency
                skip = 0
                speedup = 1.0
            else:
                dfg_k, experts_k, wd_k = make_moe_dfg(N, 1, n_clusters, n_cores)
                compile_dfg(dfg_k)
                active = set(experts_k[:k])  # Activate first k experts
                result = run_sim(dfg_k, sim_config, active, wd_k,
                                 label=f"darts_N{N}_k{k}")
                lat = result.latency
                skip = result.tasks_skipped
                speedup = static.latency / max(lat, 1)

            if verbose:
                print(f"  N={N:2d}, k={k:2d} (N/k={N / k:.1f}): "
                      f"static={static.latency}, darts={lat}, "
                      f"speedup={speedup:.2f}x, skip={skip}")

            rows.append({
                "N": N, "k": k, "N_over_k": f"{N / k:.1f}",
                "static_latency": static.latency, "darts_latency": lat,
                "speedup": f"{speedup:.2f}", "tasks_skipped": skip,
            })

    _save_csv(os.path.join(output_dir, "nk_sweep.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 5 — Speculative Decoding
# ════════════════════════════════════════════════════════════


def experiment_spec_decode(output_dir, verbose=True):
    """Speculative decoding: draft K tokens, verify, accept 0..j."""
    n_cores = 3
    draft_lengths = [3, 5, 7]
    rows = []

    sim_config = SimConfig(
        num_chiplets=1,
        num_clusters_per_chiplet=1,
        num_cores_per_cluster=n_cores,
        work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
        random_seed=42,
    )

    for K in draft_lengths:
        # Static: all accept nodes execute (no rejection)
        dfg_s, accepts_s, wd_s = make_spec_decode_dfg(K, n_cores)
        compile_dfg(dfg_s)
        static = run_sim(dfg_s, sim_config, None, wd_s,
                         label=f"static_K{K}")

        if verbose:
            print(f"\n  K={K} drafts, static (all accept): latency={static.latency}, "
                  f"{'DEADLOCK!' if static.deadlock else 'OK'}")

        rows.append({
            "K": K, "accepted": K, "accept_rate": "1.00",
            "mode": "static", "latency": static.latency,
            "tasks_skipped": 0,
            "speedup": "1.00", "deadlock": static.deadlock,
        })

        # DARTS: accept first j tokens (sweep acceptance count)
        for j in range(K + 1):  # 0 = reject all, K = accept all
            if j == K:
                continue  # same as static
            dfg_k, accepts_k, wd_k = make_spec_decode_dfg(K, n_cores)
            compile_dfg(dfg_k)
            active = set(accepts_k[:j]) if j > 0 else set()
            result = run_sim(dfg_k, sim_config, active, wd_k,
                             label=f"spec_K{K}_j{j}")
            speedup = static.latency / max(result.latency, 1)
            rate = j / K

            if verbose:
                print(f"  K={K}, accept={j} ({rate:.0%}): "
                      f"latency={result.latency}, skip={result.tasks_skipped}, "
                      f"speedup={speedup:.2f}x, "
                      f"{'DEADLOCK!' if result.deadlock else 'OK'}")

            rows.append({
                "K": K, "accepted": j, "accept_rate": f"{rate:.2f}",
                "mode": "darts", "latency": result.latency,
                "tasks_skipped": result.tasks_skipped,
                "speedup": f"{speedup:.2f}", "deadlock": result.deadlock,
            })

    _save_csv(os.path.join(output_dir, "spec_decode.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 6 — Mixture of Depths
# ════════════════════════════════════════════════════════════


def experiment_mod(output_dir, verbose=True):
    """Mixture of Depths: per-layer skip decision on a 12-layer network."""
    n_layers = 12
    n_cores = 3
    rows = []

    sim_config = SimConfig(
        num_chiplets=1,
        num_clusters_per_chiplet=1,
        num_cores_per_cluster=n_cores,
        work_delay_range=(DEFAULT_DELAY, DEFAULT_DELAY),
        random_seed=42,
    )

    # Static: all blocks execute
    dfg_s, blocks_s, wd_s = make_mod_dfg(n_layers, n_cores)
    compile_dfg(dfg_s)
    static = run_sim(dfg_s, sim_config, None, wd_s, label="static_mod")

    if verbose:
        print(f"\n  {n_layers}-layer MoD, static (all blocks): "
              f"latency={static.latency}, "
              f"{'DEADLOCK!' if static.deadlock else 'OK'}")

    rows.append({
        "skip_rate": "0.00", "blocks_active": n_layers,
        "mode": "static", "latency": static.latency,
        "tasks_skipped": 0,
        "speedup": "1.00", "deadlock": static.deadlock,
    })

    # DARTS: skip a fraction of layers
    # Patterns: every-other, first-half-skip, random-like
    skip_patterns = [
        ("25%", [b for i, b in enumerate(blocks_s) if i % 4 != 0]),       # skip 25%
        ("50%_even", [b for i, b in enumerate(blocks_s) if i % 2 == 0]),   # skip even layers
        ("50%_odd", [b for i, b in enumerate(blocks_s) if i % 2 == 1]),    # skip odd layers
        ("75%", [b for i, b in enumerate(blocks_s) if i % 4 == 0]),        # skip 75%
    ]

    for pattern_name, active_blocks in skip_patterns:
        dfg_k, blocks_k, wd_k = make_mod_dfg(n_layers, n_cores)
        compile_dfg(dfg_k)

        # Map pattern from blocks_s indices to blocks_k nodes
        active_indices = {i for i, b in enumerate(blocks_s) if b in active_blocks}
        active = set(blocks_k[i] for i in active_indices)
        n_active = len(active)
        skip_rate = 1.0 - n_active / n_layers

        result = run_sim(dfg_k, sim_config, active, wd_k,
                         label=f"mod_{pattern_name}")
        speedup = static.latency / max(result.latency, 1)

        if verbose:
            print(f"  skip={pattern_name} ({n_active}/{n_layers} active): "
                  f"latency={result.latency}, skip={result.tasks_skipped}, "
                  f"speedup={speedup:.2f}x, "
                  f"{'DEADLOCK!' if result.deadlock else 'OK'}")

        rows.append({
            "skip_rate": f"{skip_rate:.2f}", "blocks_active": n_active,
            "mode": f"darts_{pattern_name}", "latency": result.latency,
            "tasks_skipped": result.tasks_skipped,
            "speedup": f"{speedup:.2f}", "deadlock": result.deadlock,
        })

    _save_csv(os.path.join(output_dir, "mixture_of_depths.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Experiment 7 — Auto-Scheduling vs Round-Robin
# ════════════════════════════════════════════════════════════


def experiment_auto_schedule(output_dir, verbose=True):
    """Compare auto-placement vs round-robin on Mixtral configurations."""
    sys.path.insert(0, os.path.join(_root, "sw"))
    from bingo_frontend import from_mixtral_config, ChipletConfig

    hw = ChipletConfig(n_chiplets=1, n_clusters=2, n_cores=3)
    sim_config = SimConfig(
        num_chiplets=1, num_clusters_per_chiplet=2,
        num_cores_per_cluster=3,
        work_delay_range=(100, 100), random_seed=42,
    )
    rows = []

    for n_layers in [4, 8, 16, 32]:
        for mode in ["round-robin", "auto"]:
            auto = (mode == "auto")
            dfg, meta = from_mixtral_config(
                n_layers=n_layers, n_experts=8, top_k=2,
                hw=hw, auto_place=auto,
            )
            compile_dfg(dfg)

            # DARTS top-2
            active = set()
            for experts in meta.expert_nodes.values():
                active.update(experts[:2])
            darts = run_sim(dfg, sim_config, active, dfg._work_delays,
                            label=f"{mode}_{n_layers}L_darts")

            # Static
            static = run_sim(dfg, sim_config, None, dfg._work_delays,
                             label=f"{mode}_{n_layers}L_static")

            speedup = static.latency / max(darts.latency, 1)

            if verbose:
                d = "DEAD" if (static.deadlock or darts.deadlock) else "OK"
                print(f"  {n_layers:2d}L {mode:12s}  static={static.latency:6d}  "
                      f"darts={darts.latency:6d}  speedup={speedup:.2f}x  "
                      f"skip={darts.tasks_skipped:3d}  {d}")

            rows.append({
                "layers": n_layers, "placement": mode,
                "static_latency": static.latency,
                "darts_latency": darts.latency,
                "speedup": f"{speedup:.2f}",
                "tasks_skipped": darts.tasks_skipped,
                "deadlock": static.deadlock or darts.deadlock,
            })

    _save_csv(os.path.join(output_dir, "auto_schedule.csv"), rows)
    return rows


# ════════════════════════════════════════════════════════════
#  Output
# ════════════════════════════════════════════════════════════


def _save_csv(path, rows):
    if not rows:
        return
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=rows[0].keys())
        w.writeheader()
        w.writerows(rows)
    print(f"  -> Saved: {path}")


def _print_table(title, rows, columns):
    """Print a formatted ASCII table."""
    print(f"\n{'=' * 78}")
    print(f"  {title}")
    print(f"{'=' * 78}")
    if not rows:
        print("  (no data)")
        return
    widths = {}
    for c in columns:
        col_w = len(str(c))
        for r in rows:
            col_w = max(col_w, len(str(r.get(c, ""))))
        widths[c] = col_w

    header = " | ".join(str(c).ljust(widths[c]) for c in columns)
    print(f"  {header}")
    print(f"  {'-+-'.join('-' * widths[c] for c in columns)}")
    for r in rows:
        line = " | ".join(str(r.get(c, "")).ljust(widths[c]) for c in columns)
        print(f"  {line}")


# ════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════


def main():
    parser = argparse.ArgumentParser(description="DARTS Evaluation Suite")
    parser.add_argument("--moe", action="store_true", help="MoE experiments only")
    parser.add_argument("--early-exit", action="store_true", help="Early exit only")
    parser.add_argument("--sweep", action="store_true", help="N/k sweep only")
    parser.add_argument("--spec-decode", action="store_true", help="Speculative decoding only")
    parser.add_argument("--mod", action="store_true", help="Mixture of Depths only")
    parser.add_argument("--auto-sched", action="store_true", help="Auto-scheduling comparison only")
    parser.add_argument("--output", default=None, help="Output directory")
    parser.add_argument("-q", "--quiet", action="store_true")
    args = parser.parse_args()

    run_all = not (args.moe or args.early_exit or args.sweep
                   or args.spec_decode or args.mod or args.auto_sched)
    verbose = not args.quiet
    output_dir = args.output or os.path.join(_root, "eval_results")
    os.makedirs(output_dir, exist_ok=True)

    print("DARTS Evaluation Suite")
    print(f"Output: {output_dir}")
    print(f"Delays: expert={EXPERT_DELAY}, router={ROUTER_DELAY}, "
          f"aggregator={AGGREGATOR_DELAY}, input={INPUT_DELAY}")

    # ── Experiment 1: MoE single chiplet ──
    if run_all or args.moe:
        print(f"\n{'─' * 78}")
        print("  Experiment 1: MoE Single Chiplet  (N=8, static vs DARTS)")
        print(f"{'─' * 78}")
        rows = experiment_moe_single_chiplet(output_dir, verbose)
        _print_table(
            "MoE Single Chiplet Results", rows,
            ["hw", "mode", "top_k", "latency", "speedup",
             "tasks_skipped", "utilization", "deadlock"],
        )

    # ── Experiment 2: MoE multi-chiplet ──
    if run_all or args.moe:
        print(f"\n{'─' * 78}")
        print("  Experiment 2: MoE Multi-Chiplet  (8 experts, 2 chiplets)")
        print(f"{'─' * 78}")
        rows = experiment_moe_multi_chiplet(output_dir, verbose)
        _print_table(
            "MoE Multi-Chiplet Results", rows,
            ["scenario", "active_experts", "latency", "speedup",
             "tasks_skipped", "utilization", "deadlock"],
        )

    # ── Experiment 3: Early exit ──
    if run_all or args.early_exit:
        print(f"\n{'─' * 78}")
        print("  Experiment 3: Early Exit  (4 stages)")
        print(f"{'─' * 78}")
        rows = experiment_early_exit(output_dir, verbose)
        _print_table(
            "Early Exit Results", rows,
            ["exit_after", "stages_executed", "latency", "speedup",
             "tasks_skipped", "deadlock"],
        )

    # ── Experiment 4: N/k sweep ──
    if run_all or args.sweep:
        print(f"\n{'─' * 78}")
        print("  Experiment 4: N/k Sweep  (1 cluster, 3 cores)")
        print(f"{'─' * 78}")
        rows = experiment_nk_sweep(output_dir, verbose)
        _print_table(
            "N/k Sweep Results", rows,
            ["N", "k", "N_over_k", "static_latency", "darts_latency",
             "speedup", "tasks_skipped"],
        )

    # ── Experiment 5: Speculative decoding ──
    if run_all or args.spec_decode:
        print(f"\n{'─' * 78}")
        print("  Experiment 5: Speculative Decoding  (K={3,5,7} drafts)")
        print(f"{'─' * 78}")
        rows = experiment_spec_decode(output_dir, verbose)
        _print_table(
            "Speculative Decoding Results", rows,
            ["K", "accepted", "accept_rate", "mode", "latency",
             "speedup", "tasks_skipped", "deadlock"],
        )

    # ── Experiment 6: Mixture of Depths ──
    if run_all or args.mod:
        print(f"\n{'─' * 78}")
        print("  Experiment 6: Mixture of Depths  (12 layers)")
        print(f"{'─' * 78}")
        rows = experiment_mod(output_dir, verbose)
        _print_table(
            "Mixture of Depths Results", rows,
            ["skip_rate", "blocks_active", "mode", "latency",
             "speedup", "tasks_skipped", "deadlock"],
        )

    # ── Experiment 7: Auto-scheduling ──
    if run_all or args.auto_sched:
        print(f"\n{'─' * 78}")
        print("  Experiment 7: Auto-Scheduling vs Round-Robin  (Mixtral 4-32L)")
        print(f"{'─' * 78}")
        rows = experiment_auto_schedule(output_dir, verbose)
        _print_table(
            "Auto-Scheduling Results", rows,
            ["layers", "placement", "static_latency", "darts_latency",
             "speedup", "tasks_skipped", "deadlock"],
        )

    print(f"\n{'=' * 78}")
    print(f"  Evaluation complete. Results in: {output_dir}/")
    print(f"{'=' * 78}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
