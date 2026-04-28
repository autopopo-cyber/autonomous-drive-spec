# Agent Kit

> **Everything a single AI agent needs to work autonomously.**
> Plan-Tree for memory, mc-poll for task execution, heartbeat for health, cron for rhythm.

## 🎯 What It Is

Agent Kit is the **per-agent toolkit** — the software every agent in the fleet runs independently. It pairs with [Fleet MC](https://github.com/autopopo-cyber/fleet-mc) (organization layer) and [LLM Wiki](https://github.com/autopopo-cyber/llm-wiki) (knowledge base) to form the three pillars of the agent fleet.

```
┌─────────────┐  ┌──────────┐  ┌──────────┐
│  agent-kit  │  │ fleet-mc │  │ llm-wiki │
│ (per-agent) │  │  (fleet) │  │  (brain) │
└──────┬──────┘  └────┬─────┘  └────┬─────┘
       │              │             │
   每个Agent      组织协调       知识积累
   独立运行      任务编排       哲学基础
```

## 📦 What's Inside

| Component | File | Purpose |
|-----------|------|---------|
| **Plan-Tree** | `plan-tree/v3-template.md` `v4-template.md` | Living memory with timestamps — each branch knows when it was last touched. v4 adds OODA decision points. |
| **Task Poll** | `scripts/mc-poll.py` `mc-poll.sh` | Polls Fleet MC for assigned tasks → executes via Hermes → submits to review. Anti-hallucination: verifies artifact before marking complete. |
| **QA Audit** | `scripts/qa-poll.py` `qa-poll.sh` | QA agents pick up review tasks → 5-step audit checklist → approve or reject. |
| **Heartbeat** | `scripts/heartbeat.sh` | 30-second health ping to Fleet MC. |
| **Cron Template** | `cron/example-crontab.txt` | Ready-to-use crontab with staggered offsets for 8 agents. |
| **Hermes Profiles** | `profiles/` | Example SOUL.md + config.yaml for persona agents. |
| **Idle Loop** | `SKILL.md` | Survival drive — when idle, agent self-improves instead of waiting. |

## 🚀 Quick Start

### 1. Clone & Install

```bash
git clone https://github.com/autopopo-cyber/agent-kit.git ~/.xianqin/
```

### 2. Set Your Agent ID

```bash
export MC_AGENT_GLOBAL_ID=102  # Your agent's unique ID (101-108)
```

### 3. Start the Poll Loop

```bash
# Developer loop: picks up in_progress tasks, executes, submits to review
MC_URL=http://YOUR_MC:3000 MC_AGENT_GLOBAL_ID=102 MC_API_KEY=your_key \
  bash ~/.xianqin/mc/mc-poll.sh
```

### 4. Add to Cron

See `cron/example-crontab.txt` for ready-to-use crontab entries.

## 🔄 Task Lifecycle

```
assigned → in_progress → review → done
   (MC)     (mc-poll)   (mc-poll)  (qa-poll)
                            │
                       QA 5-step audit
                       → done or rejected
```

## 🛡️ Anti-Hallucination Design

The agent does not self-report completion. The script verifies:

- **Developer**: result file exists and is non-empty before marking `review`
- **QA**: audit file contains ≥3 PASS/FAIL checks before marking `done`
- **Supervisor**: git commits and QA files verified against MC status

[Read the full design doc](https://github.com/autopopo-cyber/llm-wiki/blob/main/仙秦帝国/反幻觉设计原则.md)

## 🧠 Plan-Tree v4

Four-dimensional time-space prediction with OODA decision points:

```
流入 → 转化 → 流出 → 5关联 → NOW → 多分支预测
                                   └── 决策点(分叉A/B→选择→推理→放弃理由)
```

See `plan-tree/v4-template.md` and `docs/plan-tree-v4-spec.md`.

## 🏗️ Architecture

```
cron (every 10 min)
  └→ mc-poll.sh
       ├→ mc-poll.py  → GET /api/tasks?assigned_to={GID}&status=in_progress
       ├→ hermes chat → execute task
       ├→ artifact check → result file exists?
       └→ PUT /api/tasks/{id} {status:"review"}

cron (every 10 min, QA agents)
  └→ qa-poll.sh
       ├→ qa-poll.py  → GET /api/tasks?status=review
       ├→ hermes chat → 5-step audit
       ├→ artifact check → audit file has ≥3 PASS/FAIL?
       └→ PUT done or PUT back to in_progress
```

## 📋 Requirements

- **Hermes Agent CLI** — `hermes chat --yolo`
- **Fleet MC** — task API on port 3000
- **Cron** — for autonomous execution rhythm
- **Python 3** — for poll scripts
- **Git** — for code commits and artifact verification

## 🔗 Related

- [Fleet MC](https://github.com/autopopo-cyber/fleet-mc) — Multi-agent orchestration
- [LLM Wiki](https://github.com/autopopo-cyber/llm-wiki) — Fleet knowledge base
- [Development Workflow](https://github.com/autopopo-cyber/llm-wiki/blob/main/仙秦帝国/软件开发流程.md) — Full dev→QA pipeline

---

*Agent Kit — the per-agent pillar of the three-pillar fleet architecture.*
