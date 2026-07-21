"""Per-Chiplet Cycle-Accurate Model — mirrors bingo_hw_manager_top.sv.

Every method call to `tick()` represents ONE clock cycle. Within each tick:
  1. Combinational: all signals are evaluated on the registered state
  2. Sequential: registers update at the end of the tick

This eliminates the event-driven batch-processing artifacts.
"""

from __future__ import annotations

import random
from dataclasses import dataclass
from typing import Optional, Literal
from enum import IntEnum

from .bingo_sim_dep_matrix import DepMatrix
from .bingo_sim_queues import FifoQueue
from .bingo_sim_trace import SimEvent


@dataclass
class TaskDescriptor:
    """Unpacked task descriptor matching the RTL struct."""
    task_type: int          # 0=normal, 1=dummy, 2=gating
    task_id: int
    assigned_chiplet_id: int
    assigned_cluster_id: int
    assigned_core_id: int
    dep_check_en: bool
    dep_check_code: int     # bitmask
    dep_set_en: bool
    dep_set_all_chiplet: bool
    dep_set_chiplet_id: int
    dep_set_cluster_id: int
    dep_set_code: int       # bitmask
    # Per-edge identity tags (assigned by the compiler's tag allocator;
    # unset/None is coerced to tag 0 in the dep matrix).
    dep_check_tag: Optional[int] = None
    dep_set_tag: Optional[int] = None
    # Flux Tier 1: Conditional Execution
    cond_exec_en: bool = False
    cond_exec_group_id: int = 0
    cond_exec_invert: bool = False
    # Per-task fixed delay (cycles); None → use config work_delay_range
    work_delay: Optional[int] = None
    # Bitmask: CERF groups to activate on completion (gating tasks only)
    cerf_write_mask: int = 0
    # Bitmask: all CERF groups this gating task controls (for clear-before-set)
    cerf_controlled_mask: int = 0


@dataclass
class DoneInfo:
    task_id: int
    assigned_core_id: int
    assigned_cluster_id: int


class DepCheckState(IntEnum):
    IDLE = 0
    WAIT_DEP_CHECK = 1
    WAIT_QUEUES = 2
    FINISH = 3


class ChipletModel:
    """Cycle-accurate model of one bingo_hw_manager_top."""

    def __init__(
        self,
        chiplet_id: int,
        num_clusters: int,
        num_cores: int,
        rng: random.Random,
        work_delay_range: tuple[int, int] = (20, 50),
        waiting_queue_depth: int = 8,
        ready_queue_depth: int = 8,
        checkout_queue_depth: int = 8,
        done_queue_depth: int = 32,
        done_queue_mode: Literal["single", "per_core"] = "single",
    ):
        self.chiplet_id = chiplet_id
        self.num_clusters = num_clusters
        self.num_cores = num_cores
        self.rng = rng
        self.done_queue_mode = done_queue_mode
        self.work_delay_range = work_delay_range

        # Task queue (from host)
        self.task_queue = FifoQueue("task_q", 32)

        # Per-(core, cluster) waiting dep check queues.  The RTL routes by
        # physical execution resource so a blocked dependency on one cluster
        # cannot stall the same core number on another cluster.
        self.waiting_queues: list[list[FifoQueue]] = [
            [FifoQueue(f"wait_co{co}_cl{cl}", waiting_queue_depth)
             for cl in range(num_clusters)]
            for co in range(num_cores)
        ]

        # One dep_check_manager FSM per physical execution resource.
        self.dep_check_fsm: list[list[DepCheckState]] = [
            [DepCheckState.IDLE for _ in range(num_clusters)]
            for _ in range(num_cores)
        ]

        # Per-cluster dep matrices
        self.dep_matrices: list[DepMatrix] = [
            DepMatrix(num_cores, num_cores)
            for _ in range(num_clusters)
        ]

        # Per-core-per-cluster ready + checkout queues
        self.ready_queues: list[list[FifoQueue]] = [
            [FifoQueue(f"rdy_co{co}_cl{cl}", ready_queue_depth)
             for cl in range(num_clusters)]
            for co in range(num_cores)
        ]
        self.checkout_queues: list[list[FifoQueue]] = [
            [FifoQueue(f"ckout_co{co}_cl{cl}", checkout_queue_depth)
             for cl in range(num_clusters)]
            for co in range(num_cores)
        ]

        # Done queue(s)
        if done_queue_mode == "single":
            self.done_queues = [FifoQueue("done_q", done_queue_depth)]
        else:
            self.done_queues = [
                FifoQueue(f"done_q_co{c}", done_queue_depth)
                for c in range(num_cores)
            ]

        # Chiplet done queue (from remote chiplets)
        self.chiplet_done_queue = FifoQueue("h2h_done_q", done_queue_depth)

        # Per-core execution state
        self.core_busy: list[list[bool]] = [
            [False] * num_cores for _ in range(num_clusters)
        ]
        self.core_task_id: list[list[int]] = [
            [-1] * num_cores for _ in range(num_clusters)
        ]
        self.core_countdown: list[list[int]] = [
            [0] * num_cores for _ in range(num_clusters)
        ]
        self.core_task: list[list[Optional[TaskDescriptor]]] = [
            [None] * num_cores for _ in range(num_clusters)
        ]

        # Round-robin arbiter for dep_matrix_set
        self._arbiter_idx = 0

        # Flux Tier 1: Conditional Execution Register File (32 groups)
        self.cerf: list[bool] = [False] * 32

    def cerf_write_mask(self, mask: int):
        """Write the full CERF bitmask (called by host/gating core)."""
        for i in range(32):
            self.cerf[i] = bool(mask & (1 << i))

    def cerf_update(self, controlled_mask: int, write_mask: int):
        """Read-modify-write: update only controlled groups."""
        current = sum((1 << i) for i in range(32) if self.cerf[i])
        updated = (current & ~controlled_mask) | (write_mask & controlled_mask)
        self.cerf_write_mask(updated)

    def cerf_clear_all(self):
        """Clear all CERF entries (for new inference batch)."""
        self.cerf = [False] * 32

    def tick(self, cycle: int) -> list[SimEvent]:
        """Advance one clock cycle. Returns events generated this cycle.

        Mirrors the RTL within-cycle evaluation order:
        Phase 1 (combinational on registered state):
          - task_queue → demux → push to waiting queues (1 task/cycle)
          - dep_check_manager FSM next-state logic
          - dep_matrix check (reads dep_matrix_q)
          - done_queue pop condition
          - arbiter grant for dep_matrix set
        Phase 2 (sequential update):
          - FIFO push/pop
          - FSM state register update
          - dep_matrix_q <= dep_matrix_d
          - Core countdown decrement
        """
        events = []

        # ================================================================
        # Phase 1a: Task queue → one task into waiting queues
        # ================================================================
        if not self.task_queue.empty:
            task = self.task_queue.peek()
            core = task.assigned_core_id
            cluster = task.assigned_cluster_id
            if not self.waiting_queues[core][cluster].full:
                self.task_queue.pop()
                self.waiting_queues[core][cluster].push(task)

        # ================================================================
        # Phase 1b: Per-(core, cluster) dep_check_manager FSM + dep_matrix check
        #
        # RTL behavior: dep_check reads the registered scoreboard. If a check
        # passes, its clear and any dep_set update commit at the same edge.
        # A set reusing the consumed (row, col, tag) is the next dependency
        # token, so it must remain present after that edge.
        # ================================================================
        self._pending_clears = []  # list of (cluster, row, check_code, check_tag)
        for core in range(self.num_cores):
            for cluster in range(self.num_clusters):
                events.extend(self._tick_dep_check_manager(core, cluster, cycle))

        # ================================================================
        # Phase 1c: Apply deferred clears before the new set. This gives the
        # replacement set priority when clear and set target the same tag.
        # ================================================================
        for cluster, row, check_code, check_tag in self._pending_clears:
            self.dep_matrices[cluster].clear_row(row, check_code, check_tag)

        # ================================================================
        # Phase 1c.5: Dep matrix set — arbiter grants ONE request per cycle
        # ================================================================
        events.extend(self._tick_dep_matrix_set(cycle))

        # ================================================================
        # Phase 1d: Core execution — dispatch from ready queue + countdown
        # ================================================================
        events.extend(self._tick_cores(cycle))

        return events

    def _tick_dep_check_manager(
        self, core: int, cluster: int, cycle: int
    ) -> list[SimEvent]:
        """One FSM step for dep_check_manager[core][cluster]."""
        events = []
        state = self.dep_check_fsm[core][cluster]
        wq = self.waiting_queues[core][cluster]

        if state == DepCheckState.IDLE:
            if not wq.empty:
                self.dep_check_fsm[core][cluster] = DepCheckState.WAIT_DEP_CHECK

        elif state == DepCheckState.WAIT_DEP_CHECK:
            task = wq.peek()
            # dep_check_ready_i comes from dep_matrix result (or bypass)
            if not task.dep_check_en:
                # Bypass: dep_check disabled → immediate pass
                self.dep_check_fsm[core][cluster] = DepCheckState.WAIT_QUEUES
            else:
                result = self.dep_matrices[cluster].check_row(
                    core, task.dep_check_code, task.dep_check_tag)
                if result:
                    self.dep_check_fsm[core][cluster] = DepCheckState.WAIT_QUEUES

        elif state == DepCheckState.WAIT_QUEUES:
            task = wq.peek()
            # Check if ready_queue and checkout_queue can accept
            # Dummy check tasks (task_type=1, dep_check_en=1) bypass ready queue
            is_dummy_check = (task.task_type == 1 and task.dep_check_en)
            # Dummy set tasks (task_type=1, dep_set_en=1) bypass ready queue
            is_dummy_set = (task.task_type == 1 and task.dep_set_en)

            ready_ok = (is_dummy_check or is_dummy_set or
                        not self.ready_queues[core][cluster].full)
            checkout_ok = not self.checkout_queues[core][cluster].full

            if ready_ok and checkout_ok:
                self.dep_check_fsm[core][cluster] = DepCheckState.FINISH

        elif state == DepCheckState.FINISH:
            task = wq.peek()

            # DEFER dep_matrix clear — will be applied after dep_set in tick()
            if task.dep_check_en:
                self._pending_clears.append((cluster, core, task.dep_check_code, task.dep_check_tag))

            # Flux Tier 1: CERF conditional skip check
            cond_skip = False
            if task.cond_exec_en:
                group_active = self.cerf[task.cond_exec_group_id]
                if task.cond_exec_invert:
                    cond_skip = group_active      # skip when active
                else:
                    cond_skip = not group_active   # skip when inactive

            is_dummy_check = (task.task_type == 1 and task.dep_check_en)
            is_dummy_set = (task.task_type == 1 and task.dep_set_en)

            if cond_skip:
                # CERF skip: task enters checkout ONLY (as dummy, for dep_set propagation)
                # Mirrors RTL: checkout_queue_data_in.task_type forced to 2'b01
                from dataclasses import replace
                skip_task = replace(task, task_type=1)
                self.checkout_queues[core][cluster].push(skip_task)
                event_type = "TASK_SKIPPED"
            else:
                # Normal flow: push to ready queue (unless dummy)
                if not is_dummy_check and not is_dummy_set:
                    self.ready_queues[core][cluster].push(task)
                # Push to checkout queue
                self.checkout_queues[core][cluster].push(task)
                event_type = "DEP_CHECK_PASS"

            wq.pop()

            events.append(SimEvent(
                time=cycle,
                event_type=event_type,
                chiplet_id=self.chiplet_id,
                cluster_id=cluster,
                core_id=core,
                task_id=task.task_id,
            ))

            self.dep_check_fsm[core][cluster] = DepCheckState.IDLE

        return events

    def _tick_dep_matrix_set(self, cycle: int) -> list[SimEvent]:
        """Arbiter grants ONE dep_matrix set per cycle.

        Candidates (round-robin):
        - Per (core, cluster) checkout queue: dummy_set at head fires directly;
          normal task at head needs done_queue match.
        - Chiplet done queue: H2H signals fire directly.

        RTL: stream_arbiter_dep_matrix_set with N_INP = num_cores*num_clusters + 1
        """
        events = []
        n_candidates = self.num_cores * self.num_clusters + 1  # +1 for chiplet_done_queue

        for attempt in range(n_candidates):
            idx = (self._arbiter_idx + attempt) % n_candidates

            if idx < self.num_cores * self.num_clusters:
                # Local checkout queue candidate
                core = idx % self.num_cores
                cluster = idx // self.num_cores
                ev = self._try_checkout_dep_set(core, cluster, cycle)
                if ev:
                    events.extend(ev)
                    self._arbiter_idx = (idx + 1) % n_candidates
                    return events  # One grant per cycle
            else:
                # Chiplet done queue candidate
                ev = self._try_chiplet_done_dep_set(cycle)
                if ev:
                    events.extend(ev)
                    self._arbiter_idx = (idx + 1) % n_candidates
                    return events

        # No grant this cycle
        self._arbiter_idx = (self._arbiter_idx + 1) % n_candidates
        return events

    def _try_checkout_dep_set(self, core: int, cluster: int, cycle: int) -> Optional[list[SimEvent]]:
        """Try to fire dep_set from checkout[core][cluster].

        Mirrors RTL lines 746-751 (arbiter valid logic) + 1015-1017 (done_queue_pop).
        """
        cq = self.checkout_queues[core][cluster]
        if cq.empty:
            return None

        task = cq.peek()

        if task.task_type == 1 and task.dep_set_en:
            # Dummy set: fires directly (no done_queue match needed)
            return self._fire_dep_set(task, cq, None, cycle)

        if task.task_type == 1 and task.dep_check_en:
            # Dummy check in checkout: just pop it (no dep_set)
            cq.pop()
            return []

        if task.task_type in (0, 2) and not task.dep_set_en:
            # Normal/gating task with no dep_set: needs done_queue match to pop
            dq, done_info = self._find_done_match(core, cluster)
            if done_info:
                cq.pop()
                dq.pop()
                return []
            return None  # No done match → blocked

        if task.task_type in (0, 2) and task.dep_set_en:
            # Normal/gating task with dep_set: needs done_queue match
            dq, done_info = self._find_done_match(core, cluster)
            if not done_info:
                return None  # No done match → blocked
            return self._fire_dep_set(task, cq, dq, cycle)

        return None

    def _find_done_match(self, core: int, cluster: int):
        """Find a done_queue entry matching (core, cluster).

        In 'single' mode: only the HEAD must match (HOL blocking).
        In 'per_core' mode: only the HEAD of core's queue must match on cluster.
        """
        if self.done_queue_mode == "single":
            dq = self.done_queues[0]
            if dq.empty:
                return dq, None
            head = dq.peek()
            if head.assigned_core_id == core and head.assigned_cluster_id == cluster:
                return dq, head
            return dq, None  # HOL blocked
        else:
            dq = self.done_queues[core]
            if dq.empty:
                return dq, None
            head = dq.peek()
            if head.assigned_cluster_id == cluster:
                return dq, head
            return dq, None  # Cluster mismatch

    def _fire_dep_set(self, task, cq, dq, cycle) -> list[SimEvent]:
        """Fire a dep_set operation. Returns events or None if overlap blocks it."""
        events = []
        target_chiplet = task.dep_set_chiplet_id
        target_cluster = task.dep_set_cluster_id
        dep_set_code = task.dep_set_code
        dep_set_tag = task.dep_set_tag
        source_core = task.assigned_core_id

        if target_chiplet == self.chiplet_id and not task.dep_set_all_chiplet:
            # Local: try dep_matrix set_column
            success = self.dep_matrices[target_cluster].set_column(
                source_core, dep_set_code, dep_set_tag
            )
            if not success:
                return None  # Overlap → blocked, arbiter moves on

            cq.pop()
            if dq is not None:
                dq.pop()
            events.append(SimEvent(
                time=cycle,
                event_type="DEP_SET",
                chiplet_id=self.chiplet_id,
                cluster_id=target_cluster,
                core_id=source_core,
                task_id=task.task_id,
            ))
        else:
            # Remote chiplet or broadcast
            cq.pop()
            if dq is not None:
                dq.pop()
            events.append(SimEvent(
                time=cycle,
                event_type="DEP_SET_CHIPLET_SENT",
                chiplet_id=self.chiplet_id,
                cluster_id=task.assigned_cluster_id,
                core_id=source_core,
                task_id=task.task_id,
                extra={
                    "target_chiplet": target_chiplet,
                    "target_cluster": target_cluster,
                    "dep_set_code": dep_set_code,
                    "dep_set_tag": dep_set_tag,
                    "source_core": source_core,
                    "broadcast": task.dep_set_all_chiplet,
                },
            ))
        return events

    def _try_chiplet_done_dep_set(self, cycle: int) -> Optional[list[SimEvent]]:
        """Try to drain one entry from chiplet_done_queue through dep_matrix."""
        if self.chiplet_done_queue.empty:
            return None
        source_core, target_cluster, dep_set_code, dep_set_tag = self.chiplet_done_queue.peek()
        success = self.dep_matrices[target_cluster].set_column(source_core, dep_set_code, dep_set_tag)
        if not success:
            return None  # Overlap
        self.chiplet_done_queue.pop()
        return []  # No trace event for internal H2H processing

    def _tick_cores(self, cycle: int) -> list[SimEvent]:
        """Core dispatch + execution countdown."""
        events = []
        for cl in range(self.num_clusters):
            for co in range(self.num_cores):
                if self.core_busy[cl][co]:
                    self.core_countdown[cl][co] -= 1
                    if self.core_countdown[cl][co] <= 0:
                        # Task done
                        task_id = self.core_task_id[cl][co]
                        completed_task = self.core_task[cl][co]
                        self.core_busy[cl][co] = False
                        self.core_task_id[cl][co] = -1
                        self.core_task[cl][co] = None

                        # Gating task: emit CERF_WRITE event (applied by top-level sim)
                        if completed_task is not None and completed_task.cerf_controlled_mask:
                            events.append(SimEvent(
                                time=cycle,
                                event_type="CERF_WRITE",
                                chiplet_id=self.chiplet_id,
                                cluster_id=cl,
                                core_id=co,
                                task_id=task_id,
                                extra={
                                    "cerf_write_mask": completed_task.cerf_write_mask,
                                    "cerf_controlled_mask": completed_task.cerf_controlled_mask,
                                },
                            ))

                        # Push to done queue
                        done_info = DoneInfo(task_id, co, cl)
                        if self.done_queue_mode == "single":
                            self.done_queues[0].push(done_info)
                        else:
                            self.done_queues[co].push(done_info)

                        events.append(SimEvent(
                            time=cycle,
                            event_type="TASK_DONE",
                            chiplet_id=self.chiplet_id,
                            cluster_id=cl,
                            core_id=co,
                            task_id=task_id,
                        ))
                else:
                    # Try dispatch from ready queue
                    rq = self.ready_queues[co][cl]
                    if not rq.empty:
                        task = rq.pop()
                        delay = task.work_delay if task.work_delay is not None else self.rng.randint(*self.work_delay_range)
                        self.core_busy[cl][co] = True
                        self.core_task_id[cl][co] = task.task_id
                        self.core_task[cl][co] = task
                        self.core_countdown[cl][co] = delay

                        events.append(SimEvent(
                            time=cycle,
                            event_type="TASK_DISPATCHED",
                            chiplet_id=self.chiplet_id,
                            cluster_id=cl,
                            core_id=co,
                            task_id=task.task_id,
                        ))
        return events

    def receive_chiplet_dep_set(self, source_core_id, target_cluster_id, dep_set_code, dep_set_tag=None):
        """Queue an incoming H2H dep_set into the chiplet_done_queue."""
        self.chiplet_done_queue.push((source_core_id, target_cluster_id, dep_set_code, dep_set_tag))

    def is_idle(self) -> bool:
        """True if no work remains anywhere in this chiplet."""
        if not self.task_queue.empty:
            return False
        for co in range(self.num_cores):
            for cl in range(self.num_clusters):
                if not self.waiting_queues[co][cl].empty:
                    return False
        for cl in range(self.num_clusters):
            for co in range(self.num_cores):
                if self.core_busy[cl][co]:
                    return False
                if not self.ready_queues[co][cl].empty:
                    return False
                if not self.checkout_queues[co][cl].empty:
                    return False
        for dq in self.done_queues:
            if not dq.empty:
                return False
        if not self.chiplet_done_queue.empty:
            return False
        return True

    def dump_state(self) -> str:
        lines = [f"=== Chiplet {self.chiplet_id} ({self.done_queue_mode}) ==="]
        for cl in range(self.num_clusters):
            lines.append(f"  Cluster {cl} Dep Matrix:")
            lines.append(self.dep_matrices[cl].dump_state())
        for i, dq in enumerate(self.done_queues):
            if not dq.empty:
                lines.append(f"  Done queue[{i}]: "
                             f"{[(d.task_id, d.assigned_core_id, d.assigned_cluster_id) for d in dq.items]}")
        if not self.chiplet_done_queue.empty:
            lines.append(f"  H2H done queue: {list(self.chiplet_done_queue.items)}")
        for co in range(self.num_cores):
            for cl in range(self.num_clusters):
                wq = self.waiting_queues[co][cl]
                fsm = self.dep_check_fsm[co][cl].name
                rq = self.ready_queues[co][cl]
                cq = self.checkout_queues[co][cl]
                busy = self.core_busy[cl][co]
                cq_head = ""
                if not cq.empty:
                    t = cq.peek()
                    ty = "dummy_set" if (t.task_type == 1 and t.dep_set_en) else \
                         "dummy_chk" if t.task_type == 1 else "normal"
                    cq_head = f" [head:t{t.task_id} {ty}]"
                lines.append(
                    f"  Core {co} Cl{cl}: waiting={wq.count}/{wq.depth} "
                    f"fsm={fsm} rdy={rq.count} ckout={cq.count}{cq_head} "
                    f"busy={busy}"
                )
        return "\n".join(lines)
