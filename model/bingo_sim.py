"""
Bingo HW Manager Cycle-Accurate Simulator.

Tick-based model: each call to tick() advances all chiplets by one clock cycle.
This eliminates the batch-processing artifacts of the event-driven model.

Config options:
  done_queue_mode: "single" (RTL default) or "per_core" (proposed fix)
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Optional, Literal

from .bingo_sim_chiplet import ChipletModel, TaskDescriptor, DoneInfo
from .bingo_sim_trace import EventTrace, SimEvent


@dataclass
class QueueDepths:
    waiting: int = 8
    ready: int = 8
    checkout: int = 8
    done: int = 32


@dataclass
class SimConfig:
    num_chiplets: int = 1
    num_clusters_per_chiplet: int = 2
    num_cores_per_cluster: int = 3
    queue_depths: QueueDepths = field(default_factory=QueueDepths)
    work_delay_range: tuple[int, int] = (20, 50)
    h2h_latency: int = 10
    push_interval: int = 5  # cycles between task pushes per chiplet
    random_seed: int = 0
    done_queue_mode: Literal["single", "per_core"] = "single"


@dataclass
class DeadlockInfo:
    stuck_tasks: list[int]
    chiplet_states: dict[int, str]


@dataclass
class SimResult:
    trace: EventTrace
    total_latency: int
    per_core_utilization: dict[tuple[int, int, int], float]
    deadlock_detected: bool
    deadlock_info: Optional[DeadlockInfo] = None
    completed_task_ids: set[int] = field(default_factory=set)


class BingoSimulator:

    def __init__(self, config: SimConfig):
        self.config = config
        self.rng = random.Random(config.random_seed)
        self.trace = EventTrace()

        self.chiplets: dict[int, ChipletModel] = {}
        for chip_id in range(config.num_chiplets):
            self.chiplets[chip_id] = ChipletModel(
                chiplet_id=chip_id,
                num_clusters=config.num_clusters_per_chiplet,
                num_cores=config.num_cores_per_cluster,
                rng=self.rng,
                work_delay_range=config.work_delay_range,
                waiting_queue_depth=config.queue_depths.waiting,
                ready_queue_depth=config.queue_depths.ready,
                checkout_queue_depth=config.queue_depths.checkout,
                done_queue_depth=config.queue_depths.done,
                done_queue_mode=config.done_queue_mode,
            )

        # Per-chiplet task lists to push
        self._task_lists: dict[int, list[TaskDescriptor]] = {}
        self._push_idx: dict[int, int] = {}
        self._push_timer: dict[int, int] = {}
        self._all_task_ids: set[int] = set()
        self._completed_tasks: set[int] = set()

        # In-flight H2H messages:
        #   (arrival_cycle, target_chiplet, source_core, target_cluster, dep_set_code, dep_set_tag)
        self._h2h_inflight: list[tuple[int, int, int, int, int, Optional[int]]] = []

    def cerf_write_mask(self, chiplet_id: int, mask: int):
        """Write the full CERF bitmask for a specific chiplet."""
        self.chiplets[chiplet_id].cerf_write_mask(mask)

    def cerf_update(self, chiplet_id: int, controlled_mask: int, write_mask: int):
        """Read-modify-write CERF for a specific chiplet."""
        self.chiplets[chiplet_id].cerf_update(controlled_mask, write_mask)

    def load_tasks(self, per_chiplet_tasks: dict[int, list[TaskDescriptor]]):
        for chip_id, tasks in per_chiplet_tasks.items():
            self._task_lists[chip_id] = list(tasks)
            self._push_idx[chip_id] = 0
            self._push_timer[chip_id] = 0
            for t in tasks:
                # Normal (0) and gating (2) tasks need to complete.
                # Dummy (1) tasks don't go through dispatch/done.
                # Conditional tasks (cond_exec_en=1) may be skipped at runtime.
                if t.task_type in (0, 2):
                    self._all_task_ids.add(t.task_id)

    def run(self, max_cycles: int = 200000) -> SimResult:
        last_progress_cycle = 0
        last_completed_count = 0
        deadlock_threshold = 5000  # cycles without progress

        for cycle in range(max_cycles):
            # 1. Push tasks into chiplet task queues (one per chiplet per push_interval)
            self._push_tasks(cycle)

            # 2. Deliver arrived H2H messages
            self._deliver_h2h(cycle)

            # 3. Tick all chiplets — one clock cycle each
            pending_cerf_masks = []
            for chip_id, chiplet in self.chiplets.items():
                events = chiplet.tick(cycle)
                for ev in events:
                    self.trace.record(ev)
                    if ev.event_type == "TASK_DONE":
                        self._completed_tasks.add(ev.task_id)
                    elif ev.event_type == "TASK_SKIPPED":
                        # CERF-skipped task counts as "completed" for progress
                        self._completed_tasks.add(ev.task_id)
                    elif ev.event_type == "DEP_SET_CHIPLET_SENT":
                        self._route_h2h(ev, cycle)
                    elif ev.event_type == "CERF_WRITE":
                        pending_cerf_masks.append((
                            ev.extra["cerf_write_mask"],
                            ev.extra["cerf_controlled_mask"],
                        ))

            # 3b. Apply deferred CERF writes (broadcast to all chiplets)
            # Deferred so CERF updates take effect next cycle, matching RTL timing.
            # Read-modify-write: only controlled groups are updated, others preserved.
            for write_mask, controlled_mask in pending_cerf_masks:
                for cid in self.chiplets:
                    self.chiplets[cid].cerf_update(controlled_mask, write_mask)

            # 4. Check completion
            if self._completed_tasks == self._all_task_ids:
                return self._make_result(cycle, deadlock=False)

            # 5. Deadlock detection
            if len(self._completed_tasks) > last_completed_count:
                last_completed_count = len(self._completed_tasks)
                last_progress_cycle = cycle

            if cycle - last_progress_cycle > deadlock_threshold:
                # Verify nothing is in-flight
                all_pushed = all(
                    self._push_idx.get(c, 0) >= len(self._task_lists.get(c, []))
                    for c in self._task_lists
                )
                if all_pushed:
                    return self._make_result(cycle, deadlock=True)

        return self._make_result(max_cycles, deadlock=self._completed_tasks != self._all_task_ids)

    def _push_tasks(self, cycle: int):
        """Push one task per chiplet every push_interval cycles."""
        for chip_id, tasks in self._task_lists.items():
            idx = self._push_idx[chip_id]
            if idx >= len(tasks):
                continue
            timer = self._push_timer[chip_id]
            if timer > 0:
                self._push_timer[chip_id] -= 1
                continue

            chiplet = self.chiplets[chip_id]
            if chiplet.task_queue.full:
                continue  # Backpressure

            task = tasks[idx]
            chiplet.task_queue.push(task)
            self._push_idx[chip_id] = idx + 1
            self._push_timer[chip_id] = self.config.push_interval

            self.trace.record(SimEvent(
                time=cycle,
                event_type="TASK_PUSHED",
                chiplet_id=chip_id,
                cluster_id=task.assigned_cluster_id,
                core_id=task.assigned_core_id,
                task_id=task.task_id,
            ))

    def _route_h2h(self, event: SimEvent, cycle: int):
        """Schedule an H2H dep_set for future delivery."""
        target_chiplet = event.extra["target_chiplet"]
        target_cluster = event.extra["target_cluster"]
        dep_set_code = event.extra["dep_set_code"]
        dep_set_tag = event.extra.get("dep_set_tag")
        source_core = event.extra["source_core"]
        broadcast = event.extra.get("broadcast", False)

        arrival = cycle + self.config.h2h_latency

        if broadcast:
            for cid in self.chiplets:
                if cid != event.chiplet_id:
                    self._h2h_inflight.append((arrival, cid, source_core, target_cluster, dep_set_code, dep_set_tag))
        else:
            self._h2h_inflight.append((arrival, target_chiplet, source_core, target_cluster, dep_set_code, dep_set_tag))

    def _deliver_h2h(self, cycle: int):
        """Deliver H2H messages that have arrived."""
        remaining = []
        for msg in self._h2h_inflight:
            arrival, target_chip, source_core, target_cluster, dep_set_code, dep_set_tag = msg
            if cycle >= arrival:
                self.chiplets[target_chip].receive_chiplet_dep_set(
                    source_core, target_cluster, dep_set_code, dep_set_tag
                )
                self.trace.record(SimEvent(
                    time=cycle,
                    event_type="DEP_SET_CHIPLET_RECV",
                    chiplet_id=target_chip,
                    cluster_id=target_cluster,
                    core_id=source_core,
                    task_id=0,
                ))
            else:
                remaining.append(msg)
        self._h2h_inflight = remaining

    def _make_result(self, cycle: int, deadlock: bool) -> SimResult:
        info = None
        if deadlock:
            info = DeadlockInfo(
                stuck_tasks=sorted(self._all_task_ids - self._completed_tasks),
                chiplet_states={cid: c.dump_state() for cid, c in self.chiplets.items()},
            )
        return SimResult(
            trace=self.trace,
            total_latency=cycle,
            per_core_utilization=self._compute_utilization(cycle),
            deadlock_detected=deadlock,
            deadlock_info=info,
            completed_task_ids=set(self._completed_tasks),
        )

    def _compute_utilization(self, total_cycles: int) -> dict[tuple[int, int, int], float]:
        if total_cycles == 0:
            return {}
        util = {}
        active_start: dict[tuple, int] = {}
        active_total: dict[tuple, int] = {}
        for ev in self.trace.events:
            key = (ev.chiplet_id, ev.cluster_id, ev.core_id)
            if ev.event_type == "TASK_DISPATCHED":
                active_start[key] = ev.time
            elif ev.event_type == "TASK_DONE":
                s = active_start.pop(key, ev.time)
                active_total[key] = active_total.get(key, 0) + (ev.time - s)
        for key, total in active_total.items():
            util[key] = total / total_cycles
        return util
