#!/usr/bin/env python3
"""Run DFG pattern tests through the Python behavioral model.

Modes:
  python3 run_all_tests.py              # structured patterns only
  python3 run_all_tests.py --stress     # structured + 50 random DAGs
  python3 run_all_tests.py --stress 200 # structured + 200 random DAGs
  python3 run_all_tests.py --emit-sv    # also emit SV testbenches
"""

import argparse
import os
import sys
import time as _time

_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_bingo_root = os.path.dirname(_root)
sys.path.insert(0, os.path.join(_root, 'sw'))
sys.path.insert(0, _bingo_root)
sys.path.insert(0, _root)

from codegen.test_dfg_patterns import PATTERN_CATALOG, generate_random_stress_catalog
from codegen.emit_sv_testbench import emit_sv_testbench, emit_sv_top_wrapper
from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor
import networkx as nx


def dfg_to_task_descriptors(dfg, num_cores=3):
    """Convert a compiled BingoDFG to per-chiplet TaskDescriptor lists."""
    per_chiplet = {}

    try:
        ordered_nodes = list(nx.topological_sort(dfg))
    except nx.NetworkXUnfeasible:
        ordered_nodes = dfg.node_list

    for node in ordered_nodes:
        chip = node.assigned_chiplet_id
        if chip not in per_chiplet:
            per_chiplet[chip] = []

        type_map = {"dummy": 1, "gating": 2}
        tt = type_map.get(node.node_type, 0)
        cerf_mask = sum(1 << g for g in node.cerf_write_groups) if node.cerf_write_groups else 0
        cerf_ctrl = cerf_mask  # for run_all_tests, controlled == activated (static tests)

        task = TaskDescriptor(
            task_type=tt,
            task_id=node.node_id,
            assigned_chiplet_id=node.assigned_chiplet_id,
            assigned_cluster_id=node.assigned_cluster_id,
            assigned_core_id=node.assigned_core_id,
            dep_check_en=node.dep_check_enable,
            dep_check_code=_list_to_bitmask(node.dep_check_list),
            dep_set_en=node.dep_set_enable,
            dep_set_all_chiplet=node.remote_dep_set_all,
            dep_set_chiplet_id=node.dep_set_chiplet_id,
            dep_set_cluster_id=node.dep_set_cluster_id,
            dep_set_code=_list_to_bitmask(node.dep_set_list),
            cond_exec_en=node.cond_exec_en,
            cond_exec_group_id=node.cond_exec_group_id,
            cond_exec_invert=node.cond_exec_invert,
            cerf_write_mask=cerf_mask,
            cerf_controlled_mask=cerf_ctrl,
        )
        per_chiplet[chip].append(task)

    return per_chiplet


def _list_to_bitmask(core_list):
    mask = 0
    for core_id in core_list:
        mask |= (1 << core_id)
    return mask


def _count_chiplets(dfg):
    return max(n.assigned_chiplet_id for n in dfg.node_list) + 1


def _count_clusters(dfg):
    return max(n.assigned_cluster_id for n in dfg.node_list) + 1


def _count_cores(dfg):
    return max(n.assigned_core_id for n in dfg.node_list) + 1


def _check_single_bit_dep_check(dfg) -> list[str]:
    """Verify invariant: every dep_check_code has at most 1 bit set."""
    violations = []
    for node in dfg.node_list:
        if node.dep_check_enable:
            code = sum(1 << c for c in node.dep_check_list)
            if bin(code).count('1') > 1:
                violations.append(
                    f"  {node.node_name} (type={node.node_type}): "
                    f"dep_check_list={node.dep_check_list} -> code={bin(code)} "
                    f"({bin(code).count('1')} bits set!)"
                )
    return violations


def run_pattern(name, factory, kwargs, output_dir, emit_sv=False, verbose=True):
    """Run one pattern through compilation + Python model."""
    if verbose:
        print(f"\n{'='*60}")
        print(f"  Pattern: {name}")
        print(f"{'='*60}")

    # Build and compile DFG (identity-aware tagged deps: allocate one per-edge
    # tag per (R,C) cell after dep-info assignment so a consumer drains only its
    # own producer's increment; min-chain-cover reuse keeps it within DepTagWidth).
    dfg = factory(**kwargs)
    dfg.bingo_compile_conditional_regions()
    dfg.bingo_transform_dfg_add_dummy_set_nodes()
    dfg.bingo_transform_dfg_add_dummy_check_nodes()
    dfg.bingo_assign_normal_node_dep_check_info()
    dfg.bingo_assign_normal_node_dep_set_info()
    dfg.bingo_transform_dfg_allocate_dep_tags(tag_width=4)

    num_chiplets = _count_chiplets(dfg)
    num_clusters = _count_clusters(dfg)
    num_cores = _count_cores(dfg)
    total_nodes = len(dfg.node_list)
    normal_count = sum(1 for n in dfg.node_list if n.node_type == "normal")

    if verbose:
        print(f"  Nodes: {total_nodes} ({normal_count} normal + {total_nodes - normal_count} dummy), "
              f"Chiplets: {num_chiplets}, Clusters: {num_clusters}, Cores: {num_cores}")

    # Check single-bit invariant
    violations = _check_single_bit_dep_check(dfg)
    if violations:
        print(f"  INVARIANT VIOLATION: dep_check_code has >1 bit set!")
        for v in violations:
            print(v)
        return False

    # Run Python model
    config = SimConfig(
        num_chiplets=num_chiplets,
        num_clusters_per_chiplet=num_clusters,
        num_cores_per_cluster=num_cores,
        work_delay_range=(20, 50),
        h2h_latency=10,
        random_seed=42,
    )
    sim = BingoSimulator(config)

    # Flux Tier 1: For CERF test patterns, annotate some nodes as conditional
    # and set CERF state before running.
    if name.startswith("cerf_"):
        # Annotate the middle 50% of normal nodes as conditional (group 0)
        normal_nodes = [n for n in dfg.node_list if n.node_type == "normal"]
        mid_start = len(normal_nodes) // 4
        mid_end = mid_start + len(normal_nodes) // 2
        cond_nodes = normal_nodes[mid_start:mid_end]
        dfg.bingo_annotate_conditional_subgraph(cond_nodes, group_id=0)
        # Activate group 0 → conditional tasks EXECUTE (not skipped)
        sim.cerf_write_mask(0, 0x1)  # Activate group 0
        if verbose:
            print(f"  CERF: {len(cond_nodes)} nodes annotated as conditional (group 0, active)")

    per_chiplet = dfg_to_task_descriptors(dfg, num_cores)
    sim.load_tasks(per_chiplet)
    result = sim.run()

    is_deadlock_test = (name == "deadlock")

    if is_deadlock_test:
        if result.deadlock_detected:
            if verbose:
                print(f"  Result: PASS (deadlock correctly detected)")
                print(f"  Stuck tasks: {result.deadlock_info.stuck_tasks}")
        else:
            print(f"  Result: FAIL (deadlock NOT detected, but expected)")
            return False
    else:
        if result.deadlock_detected:
            print(f"  Result: FAIL (unexpected deadlock!)")
            print(f"  Stuck: {result.deadlock_info.stuck_tasks}")
            # Print chiplet states for debugging
            for cid, state in result.deadlock_info.chiplet_states.items():
                for line in state.split('\n'):
                    if any(k in line.lower() for k in ['done', 'row', 'waiting', 'checkout', 'head']):
                        print(f"    {line}")
            return False

        normal_ids = {n.node_id for n in dfg.node_list if n.node_type == "normal"}
        missing = normal_ids - result.completed_task_ids
        if missing:
            print(f"  Result: FAIL (missing: {sorted(missing)})")
            return False

        if verbose:
            print(f"  Result: PASS")
            print(f"  Completed: {len(result.completed_task_ids)} tasks, "
                  f"Latency: {result.total_latency} cycles")

    # Save trace
    trace_path = os.path.join(output_dir, f"{name}_model_trace.csv")
    result.trace.to_csv(trace_path)

    # Emit SV testbench
    if emit_sv and not is_deadlock_test:
        stim_name = f"tb_stimulus_{name}.svh"
        emit_sv_testbench(dfg, output_dir, stim_name, compile_dfg=False, dfg_name=name)
        emit_sv_top_wrapper(dfg, output_dir, name, stim_name)

    return True


def main():
    parser = argparse.ArgumentParser(description="Run DFG pattern tests")
    parser.add_argument("--stress", nargs="?", const=50, type=int, default=0,
                        help="Run N random stress tests (default: 50)")
    parser.add_argument("--emit-sv", action="store_true",
                        help="Also emit SV testbenches")
    args = parser.parse_args()

    output_dir = os.path.join(_root, "test", "generated")
    os.makedirs(output_dir, exist_ok=True)

    # Phase 1: Structured patterns
    print("\n" + "="*60)
    print("  PHASE 1: Structured Patterns")
    print("="*60)

    passed = 0
    failed = 0
    errors = 0

    for name, (factory, kwargs) in PATTERN_CATALOG.items():
        try:
            if run_pattern(name, factory, kwargs, output_dir, emit_sv=args.emit_sv):
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"  Result: ERROR ({e})")
            import traceback; traceback.print_exc()
            errors += 1

    struct_total = passed + failed + errors

    # Phase 2: Random stress tests
    stress_passed = 0
    stress_failed = 0
    stress_errors = 0

    if args.stress > 0:
        print("\n" + "="*60)
        print(f"  PHASE 2: Random Stress Tests ({args.stress} graphs)")
        print("="*60)

        stress_catalog = generate_random_stress_catalog(n_random=args.stress)
        t0 = _time.time()

        for name, (factory, kwargs) in stress_catalog.items():
            try:
                ok = run_pattern(name, factory, kwargs, output_dir,
                                 emit_sv=False, verbose=False)
                if ok:
                    stress_passed += 1
                else:
                    stress_failed += 1
                    # Re-run with verbose on failure
                    run_pattern(name, factory, kwargs, output_dir,
                                emit_sv=False, verbose=True)
            except Exception as e:
                print(f"\n  {name}: ERROR ({e})")
                stress_errors += 1

        elapsed = _time.time() - t0
        stress_total = stress_passed + stress_failed + stress_errors
        print(f"\n  Stress: {stress_passed}/{stress_total} passed, "
              f"{stress_failed} failed, {stress_errors} errors "
              f"({elapsed:.1f}s)")

    # Summary
    total_passed = passed + stress_passed
    total_failed = failed + stress_failed
    total_errors = errors + stress_errors
    total = total_passed + total_failed + total_errors

    print(f"\n{'='*60}")
    print(f"  FINAL SUMMARY")
    print(f"  Structured: {passed}/{struct_total} passed")
    if args.stress > 0:
        print(f"  Stress:     {stress_passed}/{stress_passed + stress_failed + stress_errors} passed")
    print(f"  Total:      {total_passed}/{total} passed, "
          f"{total_failed} failed, {total_errors} errors")
    print(f"{'='*60}")

    return 0 if (total_failed + total_errors) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
