"""Integration tests: multi-chiplet DFG scenarios with H2H dependency signaling."""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from model.bingo_sim import BingoSimulator, SimConfig, QueueDepths
from model.bingo_sim_chiplet import TaskDescriptor


def make_task(task_id, chiplet, cluster, core,
              dep_check_en=False, dep_check_code=0,
              dep_set_en=False, dep_set_code=0,
              dep_set_chiplet=0, dep_set_cluster=0,
              task_type=0, dep_set_all=False,
              dep_check_tag=0, dep_set_tag=0):
    return TaskDescriptor(
        task_type=task_type,
        task_id=task_id,
        assigned_chiplet_id=chiplet,
        assigned_cluster_id=cluster,
        assigned_core_id=core,
        dep_check_en=dep_check_en,
        dep_check_code=dep_check_code,
        dep_set_en=dep_set_en,
        dep_set_all_chiplet=dep_set_all,
        dep_set_chiplet_id=dep_set_chiplet,
        dep_set_cluster_id=dep_set_cluster,
        dep_set_code=dep_set_code,
        dep_check_tag=dep_check_tag,
        dep_set_tag=dep_set_tag,
    )


class TestCrossChipletDep:
    """Test dependency signaling across chiplets via dummy set nodes."""

    def test_two_chiplet_chain(self):
        """Chip0/Core0 → (dummy set) → Chip1/Core0."""
        config = SimConfig(
            num_chiplets=2,
            num_clusters_per_chiplet=1,
            num_cores_per_cluster=3,
            work_delay_range=(10, 10),
            h2h_latency=5,
            random_seed=42,
        )
        sim = BingoSimulator(config)

        chip0_tasks = [
            # Task 1 on chip0, core 0 — no deps, sets core 0 locally (noop set)
            make_task(1, 0, 0, 0),
            # Dummy set: chip0/core0 → chip1/cluster0/core0
            make_task(10, 0, 0, 0, task_type=1,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=1, dep_set_cluster=0),
        ]
        chip1_tasks = [
            # Task 2 on chip1, core 0 — checks core 0 (waiting for cross-chiplet signal)
            make_task(2, 1, 0, 0, dep_check_en=True, dep_check_code=0b001),
        ]

        sim.load_tasks({0: chip0_tasks, 1: chip1_tasks})
        result = sim.run()

        assert not result.deadlock_detected
        assert result.completed_task_ids == {1, 2}

        done_order = result.trace.task_completion_order()
        assert done_order.index(1) < done_order.index(2)

    def test_default_27_task_dfg(self):
        """Run the same 27-task DFG that the RTL testbench uses.

        Three dep-matrix cells carry TWO concurrently-live edges each, so the
        second edge on each cell uses tag 1 (mirrors tb_stimulus_default.svh):
          * chip2 (cl0,r0,c1): 10->25 (tag0), 9->11  (tag1)
          * chip3 (cl0,r0,c0): 20->26 (tag0), 22->12 (tag1)
          * chip3 (cl0,r0,c1): 13->27 (tag0), 14->16 (tag1)
        """
        config = SimConfig(
            num_chiplets=4,
            num_clusters_per_chiplet=2,
            num_cores_per_cluster=3,
            work_delay_range=(20, 50),
            h2h_latency=10,
            random_seed=42,
        )
        sim = BingoSimulator(config)

        # Chiplet 0 tasks
        chip0 = [
            make_task(1, 0, 0, 0, dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=0, dep_set_cluster=1),
            make_task(2, 0, 1, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b100,
                      dep_set_chiplet=0, dep_set_cluster=0),
            make_task(3, 0, 0, 2, dep_check_en=True, dep_check_code=0b010),
            make_task(17, 0, 0, 2, task_type=1, dep_set_en=True, dep_set_code=0b100,
                      dep_set_chiplet=1, dep_set_cluster=0),
            make_task(18, 0, 0, 2, task_type=1, dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=2, dep_set_cluster=0),
        ]

        # Chiplet 1 tasks
        chip1 = [
            make_task(4, 1, 0, 2, dep_check_en=True, dep_check_code=0b100,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=1, dep_set_cluster=1),
            make_task(6, 1, 1, 0, dep_check_en=True, dep_check_code=0b100,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=1, dep_set_cluster=0),
            make_task(19, 1, 0, 2, task_type=1, dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=1, dep_set_cluster=0),
            make_task(5, 1, 0, 1, dep_check_en=True, dep_check_code=0b100,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=1, dep_set_cluster=0),
            make_task(7, 1, 0, 0, dep_check_en=True, dep_check_code=0b011),
            make_task(20, 1, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=3, dep_set_cluster=0),
        ]

        # Chiplet 2 tasks
        chip2 = [
            make_task(8, 2, 0, 0, dep_check_en=True, dep_check_code=0b100,
                      dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=2, dep_set_cluster=1),
            make_task(10, 2, 1, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=2, dep_set_cluster=0),
            make_task(21, 2, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=2, dep_set_cluster=0),
            make_task(9, 2, 0, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=2, dep_set_cluster=0, dep_set_tag=1),
            make_task(25, 2, 0, 0, task_type=1, dep_check_en=True, dep_check_code=0b010),
            make_task(11, 2, 0, 0, dep_check_en=True, dep_check_code=0b010,
                      dep_check_tag=1),
            make_task(22, 2, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=3, dep_set_cluster=0, dep_set_tag=1),
        ]

        # Chiplet 3 tasks
        chip3 = [
            make_task(26, 3, 0, 0, task_type=1, dep_check_en=True, dep_check_code=0b001),
            make_task(12, 3, 0, 0, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b100,
                      dep_set_chiplet=3, dep_set_cluster=0, dep_check_tag=1),
            make_task(15, 3, 0, 2, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=3, dep_set_cluster=0),
            make_task(23, 3, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=3, dep_set_cluster=0),
            make_task(24, 3, 0, 0, task_type=1, dep_set_en=True, dep_set_code=0b010,
                      dep_set_chiplet=3, dep_set_cluster=1),
            make_task(13, 3, 0, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=3, dep_set_cluster=0),
            make_task(14, 3, 1, 1, dep_check_en=True, dep_check_code=0b001,
                      dep_set_en=True, dep_set_code=0b001,
                      dep_set_chiplet=3, dep_set_cluster=0, dep_set_tag=1),
            make_task(27, 3, 0, 0, task_type=1, dep_check_en=True, dep_check_code=0b110),
            make_task(16, 3, 0, 0, dep_check_en=True, dep_check_code=0b010,
                      dep_check_tag=1),
        ]

        sim.load_tasks({0: chip0, 1: chip1, 2: chip2, 3: chip3})
        result = sim.run()

        assert not result.deadlock_detected, (
            f"Deadlock! Stuck tasks: {result.deadlock_info.stuck_tasks}\n"
            + "\n".join(result.deadlock_info.chiplet_states.values())
        )

        # All 16 normal tasks should complete (IDs 1-16)
        # Dummy tasks (17-27) don't generate TASK_DONE events in the model
        normal_task_ids = set(range(1, 17))
        assert normal_task_ids.issubset(result.completed_task_ids), (
            f"Missing: {normal_task_ids - result.completed_task_ids}"
        )
