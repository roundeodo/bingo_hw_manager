# Fanchen Kong <fanchen.kong@kuleuven.be>
# The main bingo file
# Users need to specify the input DFG file here

from bingo_dfg import BingoDFG
from bingo_node import BingoNode

# Example Usage
# We have 3 cores per cluster
# core 0: GeMM
# core 1: DMA
# core 2: SIMD
# 2 clusters per chiplet and 4 clusters in total
bingo_dfg = BingoDFG()
# -----------------------------
# Chiplet 0's tasks
# -----------------------------
# gemm (Cl0) -> dma(Cl1) -> simd(Cl0)
# Here the mini compiler does not need to do generate the dummy nodes for dep set/check
chip0_cluster0_core0_gemm = BingoNode(assigned_chiplet_id=0,
                                      assigned_cluster_id=0,
                                      assigned_core_id=0, node_name="chip0_cluster0_core0_gemm")
chip0_cluster1_core1_dma = BingoNode(assigned_chiplet_id=0,
                                     assigned_cluster_id=1,
                                     assigned_core_id=1, node_name="chip0_cluster1_core1_dma")
chip0_cluster0_core2_simd = BingoNode(assigned_chiplet_id=0,
                                      assigned_cluster_id=0,
                                      assigned_core_id=2, node_name="chip0_cluster0_core2_simd")
bingo_dfg.bingo_add_node(chip0_cluster0_core0_gemm)
bingo_dfg.bingo_add_node(chip0_cluster1_core1_dma)
bingo_dfg.bingo_add_node(chip0_cluster0_core2_simd)
bingo_dfg.bingo_add_edge(chip0_cluster0_core0_gemm, chip0_cluster1_core1_dma)
bingo_dfg.bingo_add_edge(chip0_cluster1_core1_dma, chip0_cluster0_core2_simd)
# -----------------------------
# Chiplet 1's tasks
# -----------------------------
#            simd(Cl0)
#           /         \
#          |           |
#          v           v
#         dma(Cl0)    gemm(Cl1)
#          |           |
#           \         /
#            v       v
#            gemm(Cl0)
chip1_cluster0_core2_simd = BingoNode(assigned_chiplet_id=1,
                                      assigned_cluster_id=0,
                                      assigned_core_id=2, node_name="chip1_cluster0_core2_simd")
chip1_cluster0_core1_dma = BingoNode(assigned_chiplet_id=1,
                                     assigned_cluster_id=0,
                                     assigned_core_id=1, node_name="chip1_cluster0_core1_dma")
chip1_cluster1_core0_gemm = BingoNode(assigned_chiplet_id=1,
                                      assigned_cluster_id=1,
                                      assigned_core_id=0, node_name="chip1_cluster1_core0_gemm")
chip1_cluster0_core0_gemm = BingoNode(assigned_chiplet_id=1,
                                      assigned_cluster_id=0,
                                      assigned_core_id=0, node_name="chip1_cluster0_core0_gemm")
bingo_dfg.bingo_add_node(chip1_cluster0_core2_simd)
bingo_dfg.bingo_add_node(chip1_cluster0_core1_dma)
bingo_dfg.bingo_add_node(chip1_cluster1_core0_gemm)
bingo_dfg.bingo_add_node(chip1_cluster0_core0_gemm)
bingo_dfg.bingo_add_edge(chip1_cluster0_core2_simd, chip1_cluster0_core1_dma)
bingo_dfg.bingo_add_edge(chip1_cluster0_core2_simd, chip1_cluster1_core0_gemm)
bingo_dfg.bingo_add_edge(chip1_cluster0_core1_dma, chip1_cluster0_core0_gemm)
bingo_dfg.bingo_add_edge(chip1_cluster1_core0_gemm, chip1_cluster0_core0_gemm)
# We use the upper part
#            simd(Cl0)
#           /         \
#          |           |
#          v           v
#         dma(Cl0)    gemm(Cl1)
# to show the dummy set task
# Since the task description only have one dep_set_code and one dep_set_cluster_id field, it is not possible to set the dependency from simd to both gemm and dma
# So we need to create a dummy node after the simd node to set the depdencies
#            simd(Cl0)
#           /         \\
#          |           || <--  notice the double line here, it is a fake edge 
#          |           ||      since we explicitly create the dummy task with the same type of the simd task
#          v           vv      all we need to do is to push the dummy task after the simd task to describe this dependency
#         dma(Cl0)    dummy dep set simd task(Cl1)
#                      |
#                      v
#                    gemm(Cl1)
#                      
#                      | FIFO IN
#                      v
#                 -----------------------
#   SIMD          |                     |
#  Wait Check     |  dummy dep set simd |  ----> To set Gemm(Cl1)
#   Queue         |                     |
#                 |  simd               | ----> To set DMA(CL0)
#                 -----------------------
#                      |
#                      v FIFO OUT
# The double line dependency is implcitly managed by the FIFO Queue
# The dummy set task will not enter the ready queue and the checkout queue
# after the dep set is done, it will be discarded
# -----------------------------
# Chiplet 2's tasks
# -----------------------------
#            gemm(Cl0)
#           /         \
#          |           |
#          v           v
#         dma(Cl0)    dma(Cl1)
#          |           |
#           \         /
#            v       v
#            gemm(Cl0)
chip2_cluster0_core0_gemm = BingoNode(assigned_chiplet_id=2,
                                      assigned_cluster_id=0,
                                      assigned_core_id=0, node_name="chip2_cluster0_core0_gemm")
chip2_cluster0_core1_dma = BingoNode(assigned_chiplet_id=2,
                                     assigned_cluster_id=0,
                                     assigned_core_id=1, node_name="chip2_cluster0_core1_dma")
chip2_cluster1_core1_dma = BingoNode(assigned_chiplet_id=2,
                                     assigned_cluster_id=1,
                                     assigned_core_id=1, node_name="chip2_cluster1_core1_dma")
chip2_cluster0_core0_gemm_2 = BingoNode(assigned_chiplet_id=2,
                                        assigned_cluster_id=0,
                                        assigned_core_id=0, node_name="chip2_cluster0_core0_gemm_2")
bingo_dfg.bingo_add_node(chip2_cluster0_core0_gemm)
bingo_dfg.bingo_add_node(chip2_cluster0_core1_dma)
bingo_dfg.bingo_add_node(chip2_cluster1_core1_dma)
bingo_dfg.bingo_add_node(chip2_cluster0_core0_gemm_2)
bingo_dfg.bingo_add_edge(chip2_cluster0_core0_gemm, chip2_cluster0_core1_dma)
bingo_dfg.bingo_add_edge(chip2_cluster0_core0_gemm, chip2_cluster1_core1_dma)
bingo_dfg.bingo_add_edge(chip2_cluster0_core1_dma, chip2_cluster0_core0_gemm_2)
bingo_dfg.bingo_add_edge(chip2_cluster1_core1_dma, chip2_cluster0_core0_gemm_2)
# The upper part is similar to chiplet 1's example
# We need to create a dummy node after the gemm(cl0) node to set the depdencies for both dma tasks
#            gemm(Cl0)
#           /         \\
#          |           || 
#          |           ||      
#          v           vv  
#         dma(Cl0)    dummy dep set gemm task(Cl1)
#                      |
#                      v
#                    dma(Cl1)
#
# But if we look at the lower part
#         dma(Cl0)    dma(Cl1)
#          |           |
#           \         /
#            v       v
#            gemm(Cl0)
# Again we have a problem since the gemm(cl0) task has two dependencies from the same type of tasks (dma) but from different clusters
# The dep matrix of Cl0 cannot distinguish which dma task is from which cluster
# Cl0 Dep Matrix:      
#        gemm dma simd
#   gemm       x        <- gemm(Cl0) will check whether this field is set by its predecessors, but both dma tasks set this field
#   dma
#   simd
# To solve this problem, we need to create another dummy task before the gemm(Cl0) task to separate the two dma dependencies
#         dma(Cl0)                    dma(Cl1)
#          |                            |
#          v                            |
#         dummy dep check gemm(Cl0)     |   Similary, the doulbe line here is a fake edge that can be described by the FIFO Queue
#          ||                          /    we need to create a dummy dep check gemm task to separate the two dma dependencies
#          ||     ____________________/
#          ||     |
#          vv     v             
#         gemm(Cl0)
#
#                      | FIFO IN
#                      v
#                 ----------------------------
#                 |                           |
#   GeMM          |  gemm(Cl0)                | <------ dma(Cl1) will set this
#  Wait Check     |                           |
#   Queue         |                           |
#                 |  dummy dep check gemm(Cl0)| <----- dma(Cl0) will set this
#                 -----------------------------
#                      |
#                      v FIFO OUT
# Even though the dma(Cl1) might finish earlier than dma(Cl0), the gemm(Cl0) is blocked by the dummy dep check gemm(Cl0) task
# So the correctness is still guaranteed
# -----------------------------
# Chiplet 3's tasks
# -----------------------------
#             ------gemm(Cl0)------
#           /          |          |
#          |           |          |
#          v           v          v
#         dma(Cl0)    dma(Cl1)   simd(Cl0)
#          |           |          |
#           \         /           |
#            v       v            |
#            gemm(Cl0)<------------
chip3_cluster0_core0_gemm_1 = BingoNode(assigned_chiplet_id=3,
                                        assigned_cluster_id=0,
                                        assigned_core_id=0, node_name="chip3_cluster0_core0_gemm_1")
chip3_cluster0_core1_dma = BingoNode(assigned_chiplet_id=3,
                                     assigned_cluster_id=0,
                                     assigned_core_id=1, node_name="chip3_cluster0_core1_dma")
chip3_cluster1_core1_dma = BingoNode(assigned_chiplet_id=3,
                                     assigned_cluster_id=1,
                                     assigned_core_id=1, node_name="chip3_cluster1_core1_dma")
chip3_cluster0_core2_simd = BingoNode(assigned_chiplet_id=3,
                                        assigned_cluster_id=0,
                                        assigned_core_id=2, node_name="chip3_cluster0_core2_simd")
chip3_cluster0_core0_gemm_2 = BingoNode(assigned_chiplet_id=3,
                                        assigned_cluster_id=0,
                                        assigned_core_id=0, node_name="chip3_cluster0_core0_gemm_2")
bingo_dfg.bingo_add_node(chip3_cluster0_core0_gemm_1)
bingo_dfg.bingo_add_node(chip3_cluster0_core1_dma)
bingo_dfg.bingo_add_node(chip3_cluster1_core1_dma)
bingo_dfg.bingo_add_node(chip3_cluster0_core2_simd)
bingo_dfg.bingo_add_node(chip3_cluster0_core0_gemm_2)
bingo_dfg.bingo_add_edge(chip3_cluster0_core0_gemm_1, chip3_cluster0_core1_dma)
bingo_dfg.bingo_add_edge(chip3_cluster0_core0_gemm_1, chip3_cluster1_core1_dma)
bingo_dfg.bingo_add_edge(chip3_cluster0_core0_gemm_1, chip3_cluster0_core2_simd)
bingo_dfg.bingo_add_edge(chip3_cluster0_core1_dma, chip3_cluster0_core0_gemm_2)
bingo_dfg.bingo_add_edge(chip3_cluster1_core1_dma, chip3_cluster0_core0_gemm_2)
bingo_dfg.bingo_add_edge(chip3_cluster0_core2_simd, chip3_cluster0_core0_gemm_2)
# By iteratively applying the above strategies, we can correctly set the dependencies for all tasks in chiplet 3
#            gemm(Cl0)==================================
#           /         \\                                ||
#          |           ||                               ||
#          |           ||                               ||
#          v           vv                               vv
#         dma(Cl0)    dummy dep set gemm task(Cl1)   dummy dep set gemm task(Cl0)
#          |           |                                |
#          |           v                                |
#          |          dma(Cl1)                          v
#          |           |                              simd(Cl0)
#          |           |                                |
#          |           v                                |
#          |          dummy dep check gemm(Cl0)<------- | <- notice this edge, it means the dummy dep check gemm will be set by dma(Cl1) as well
#          |           ||                                    as other predecessors
#          |           vv                               
#          ---------->gemm(Cl0)
#
# -----------------------------
# Connect between the chiplets
# -----------------------------
bingo_dfg.bingo_add_edge(chip0_cluster0_core2_simd, chip1_cluster0_core2_simd)
bingo_dfg.bingo_add_edge(chip0_cluster0_core2_simd, chip2_cluster0_core0_gemm)
bingo_dfg.bingo_add_edge(chip1_cluster0_core0_gemm, chip3_cluster0_core0_gemm_1)
bingo_dfg.bingo_add_edge(chip2_cluster0_core0_gemm_2, chip3_cluster0_core0_gemm_1)
# Here we need to add the chiplet set/check tasks between the chiplets
# For each cross-chiplet edge, we need to add a dep set task on the source chiplet and a dep check task on the destination chiplet
#            chiplet0
#           /         \
#          |           |
#          v           v
#         chiplet1    chiplet2
#          |           |
#           \         /
#            v       v
#            chiplet3
# For each node, we first insert the dep set task after it
#            chiplet0
#               |
#          chiplet dep set(chiplet0)
#           /                \
#          |                  |
#          v                  v
#         chiplet1         chiplet2
#          |                  |
#  chiplet dep set(chiplet1)  chiplet dep set(chiplet2)
#           \                 /
#            v               v
#                 chiplet3
# Then we need to insert the dep check task before the destination node
#            chiplet0
#               |
#          chiplet dep set(chiplet0)
#           /                          \
#          |                            |
#          v                            v
#  chiplet dep check(chiplet1)   chiplet dep check(chiplet2)
#          |                            |
#          v                            v
#         chiplet1                   chiplet2
#          |                            |
#  chiplet dep set(chiplet1)  chiplet dep set(chiplet2)
#           \                           /
#            v                        v
#               chiplet dep check(chiplet3)
#                      |
#                      v
#                 chiplet3
bingo_dfg.bingo_visualize_dfg("original_dfg.png")

# Serialize producers that share a (consumer_core, producer_core) counter cell
# across multiple consumers, so each consumer drains exactly its own producers.
bingo_dfg.bingo_transform_dfg_serialize_shared_counter_consumers()
# Transform the DFG to add dummy set nodes
bingo_dfg.bingo_transform_dfg_add_dummy_set_nodes()
bingo_dfg.bingo_visualize_dfg("dfg_after_add_dummy_dep_set_nodes.png")
# Transform the DFG to add dummy check nodes
bingo_dfg.bingo_transform_dfg_add_dummy_check_nodes()
bingo_dfg.bingo_visualize_dfg("dfg_after_add_dummy_dep_check_nodes.png")
# Set the Dep Set and Dep Check for the normal nodes
bingo_dfg.bingo_assign_normal_node_dep_set_info()
bingo_dfg.bingo_assign_normal_node_dep_check_info()
print(bingo_dfg.bingo_emit_task_desc_sv())
print(bingo_dfg.bingo_emit_push_task_sv())
