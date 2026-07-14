"""Regression for cross-cluster waiting-queue head-of-line blocking."""

import os
import sys

_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, _ROOT)

from model.bingo_sim import BingoSimulator, SimConfig
from model.bingo_sim_chiplet import TaskDescriptor


def _task(
    task_id,
    cluster,
    core,
    *,
    dep_check_en=False,
    dep_check_code=0,
    dep_set_en=False,
    dep_set_cluster=0,
    dep_set_code=0,
    work_delay=5,
):
    return TaskDescriptor(
        task_type=0,
        task_id=task_id,
        assigned_chiplet_id=0,
        assigned_cluster_id=cluster,
        assigned_core_id=core,
        dep_check_en=dep_check_en,
        dep_check_code=dep_check_code,
        dep_set_en=dep_set_en,
        dep_set_all_chiplet=False,
        dep_set_chiplet_id=0,
        dep_set_cluster_id=dep_set_cluster,
        dep_set_code=dep_set_code,
        work_delay=work_delay,
    )


def test_blocked_cluster_does_not_block_same_core_on_another_cluster():
    config = SimConfig(
        num_chiplets=1,
        num_clusters_per_chiplet=2,
        num_cores_per_cluster=2,
        push_interval=0,
        work_delay_range=(5, 5),
        random_seed=0,
    )
    sim = BingoSimulator(config)

    blocked_c0 = _task(
        1,
        cluster=0,
        core=0,
        dep_check_en=True,
        dep_check_code=0b10,
    )
    independent_c1 = _task(2, cluster=1, core=0, work_delay=5)
    producer_c0 = _task(
        3,
        cluster=0,
        core=1,
        dep_set_en=True,
        dep_set_cluster=0,
        dep_set_code=0b01,
        work_delay=30,
    )

    # The independent task is deliberately queued behind the blocked task and
    # uses the same core number on another cluster.  Per-core waiting queues
    # serialize them; per-(core, cluster) queues let task 2 proceed immediately.
    sim.load_tasks({0: [blocked_c0, independent_c1, producer_c0]})
    result = sim.run()

    assert not result.deadlock_detected
    done_time = {
        event.task_id: event.time
        for event in result.trace.events
        if event.event_type == "TASK_DONE"
    }
    assert result.completed_task_ids == {1, 2, 3}
    assert done_time[2] < done_time[3]

