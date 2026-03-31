# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository is the central hub for performance analysis and benchmarking of databases tested by the Crucible platform. It hosts analytical tools, Jupyter notebooks, deployment scripts for Systems Under Test (SUTs), and Markdown insight reports documenting system behavior under severe load.

## Architecture

The repo enforces strict separation between shared analytical tools and engine-specific evaluations:

- **`analysis/`** — Engine-agnostic shared tooling
  - `parsers/` — Python scripts to parse raw k6 CSVs and Prometheus metrics from the `project-crucible-storage` S3 bucket
  - `notebooks/` — Reusable Jupyter notebooks for cross-engine visualization (percentiles, TPS, error rates)
  - `requirements.txt` — Python dependencies (pandas, matplotlib, jupyter, etc.)

- **`infra/`** — Shared infrastructure deployments (not engine-specific)
  - `helm/prometheus/` — Prometheus Helm chart for SUT metrics collection

- **`targets/{engine}/`** — Fully self-contained per-SUT directories (e.g., `doris/`, `trino/`)
  - `deploy/` — Helm charts for reproducible SUT provisioning
  - `fixtures/` — **Shared** data generation configs, DDLs, and workload SQL reusable across research topics
  - `research/{goal}/` — Self-contained research investigations (see Research Convention below)
    - `goal.md` — Human-authored research goal and hypothesis
    - `fixtures/` — **Research-specific** scripts, DDLs, and workloads used only by this investigation
    - `plans/` — Crucible test plan YAMLs generated during the investigation
    - `results.yaml` — Structured log of every experiment run
    - `report.md` — Final findings report (the core deliverable)

## Deploying Doris

```bash
# Install (from repo root)
helm install doris targets/doris/deploy/helm/doris -n doris --create-namespace

# Override replicas or resources for a lighter dev cluster
helm install doris targets/doris/deploy/helm/doris -n doris --create-namespace \
  --set fe.replicaCount=1 --set be.replicaCount=1

# Upgrade after values change
helm upgrade doris targets/doris/deploy/helm/doris -n doris

# Uninstall (PVCs are not deleted automatically)
helm uninstall doris -n doris
```

The chart deploys:
- **FE StatefulSet** — 3 replicas (1 leader + 2 followers), MySQL-compatible query on port `9030`, HTTP UI on `8030`
- **BE StatefulSet** — 3 replicas, registers with FE automatically via `FE_SERVERS` env var
- Headless services for stable DNS within each StatefulSet, plus a client-facing FE service

## Workflow

1. **Deploy** — Provision SUTs via Helm charts in `targets/{engine}/deploy/`
2. **Research** — Define a goal in `targets/{engine}/research/{goal}/goal.md`, then invoke `/research` to run the autonomous investigation loop (see Research Convention below)
3. **Visualize & Explore** — Ingest raw Crucible telemetry using shared notebooks in `analysis/notebooks/`
4. **Review** — Read the generated `report.md` in the research goal folder; provide feedback to iterate

## Key Design Decisions

- Target isolation: each SUT's deploy configs, fixtures, and research investigations are co-located so findings stay coupled to their test parameters
- Analysis tooling is engine-agnostic because Crucible normalizes telemetry across all targets
- Helm is the first-priority deployment mechanism for reproducibility
- Research is goal-driven: each investigation is self-contained in its own folder with goal, plans, results, and report together

## Research Convention

### Overview

Research investigations are driven by goal files authored by humans. Claude autonomously
plans experiments, submits test runs via the Crucible MCP, collects results, analyzes them,
and produces a final report. The full protocol is defined in the `/research` skill
(`.claude/skills/research/SKILL.md`).

### Directory Structure

Each research goal lives in its own folder under `targets/{engine}/research/`:

```
targets/doris/
  fixtures/                    # shared across research topics
    tpch_ddl.sql               #   TPC-H schema DDL
    tpch_setup.sh              #   data generation and loading
    tpch_queries.sql           #   reference TPC-H queries
    tpch-sf1-workload.sql      #   Crucible workload format (all 22 queries)
  research/
    join-spill-analysis/
      goal.md                  # human-authored — context, hypothesis, success criteria
      fixtures/                # research-specific scripts (only used by this topic)
        create_variants.sql    #   example: custom table DDLs for this experiment
        point_query.sql        #   example: custom workload for this experiment
      plans/                   # auto-generated — Crucible test plan YAMLs
      results.yaml             # auto-generated — structured log of all experiment runs
      report.md                # auto-generated — final findings report
```

### Fixture Convention

Fixtures (DDLs, data loaders, workload SQL) follow a two-tier layout:

- **Shared fixtures** (`targets/{engine}/fixtures/`) — Reusable assets used by
  multiple research topics. Examples: TPC-H schema DDL, data loading scripts,
  standard workload SQL files.
- **Research-specific fixtures** (`targets/{engine}/research/{goal}/fixtures/`) —
  Scripts and SQL used only by a single investigation. Examples: custom table
  variants with specific index configurations, specialized point query workloads.

**Rule:** if a fixture is only used by one research topic, it belongs in that
topic's `fixtures/` subfolder. If it's reusable across topics, it goes in the
shared `fixtures/` directory.

### Goal File Template

Create `goal.md` with the following sections:

```markdown
---
allow_deploy_changes: false   # set true to permit SUT deployment modifications
                              # (Helm values, resource limits, replica counts)
auto_approve: false           # set true to skip approval before executing experiments
---

# {Title}

## Context
[Background that motivates the investigation]

## Engine
{engine name, e.g., doris}

## Hypothesis
[The specific claim to prove or disprove]

## Metrics of Interest
- {metric 1 — e.g., p99 query latency}
- {metric 2 — e.g., BE memory utilization}

## Suggested Metrics (optional)
[Specific PromQL queries the author recommends for the observability block]
- cluster_qps: `sum(rate(doris_be_query_total{job='doris-be'}[1m]))`
- avg_memory: `avg(doris_be_mem_usage_bytes{job='doris-be'})`

## Experiment Design
[Suggested approach — which parameters to vary, how many steps, etc.]

## Constraints
- {constraint 1}
- {constraint 2}

## Success Criteria
[What the final report must answer — bulleted list of specific questions]
```

### Running a Research Investigation

```
/research targets/doris/research/join-spill-analysis/goal.md
```

### Providing Feedback

If the report does not meet expectations, tell Claude the feedback directly.
Claude will append a `## Feedback` section to `goal.md` with a date stamp,
then re-run the loop targeting only the gaps identified in the feedback.
