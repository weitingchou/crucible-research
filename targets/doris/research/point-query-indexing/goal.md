---
allow_deploy_changes: false
auto_approve: true
---

# Point Query Performance Across Doris Index Types

## Context
Doris supports multiple indexing mechanisms that can accelerate different query
patterns. For point queries (single-row lookups by key), the choice of index and
table model can have dramatic performance implications. Doris offers:

- **Prefix/short key index** — built-in sparse index on the sort key prefix
  (first 36 bytes). Always present, no configuration needed.
- **Bloom filter index** — probabilistic filter for equality predicates on
  high-cardinality columns. Reduces disk I/O by skipping pages that definitely
  don't contain the target value.
- **Inverted index** — token-based index (since Doris 2.0) supporting equality,
  range, and text search. More precise than bloom filters but higher storage cost.
- **Short-circuit read + row store** — Doris 2.x optimization where point queries
  on UNIQUE key tables bypass the normal scan path entirely. Requires
  `"store_row_column" = "true"` and `"enable_unique_key_merge_on_write" = "true"`.

We want to determine which combination delivers the best point query latency and
throughput for a typical OLAP key-value lookup pattern.

## Engine
doris

## Hypothesis
The short-circuit read with row store optimization on a UNIQUE key (merge-on-write)
table will deliver the lowest point query latency — significantly faster than bloom
filter or inverted index approaches — because it avoids the columnar scan path
entirely. Bloom filter and inverted index will both improve over the no-index
baseline, with inverted index providing better precision at the cost of slightly
higher storage overhead.

## Metrics of Interest
- Point query latency (p50, p95, p99)
- Point query throughput (QPS)
- Storage size per table variant (to quantify index overhead)
- Cache hit rates (to understand if results are skewed by caching)
- BE CPU utilization per variant (to quantify compute cost per query)
- BE memory utilization per variant (to quantify memory pressure)

## Suggested Metrics
- cluster_qps: `doris_fe_qps{job="doris-fe"}`
- query_latency_p95: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.95"}`
- query_latency_p99: `doris_fe_query_latency_ms{job="doris-fe",quantile="0.99"}`
- be_cache_hit_ratio: `doris_be_cache_hit_ratio{job="doris-be"}`
- be_active_queries: `doris_be_query_ctx_cnt{job="doris-be"}`
- be_cpu_usage: `rate(process_cpu_seconds_total{job="doris-be"}[1m])`
- be_mem_bytes: `process_resident_memory_bytes{job="doris-be"}`
- be_mem_tracker: `doris_be_all_memtrackers_bytes{job="doris-be"}`

## Experiment Design
Create five variants of the `orders` table (1.5M rows from TPC-H SF1), each with a
different index configuration. Load the same data into all variants. Run identical
point query workloads against each.

### Table Variants

| Variant | Table Model | Key Columns | Index on `o_orderkey` | Special Properties |
|---------|-------------|-------------|----------------------|-------------------|
| A: baseline | DUPLICATE | o_orderkey | prefix index only (default) | — |
| B: bloom | DUPLICATE | o_orderkey | bloom filter index | `"bloom_filter_columns" = "o_orderkey"` |
| C: inverted | DUPLICATE | o_orderkey | inverted index | `INDEX idx_orderkey (o_orderkey) USING INVERTED` |
| D: unique-mow | UNIQUE (merge-on-write) | o_orderkey | prefix index | `"enable_unique_key_merge_on_write" = "true"` |
| E: unique-mow-rowstore | UNIQUE (merge-on-write) | o_orderkey | prefix index + row store | `"enable_unique_key_merge_on_write" = "true"`, `"store_row_column" = "true"` |

### Workload
Point queries selecting a single row by `o_orderkey`:
```sql
SELECT * FROM {table_variant} WHERE o_orderkey = {random_key};
```

Use random keys uniformly distributed across the 1.5M order key space.
Run at **concurrency 8** for **5 minutes** per variant.

### Setup Steps
1. Create all five table variants with appropriate DDL
2. Load `orders` data into each variant
3. Run `ANALYZE TABLE` on each to update statistics
4. Flush caches between variants to ensure fair comparison
5. Run the point query workload against each variant sequentially

## Constraints
- Use the existing TPC-H SF1 `orders` data (1.5M rows) — do not alter the source
- Create new table variants in the `tpch` database (do not modify the original `orders` table)
- Each variant must contain identical data for fair comparison
- Flush page cache / restart BE between variants to eliminate cache warmth bias,
  OR run a cold-start + warm-start sequence for each variant and report both
- Fixed concurrency of 8 VUs across all variants
- Fixed 5-minute duration per variant

## Success Criteria
- A comparison table showing p50, p95, p99 latency and QPS for all five variants
- Ranking of index strategies by point query performance
- Quantified speedup of each index type over the no-index baseline
- Storage overhead of each index type (table size in bytes)
- CPU and memory cost per variant — is the fastest index also the most resource-hungry?
- Efficiency metric: QPS-per-CPU-core and latency-per-MB-memory for each variant
- Whether the short-circuit read + row store optimization lives up to its promise
- Recommendation that weighs latency gains against resource (CPU, memory, storage) costs
