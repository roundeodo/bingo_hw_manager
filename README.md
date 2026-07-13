# Bingo Hardware Task Manager

A hardware task scheduler for heterogeneous multi-core, multi-chiplet SoCs. It accepts a stream of task descriptors with encoded dependency information, resolves inter-task dependencies through a per-cluster dependency matrix, and dispatches ready tasks to execution cores. The dependency matrix is an **identity-aware tagged scoreboard** — a consumer waits for *its* producer rather than any signal from a producer core. See **Identity-Aware Dependencies**.

**Authors:** Fanchen Kong, Xiaoling Yi, Yunhao Deng  
**Affiliation:** KU Leuven (MICAS)

## Architecture Overview

```
Host / Software Runtime
         |
         | Task descriptors (64-bit packed structs)
         v
  +--------------+       +------------------------------------------+
  | Task Queue   |       |  Per-Chiplet HW Manager                  |
  | (AXI-Lite or |------>|                                          |
  |  Master)     |       |  +-- stream_demux (by core_id) ------+  |
  +--------------+       |  |                                    |  |
                         |  v                                    |  |
                +--------+----------+   +--------+----------+   |  |
                | Waiting Queue     |   | Waiting Queue     |...|  |
                | Core 0 (depth 8)  |   | Core 1 (depth 8)  |   |  |
                +--------+----------+   +--------+----------+   |  |
                         |                       |               |  |
                    dep_check_manager FSM    dep_check_manager   |  |
                    (IDLE->CHECK->QUEUE->FINISH)                 |  |
                         |                       |               |  |
                +--------v-----------+-----------v---------+     |  |
                |  Counter-Based Dependency Matrix         |     |  |
                |  (per cluster, 8-bit saturating counters)|     |  |
                |  set: counter++ (always accepts)         |     |  |
                |  check: all required counters >= 1       |     |  |
                |  clear: counter-- (on successful check)  |     |  |
                +--------+-----------+---------------------+     |  |
                         |                                       |  |
          +--------------+--------------+                        |  |
          v                             v                        |  |
  +-------+--------+   +-------+--------+                       |  |
  | Ready Queue    |   | Checkout Queue |                       |  |
  | [core][cluster]|   | [core][cluster]|                       |  |
  | -> Device Core |   | -> dep_set     |                       |  |
  +----------------+   +-------+--------+                       |  |
          |                     |                                |  |
     (execute)        +---------+----------+                     |  |
          |           |                    |                     |  |
          v      Local dep_set      Remote dep_set (H2H)        |  |
  +-------+--------+  |           +-------------------+         |  |
  | Done Queue     |  |           | Chiplet Dep Set   |         |  |
  | [core][cluster]|  |           | AXI-Lite Master   |------+  |  |
  | (per-pair FIFO)|  |           | -> remote chiplet |      |  |  |
  +-------+--------+  |           +-------------------+      |  |  |
          |            |                                      |  |  |
          +----> Arbiter -> dep_matrix.set_column()           |  |  |
                                                              |  |  |
  +-----------------------------------------------------------+  |  |
  | From Remote Chiplets (H2H)                                   |  |
  |   -> Chiplet Done Queue -> Arbiter -> dep_matrix.set_column()|  |
  +--------------------------------------------------------------+  |
  +------------------------------------------------------------------+
```

## Task Descriptor Format

Each task is a 64-bit packed struct pushed into the task queue:

| Field | Width | Description |
|-------|-------|-------------|
| `task_type` | 1 | 0 = normal (executes on core), 1 = dummy (synchronization only) |
| `task_id` | 12 | Unique identifier (0-4095) |
| `assigned_chiplet_id` | 8 | Target chiplet |
| `assigned_cluster_id` | log2(clusters) | Target cluster within chiplet |
| `assigned_core_id` | log2(cores) | Target core within cluster |
| `dep_check_en` | 1 | Enable dependency checking before dispatch |
| `dep_check_code` | N_CORES | Bitmask: which core columns to check in dep matrix |
| `dep_set_en` | 1 | Enable dependency signaling after completion |
| `dep_set_all_chiplet` | 1 | Broadcast dep_set to all chiplets |
| `dep_set_chiplet_id` | 8 | Target chiplet for dep_set |
| `dep_set_cluster_id` | log2(clusters) | Target cluster for dep_set |
| `dep_set_code` | N_CORES | Bitmask: which core rows to signal in dep matrix |
| `dep_check_tag` | `DepTagWidth` | Per-edge identity tag this check expects |
| `dep_set_tag` | `DepTagWidth` | Per-edge identity tag this set carries |

The two tag fields are carved from the descriptor's reserved bits, so the
64-bit layout is unchanged. See **Identity-Aware Dependencies** below.

## Task Lifecycle

```
1. PUSH      Host writes task descriptor to task queue
2. ROUTE     Demux routes task to assigned core's waiting queue
3. CHECK     dep_check_manager reads dep_matrix:
             - dep_check_en=0: bypass (immediate pass)
             - dep_check_en=1: wait until the expected tag is present in
               every required column
4. CLEAR     On pass, clear the checked (column, tag) presence bits
5. DISPATCH  Task enters ready queue; core reads and executes
6. COMPLETE  Core writes done_info to per-(core,cluster) done queue
7. SIGNAL    Done queue + checkout queue match triggers dep_set:
             - Local: set the tag's presence bit in target cluster's dep matrix
             - Remote: AXI-Lite write to target chiplet's H2H mailbox
```

## Tagged Dependency Matrix

Each cluster has a dependency matrix with `N_CORES x N_CORES` cells, where each cell is a `2**DepTagWidth` **presence-bit scoreboard** over per-edge identity tags.

```
             Column (signal source core)
             core 0    core 1    core 2
Row 0 (co0)  [tags]    [tags]    [tags]   <- what core 0 waits for
Row 1 (co1)  [tags]    [tags]    [tags]   <- what core 1 waits for
Row 2 (co2)  [tags]    [tags]    [tags]   <- what core 2 waits for
```

**Operations:**
- `set_column(col, mask, tag)`: For each row in mask, set the presence bit `[row][col][tag]`. **Always succeeds** (no overlap rejection, `dep_set_ready = '1`).
- `check_row(row, mask, tag)`: True if bit `[row][c][tag]` is set for every column `c` in the mask.
- `clear_row(row, mask, tag)`: Clear bit `[row][c][tag]` for each column `c` in the mask.

There is no overlap rejection or backpressure, so the deadlock of the historical 1-bit overlap-detecting design (a second `set` to an already-set bit was rejected, creating circular backpressure through the done queue) cannot occur.

## Identity-Aware Dependencies (per-edge tags)

An identity-blind cell (one shared counter per `(consumer_core, producer_core)`
pair) knows the *number* of pending signals from a producer core, not *which*
producer raised them. Because one cell is shared by **every** producer→consumer
edge that maps to the same pair, a consumer could drain a stray signal meant for
a different consumer and dispatch **before its own input is ready** (the
counter-sharing hazard; see `COUNTER_SHARING_BUG.md`). That legacy counter
matrix — and the even older `serialize_shared_counter_consumers` software
mitigation — have been **removed**; per-edge identity tags are the design.

- **Hardware:** each cell is a `2**DepTagWidth` **presence-bit scoreboard**. A
  `set` writes the bit at its `dep_set_tag`; a `check` passes only on its own
  `dep_check_tag`; `clear` clears that one bit. A stray set carries a tag no
  consumer expects, so it can never satisfy an unrelated check. `DepTagWidth=4`
  (default) sizes the scoreboard to a layer's natural concurrency.
- **Software (mini-compiler):** `bingo_transform_dfg_allocate_dep_tags(W)` assigns
  each edge a tag via an optimal **minimum chain-cover** of the happens-before
  partial order per cell (edges that can never be live at once share a tag). The
  order accounts for **same-core HOL** execution (each core dispatches its tasks in
  topological order), which collapses same-core/diagonal cells to a single chain →
  one tag. This reuse is what lets a tiny fixed `DepTagWidth` suffice with **no
  separate concurrency-bounding pass**: if a cell ever needs more than `2**W`
  simultaneously-live edges the allocator **raises** (a placement signal —
  co-locate/serialize those producers, or widen `DepTagWidth`), rather than
  silently aliasing. The compiler does the heavy lifting; the hardware stays tiny.
  See [docs/identity_aware_dependency_matrix.md](docs/identity_aware_dependency_matrix.md)
  for a worked tutorial.

The tags ride the existing datapath: they live inside `dep_check_info`/
`dep_set_info` in the descriptor, flow through the dep-matrix set arbiter/demux in
the `dep_matrix_set_meta` struct, and are checked by the per-core
`dep_check_manager`. End-to-end RTL test: `test/tb_bingo_hw_manager_tagged.sv`.

## Per-(Core, Cluster) Done Queues

Each `(core, cluster)` pair has its own independent done queue FIFO:

```
Done Queues: [NUM_CORES][NUM_CLUSTERS] independent FIFOs

done_q[0][0]   done_q[0][1]     <- core 0, clusters 0..1
done_q[1][0]   done_q[1][1]     <- core 1, clusters 0..1
done_q[2][0]   done_q[2][1]     <- core 2, clusters 0..1
```

The pop condition for each FIFO depends ONLY on its own state:
```
done_q_pop[core][cluster] = !done_q_empty[core][cluster]
                          && checkout[core][cluster].task_type == NORMAL
                          && arbiter_ready[core + cluster * N_CORES]
```

No cross-core or cross-cluster dependency in the pop logic. This eliminates head-of-line blocking where one core's completion stalls behind another core's entry in a shared FIFO.

## Module Hierarchy

```
bingo_hw_manager_top
 |
 +-- Task Queue (1x)
 |    +-- write_mailbox (AXI-Lite slave mode) OR
 |    +-- task_queue_master (AXI-Lite master mode)
 |
 +-- Per-Core Pipeline (NUM_CORES_PER_CLUSTER instances)
 |    +-- fifo_v3 (waiting_dep_check_queue, depth=8)
 |    +-- dep_check_manager (4-state FSM)
 |    +-- stream_filter (dep_check_en bypass)
 |    +-- stream_demux (route to cluster)
 |    +-- stream_filter (dummy task filter)
 |    +-- stream_demux (route to cluster, ready+checkout path)
 |
 +-- Per-Cluster Dep Matrix (NUM_CLUSTERS_PER_CHIPLET instances)
 |    +-- dep_matrix (tagged presence-bit scoreboard)
 |
 +-- Per-(Core, Cluster) Queues (N_CORES x N_CLUSTERS instances each)
 |    +-- Ready Queue: read_mailbox or fifo_v3
 |    +-- Checkout Queue: fifo_v3 (depth=CheckoutQueueDepth)
 |    +-- Done Queue: fifo_v3 (depth=DoneQueueDepth)
 |    +-- stream_demux (local vs H2H dep_set routing)
 |    +-- stream_filter (dep_set_en filtering)
 |
 +-- Dep Matrix Set Arbiter (1x)
 |    +-- stream_arbiter (N_CORES*N_CLUSTERS + 1 inputs)
 |    +-- stream_demux (route to cluster dep matrix)
 |    +-- stream_demux (route to core within cluster)
 |
 +-- H2H Communication
 |    +-- Chiplet Dep Set Master (AXI-Lite master, 1x)
 |    +-- stream_arbiter (chiplet dep set, from all cores)
 |    +-- Chiplet Done Queue (write_mailbox, 1x)
 |
 +-- Power Manager (1x)
      +-- bingo_hw_manager_pm (idle-based clock gating)
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `NUM_CORES_PER_CLUSTER` | 4 | Execution cores per cluster |
| `NUM_CLUSTERS_PER_CHIPLET` | 2 | Clusters per chiplet |
| `DepTagWidth` | 4 | Tag width (cell holds up to `2**DepTagWidth` concurrent edges) |
| `TaskIdWidth` | 12 | Task ID width (max 4096 tasks) |
| `ChipIdWidth` | 8 | Chiplet ID width (max 256 chiplets) |
| `HostAxiLiteAddrWidth` | 48 | Host-side AXI address width |
| `HostAxiLiteDataWidth` | 64 | Host-side AXI data width (task descriptor) |
| `DeviceAxiLiteAddrWidth` | 48 | Device-side AXI address width |
| `DeviceAxiLiteDataWidth` | 32 | Device-side AXI data width (done info) |
| `TaskQueueDepth` | 32 | Incoming task FIFO depth |
| `DoneQueueDepth` | 32 | Per-(core,cluster) done FIFO depth |
| `CheckoutQueueDepth` | 8 | Per-(core,cluster) checkout FIFO depth |
| `ReadyQueueDepth` | 8 | Per-(core,cluster) ready FIFO depth |
| `TASK_QUEUE_TYPE` | 1 | 0: AXI-Lite slave, 1: AXI-Lite master |
| `READY_AND_DONE_QUEUE_INTERFACE_TYPE` | 1 | 0: AXI-Lite, 1: CSR req/resp |

## Interface Modes

**Task Queue:**
- **Mode 0 (Slave):** Host pushes task descriptors via AXI-Lite writes to a mailbox
- **Mode 1 (Master):** HW manager fetches task descriptors from host memory at `task_list_base_addr_i`

**Ready/Done Queues:**
- **Mode 0 (AXI-Lite):** Cores read ready tasks and write completions via AXI-Lite
- **Mode 1 (CSR):** Cores use lightweight CSR req/resp interface (lower latency)

## Cross-Chiplet Communication

When a task's `dep_set_chiplet_id != chip_id_i`, the dependency signal is routed to a remote chiplet via the H2H path:

1. Checkout queue entry routed to chiplet dep_set arbiter
2. `bingo_hw_manager_chiplet_dep_set` module sends AXI-Lite write to remote chiplet's mailbox
3. Remote chiplet receives via `from_remote_axi_lite_req_i` into its chiplet done queue
4. Remote chiplet processes the signal through its dep matrix set arbiter

Broadcast mode (`dep_set_all_chiplet = 1`) sends the signal to all chiplets simultaneously.

## Dependencies

- [AXI](https://github.com/pulp-platform/axi) v0.39.1 — AXI-Lite definitions, crossbar
- [common_cells](https://github.com/pulp-platform/common_cells) v1.37.0 — FIFO, stream arbiter/demux/filter, counters

## DARTS: Dynamic Adaptive Runtime Task Scheduling

DARTS extends the static scheduler with conditional execution support for data-dependent workloads (MoE routing, early exit). See `dev_doc/` for full architecture documentation.

### Conditional Execution (CERF)

A 16-entry Conditional Execution Register File (CERF) per chiplet enables runtime task skipping. Tasks marked as conditional are either executed or skipped based on the CERF state, which is written by **gating tasks** on completion.

The user expresses conditional execution through **conditional edges** in the DFG:

```python
# Router conditionally activates each expert (compiler handles the rest)
dfg.bingo_add_edge(router, expert_0, cond=True)
dfg.bingo_add_edge(router, expert_1, cond=True)
dfg.bingo_add_edge(expert_0, aggregator)          # unconditional

# Compile: auto-assigns CERF groups, promotes router to gating task
compile_dfg(dfg)

# Simulate: specify which nodes are active
run_sim(dfg, config, active_nodes={expert_0})
```

The compiler pass `bingo_compile_conditional_regions()`:
1. Scans edges for `cond=True`
2. Auto-promotes source nodes to gating tasks (`task_type=2`)
3. Groups conditional targets by connected components (unconditional edges between targets = shared CERF group)
4. Assigns CERF group IDs (0-15) automatically

Skipped tasks still propagate dependency signals (via the checkout queue as dummies), preserving graph correctness.

### Additional Modules

| Module | Purpose |
|--------|---------|
| `bingo_hw_manager_cond_exec_controller.sv` | 16-entry CERF register file |
| `bingo_hw_manager_load_monitor.sv` | Per-core pending task counters (load monitoring) |

### Evaluation Results

Evaluated via cycle-accurate Python simulator (`scripts/eval_darts.py`):

| Workload | Configuration | Speedup |
|----------|---------------|---------|
| MoE 8 experts, top-2 | 1 cluster, 3 cores | 2.29x |
| MoE 16 experts, top-1 | 1 cluster, 3 cores | 4.15x |
| MoE 8 experts, top-2 | 2 chiplets | 1.84-1.95x |
| Early exit (stage 0/4) | 1 cluster, 3 cores | 3.28x |

## Source Files

| Level | File | Description |
|-------|------|-------------|
| 0 | `bingo_hw_manager_mailbox_adapter.sv` | AXI-Lite to mailbox adapter |
| 0 | `bingo_hw_manager_read_mailbox.sv` | FIFO-to-AXI-Lite read bridge |
| 0 | `bingo_hw_manager_write_mailbox.sv` | AXI-Lite-to-FIFO write bridge |
| 0 | `bingo_hw_manager_task_queue_master.sv` | AXI-Lite master for task fetching |
| 0 | `bingo_hw_manager_csr_to_fifo*.sv` | CSR interface adapters |
| 1 | `bingo_hw_manager_dep_matrix.sv` | Dependency matrix: identity-aware tagged presence-bit scoreboard |
| 1 | `bingo_hw_manager_chiplet_dep_set.sv` | H2H AXI-Lite master |
| 1 | `bingo_hw_manager_dep_check_manager.sv` | Dependency check FSM |
| 1 | `bingo_hw_manager_pm.sv` | Power manager |
| 1 | `bingo_hw_manager_cond_exec_controller.sv` | CERF (conditional execution) |
| 1 | `bingo_hw_manager_load_monitor.sv` | Load monitoring |
| 2 | `bingo_hw_manager_top.sv` | Top-level integration |

## Testing

Two layers, both self-contained in this repo:

- **Cycle-accurate Python model** (`model/`) mirroring the RTL pipeline, with a
  pytest suite in `model/tests/`:
  - `test_dep_matrix.py` — the matrix primitive (tagged presence-bit scoreboard)
  - `test_single_chiplet.py`, `test_multi_chiplet.py` — pipeline / H2H integration
  - `test_cross_cluster_handoff_guard.py` — cross-cluster placement guard
  - `test_identity_stray_increment.py` — reproduces the counter-sharing hazard and shows the tag fix closes it
  - `test_dep_tag_allocator.py` — the tag allocator (min-chain-cover): edge pairing, tag reuse, distinct tags for concurrent edges, capacity backstop
  - `test_dep_sync.py` — multi-cluster dispatch-before-producer gate (must be clean under tags); also runnable as a CLI
- **RTL testbench harness** (`test/tb_bingo_hw_manager_harness.svh`) with deadlock
  detection, dep-matrix monitoring, and trace logging, driving the testbenches:
  `tb_bingo_hw_manager_top` (multi-chiplet), `tb_bingo_hw_manager_cerf_basic/skip`
  (CERF), `tb_bingo_hw_manager_dep_matrix` (matrix unit), and
  `tb_bingo_hw_manager_tagged`/`_tagged_mc` (identity-aware deps end-to-end).
- **DFG compiler** (`sw/bingo_dfg.py`) with automatic dummy task insertion and the
  identity-aware per-edge tag allocator (min-chain-cover).

```bash
# RTL: compile + simulate one testbench (requires QuestaSim)
make compile.log
make sim-bingo_hw_manager_top.log           # or _tagged / _dep_matrix / _cerf_basic / _cerf_skip

# Python model + compiler tests
make test-model                             # python3 -m pytest model/tests/

# Dependency-sync gate as a standalone report
python3 model/tests/test_dep_sync.py --seeds 20 --clusters 2
```

All Python model tests and all RTL testbenches pass; the per-edge identity tags
drive the dispatch-before-producer hazard to zero.
