---
name: research
description: |
  Run autonomous database performance research from a goal file.
  Use when the user invokes /research with a path to a goal.md under
  targets/{engine}/research/{goal}/. Executes the full loop: read goal,
  plan experiments, submit test runs via Crucible MCP, collect results,
  analyze, iterate, and produce a final report.
argument-hint: targets/{engine}/research/{goal}/goal.md
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent
effort: high
---

# Autonomous Research Protocol

You are conducting a database performance research investigation defined
by the goal file at `$ARGUMENTS`. Follow this protocol precisely.

---

## Crucible Test Model

Understand how Crucible structures test execution before planning experiments:

- A **test plan** = **test environment** + **test workload**.
- The **test environment** is the SUT deployed by this project (Helm charts,
  resource limits, configs). It is described in the test plan YAML under
  `test_environment`.
- The **test workload** (SQL queries, concurrency, duration) must be **uploaded
  to Crucible** via `mcp__crucible__upload_workload_sql`, then referenced in
  the test plan YAML under `execution.workload`.
- A test plan is uploaded once. You can then **submit multiple test runs**
  against the same plan. All runs inherit the plan's `run_label`.

### When to create multiple test plans vs. multiple runs

| What varies between experiments | Action |
|---|---|
| **Workload** (different queries, concurrency, duration) | Create a **new test plan** with its own workload upload |
| **Engine spec** (memory, replicas, config flags) | Reuse the **same test plan**, submit a **new run** with different spec info at submission time |
| **Both** | Create multiple test plans (one per workload) × submit multiple runs per plan (one per spec) |

The spec info (resource limits, config changes, etc.) is provided when triggering
a test run via `mcp__crucible__submit_test_run`, so you do not need to re-upload
the plan just because the engine configuration changed.

### Observability in test plans

Crucible can collect Prometheus metrics from the target engine during the test run
automatically. You do **not** need to query Prometheus yourself. Instead, define an
`observability` block in the test plan YAML:

```yaml
test_environment:
  # ... connection details ...
  observability:
    prometheus_sources:
      - name: engine
        url: "http://<prometheus-service>.<namespace>.svc.cluster.local:9090"
        metrics:
          - name: "<metric_label>"
            query: "<PromQL expression>"
        resolution: 15        # optional, seconds between samples (default: 15)
        max_data_points: 500   # optional (default: 500)
```

When the test run completes, the result JSON returned by the Crucible MCP contains
both k6 load test results and the collected Prometheus metrics.

**Choosing metrics:** Based on the research goal's hypothesis and metrics of
interest, select PromQL queries that will provide insight. If the goal file
includes a `suggested_metrics` section, use those as a starting point. Otherwise,
determine the right metrics by reading the engine documentation and understanding
what internal counters are relevant to the hypothesis. For example:

- Query performance → query latency histograms, QPS counters
- Memory pressure → memory usage, cache hit rates, spill counters
- I/O behavior → disk read/write throughput, compaction stats
- Concurrency → thread pool utilization, connection counts

---

## Phase 1: Understand

1. **Read the goal file** (`$ARGUMENTS`) in full.
2. **Identify the key elements:**
   - `Engine` — which target database (determines deploy config, fixtures, connection details)
   - `Context` — background that motivates the investigation
   - `Hypothesis` — the specific claim to prove or disprove
   - `Metrics of Interest` — what to measure (latency, throughput, memory, etc.)
   - `Suggested Metrics` — optional PromQL queries the author recommends; use
     these as a starting point but add others if needed for the hypothesis
   - `Experiment Design` — the human's suggested approach (follow it unless clearly flawed)
   - `Constraints` — hard boundaries on what you may and may not do
   - `Success Criteria` — what the final report must answer
   - `allow_deploy_changes` — whether you are permitted to modify the SUT deployment
     (Helm values, resource limits, replica counts). Defaults to `false` if absent.
3. **Check for a `## Feedback` section.** If present, this is a follow-up iteration:
   - Read the existing `results.yaml` and `report.md` in the same folder.
   - Understand what was already tested and what gaps the feedback identifies.
   - Plan only the follow-up experiments needed to address the feedback.
4. **Read the engine's deploy config and fixtures** to understand the current SUT
   state (version, resource limits, loaded datasets, connection details).
5. **Determine the Prometheus metrics** to include in test plans:
   - Start with any `suggested_metrics` from the goal file.
   - Add metrics that are relevant to the hypothesis based on engine knowledge.
   - Read engine documentation or existing deploy configs to find available
     metric names and label conventions.
   - Locate the Prometheus service URL from the infra deployment
     (e.g., `infra/helm/prometheus/values.yaml`).

---

## Phase 2: Plan

1. **Design a set of experiments** that systematically address the hypothesis.
   Each experiment should vary one parameter at a time unless the goal explicitly
   calls for combinatorial testing.
2. **Identify the experiment axes:**
   - **Workload axis** — which queries, concurrency levels, and durations to test.
     Each distinct workload requires its own test plan YAML and workload upload.
   - **Spec axis** — which engine configurations to test (memory, replicas, flags).
     These are passed at run submission time and reuse the same uploaded plan.
   - Map out the full matrix: `workloads × specs = total runs`.
3. **For each experiment, define:**
   - A short description (what it tests and why)
   - Which test plan it uses (new or existing)
   - Which spec overrides to pass at submission (if any)
   - Which Prometheus metrics to collect (included in the plan's observability block)
   - What outcome would confirm or reject the hypothesis
4. **Write the experiment plan as a summary** to the user before executing.
   Wait for approval unless the goal file contains `auto_approve: true`.

---

## Phase 3: Execute

### 3a. Prepare workloads and plans

- For each distinct workload in the experiment plan:
  1. Upload the workload SQL via `mcp__crucible__upload_workload_sql`.
  2. Create a test plan YAML in the `plans/` subfolder of the research goal
     directory. Name it descriptively (e.g., `q9-q21-c4.yaml`).
  3. Set `run_label` to the goal folder name (e.g., `join-spill-analysis`).
  4. Include the `observability.prometheus_sources` block with the metrics
     determined in Phase 1.
  5. Validate via `mcp__crucible__validate_test_plan`.

### 3b. Submit runs

- For each experiment (plan × spec combination):
  1. If the experiment requires deployment changes, verify
     `allow_deploy_changes: true` in the goal file. Apply changes via Helm
     upgrade and wait for pods to be ready.
  2. Submit the test run via `mcp__crucible__submit_test_run`, passing any
     spec overrides. Record the `run_id` immediately.

### 3c. Monitor

- Poll `mcp__crucible__monitor_test_progress` until status is `COMPLETED` or `FAILED`.
- If `FAILED`, log the error in results.yaml and decide:
  - Transient failure (timeout, worker crash) → retry once.
  - Configuration error → fix the plan and resubmit.
  - Fundamental issue → log as failed, skip, and continue.

### 3d. Collect

- Retrieve the test run results via the Crucible MCP result tool.
- The response JSON contains both **k6 load test metrics** (latency percentiles,
  TPS, error rates) and **Prometheus metrics** (as defined in the plan's
  observability block).
- Extract the metrics of interest from the response.

### 3e. Log

- Append the experiment to `results.yaml` in the research goal directory.
- Use this structure:

```yaml
experiments:
  - run_id: "<uuid>"
    run_label: "<goal-folder-name>"
    timestamp: "<ISO 8601>"
    description: "<what this experiment tests>"
    plan_file: "plans/<filename>.yaml"
    parameters:
      concurrency: N
      queries: [Q1, Q2]
      hold_for: "120s"
    spec_overrides:
      # only present if engine spec was changed for this run
      be.resources.limits.memory: "8Gi"
    status: completed | failed | skipped
    error: "<error message if failed>"
    results:
      k6:
        # key k6 metrics
        p99_latency_ms: 342
        tps: 120
        error_rate: 0.0
      prometheus:
        # metrics from observability block
        cluster_qps: 145
        avg_memory_bytes: 2147483648
    notes: "<any observations or anomalies>"
```

---

## Phase 4: Analyze

After all planned experiments complete:

1. **Compare results across experiments.** Look for:
   - Trends (does latency grow linearly or exponentially with concurrency?)
   - Thresholds (at what point does behavior change?)
   - Anomalies (unexpected spikes, errors, or plateaus)
2. **Check against the hypothesis.** Is there enough evidence to confirm or reject it?
3. **Decide whether to iterate:**
   - If the data is inconclusive, design follow-up experiments targeting the gap.
     Append them to results.yaml and loop back to Phase 3.
   - If the hypothesis is answered, proceed to Phase 5.
   - Maximum 3 iteration rounds unless the goal file specifies otherwise.

---

## Phase 5: Report

Generate `report.md` in the research goal directory with this structure:

```markdown
# {Title from goal.md}

## Summary
[2-3 sentences directly answering the hypothesis]

## Methodology
- Engine: {name, version, resource config}
- Dataset: {name, scale factor}
- Queries: {which queries were tested}
- Parameters varied: {what changed across experiments}
- Duration per experiment: {hold_for value}
- Run label: {goal-folder-name}
- Prometheus metrics collected: {list of metric names}

## Findings

### {Finding 1 Title}
[Data-backed finding with specific numbers]

### {Finding 2 Title}
[Data-backed finding with specific numbers]

[Include tables comparing metrics across experiments where appropriate]

| Parameter | Metric A | Metric B | Metric C |
|-----------|----------|----------|----------|
| value 1   | ...      | ...      | ...      |
| value 2   | ...      | ...      | ...      |

## Conclusions
[Direct answers to each item in the Success Criteria from goal.md]

## Limitations
[What this investigation did NOT cover; caveats on the results]

## Appendix
- Research goal: {relative path to goal.md}
- Experiment log: {relative path to results.yaml}
- Test plans: {relative path to plans/}
- Crucible run IDs: [list of all run_ids]
```

---

## Phase 6: Wrap Up

1. Verify the report answers every item in the Success Criteria.
2. Inform the user that the report is ready for review.
3. If the user provides feedback, append it to the `## Feedback` section of
   `goal.md` with a date stamp, then re-enter the loop at Phase 1 step 3.

---

## Rules

- **Do not modify the SUT deployment** unless `allow_deploy_changes: true` is
  set in the goal file. If a deployment change is needed but not permitted,
  ask the user to update the goal file.
- **Do not modify fixtures or loaded data** unless the goal file explicitly permits it.
- **Log every run** — even failures. The results.yaml must be a complete record.
- **One variable at a time** — unless the goal calls for combinatorial testing.
- **Respect constraints** in the goal file. If it says "max 5 experiments", stop at 5.
- **Use the goal folder name as the run_label** for all test submissions, so runs
  are grouped and queryable via Crucible MCP.
- **Reuse uploaded plans** when only engine spec varies between runs. Create a new
  plan only when the workload itself changes (different queries, concurrency, duration).
- **Be honest in the report.** If the data doesn't support the hypothesis, say so.
  A null result is still a result.
- **Restore deployment changes** after the investigation completes. If you modified
  Helm values for an experiment, revert to the original configuration unless the
  goal file says otherwise.
