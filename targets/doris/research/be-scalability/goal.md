---
allow_deploy_changes: true
auto_approve: true
---

# BE Horizontal Scalability Under TPC-H Workload

## Context
Our prior CPU concurrency research showed that a single 2-CPU BE node saturates at
~99% CPU with just 4 concurrent queries, capping throughput at ~13 QPS. The natural
follow-up is: does adding more BE nodes proportionally increase throughput? Doris
distributes query fragments across BEs, so in theory throughput should scale with
BE count — but coordination overhead, FE bottlenecks, or data skew could limit
actual gains.

The EKS cluster has 3 × c7i-flex.2xlarge nodes (8 vCPU, 16 GiB each), providing
enough capacity for up to 4 BE replicas at the current per-BE spec.

## Engine
doris

## Hypothesis
Query throughput (QPS) scales linearly with the number of BE nodes at a fixed
concurrency level. Specifically, 2 BE should deliver ~2× the QPS of 1 BE, and
4 BE should deliver ~4×, while per-query latency decreases proportionally. We
expect diminishing returns at some point due to FE coordination overhead or
network serialization.

## Metrics of Interest
- Query throughput (QPS) at each BE count
- Query latency distribution (p50, p95, p99) at each BE count
- Per-BE CPU utilization (to confirm load is distributed evenly)
- FE CPU utilization (to detect FE becoming the bottleneck)
- Per-BE tablet count (to confirm data is balanced after rebalancing)

## Suggested Metrics
- cluster_qps: `doris_fe_qps{job="doris-fe"}`
- query_latency_p95: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.95"}`
- query_latency_p99: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.99"}`
- be_cpu_usage_pct: `100 - avg by (instance)(rate(doris_be_cpu{job="doris-be",device="cpu",mode="idle"}[1m]))`
- be_active_queries: `doris_be_query_ctx_cnt{job="doris-be"}`
- be_load_average: `doris_be_load_average{job="doris-be"}`
- wg_cpu_time_rate: `rate(doris_be_workload_group_cpu_time_sec{job="doris-be"}[1m])`

## Experiment Design
Run the same TPC-H SF1 workload at a fixed concurrency of **8 VUs** (enough to
saturate 1 BE based on prior research) against three BE configurations:

| Config | BE Replicas | FE Replicas | Per-BE Spec |
|--------|-------------|-------------|-------------|
| 1x     | 1           | 1           | 500m/2 CPU, 2Gi/4Gi |
| 2x     | 2           | 1           | 500m/2 CPU, 2Gi/4Gi |
| 4x     | 4           | 1           | 500m/2 CPU, 2Gi/4Gi |

Each configuration runs for **5 minutes** (`hold_for: 300s`) with no ramp-up.

Between configurations:
1. Scale BE replicas via `helm upgrade`
2. Wait for all new BEs to register and become Alive
3. Wait for tablet rebalancing to complete (check via `SHOW BACKENDS` TabletNum)
4. Run the experiment

## Constraints
- Use the existing TPC-H SF1 dataset — do not reload or alter data
- Keep FE at 1 replica throughout (isolate BE scaling effect)
- Use identical per-BE resource spec across all configurations
- Fixed concurrency of 8 VUs for all runs
- Each run must be at least 5 minutes for steady-state metrics
- Verify tablet distribution is balanced before each run

## Success Criteria
- A table showing QPS, p95, and p99 latency at each BE count (1, 2, 4)
- Whether throughput scales linearly, sub-linearly, or not at all with BE count
- Per-BE CPU utilization at each config (confirms load distribution)
- Identification of any bottleneck that prevents linear scaling (FE CPU, network, data skew)
- Quantified scaling efficiency: actual speedup vs ideal speedup at each step
