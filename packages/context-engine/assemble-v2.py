#!/usr/bin/env python3
"""
Context Assembler v2 — 只读组合，不覆写持久文件。

读取:
  ~/.xianqin/context/{GID}/*.json  (持久文件，各自维护)
  MC API                            (实时舰队状态)

写入:
  ~/.xianqin/context/{GID}/prefill.json  (prefill JSON 数组)
  ~/.xianqin/context/{GID}/fleet-snapshot.json (瞬态，可覆写)

用法:
  MC_API_KEY=xxx python3 assemble-v2.py 105
"""

import json, os, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

# ─── Config ───
MC_URL = os.environ.get("MC_URL", "http://localhost:3000")
MC_API_KEY = os.environ.get("MC_API_KEY", "")
CONTEXT_HOME = Path(os.environ.get("CONTEXT_HOME", os.path.expanduser("~/.xianqin/context")))

GID_TO_DBID = {"101":"10","102":"4","103":"5","104":"6","105":"18","106":"19","107":"20","108":"21"}
AGENT_NAMES = {"101":"相邦","102":"白起","103":"王翦","104":"丞相","105":"萱萱","106":"俊秀","107":"雪莹","108":"红婳"}


def mc(path: str) -> dict:
    """Call MC API."""
    try:
        r = subprocess.run(
            ["curl", "-sf", "-m", "5", "-H", f"x-api-key: {MC_API_KEY}", f"{MC_URL}{path}"],
            capture_output=True, text=True, timeout=10
        )
        return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}
    except Exception:
        return {}


def read_json(path: Path) -> dict:
    """Read a JSON file, return empty dict if missing."""
    try:
        return json.loads(path.read_text()) if path.exists() else {}
    except Exception:
        return {}


def get_fleet_snapshot() -> dict:
    """Get real-time fleet status from MC."""
    data = mc("/api/agents")
    agents = data.get("agents", [])
    now = datetime.now()
    snapshot = {"updated": now.isoformat(), "agents": {}}
    for a in agents:
        gid = str(a.get("global_id", "?"))
        ls = a.get("last_seen", 0)
        secs = int(now.timestamp() - ls) if ls else 9999
        snapshot["agents"][gid] = {
            "name": a.get("name", AGENT_NAMES.get(gid, "?")),
            "status": a.get("status", "?"),
            "alive": secs < 600,
            "secs_ago": secs,
        }
    return snapshot


def get_my_tasks(gid: str) -> list:
    """Get inbox and active tasks for this agent."""
    dbid = GID_TO_DBID.get(gid, gid)
    # Inbox
    data = mc(f"/api/tasks?assigned_to={dbid}&status=inbox&limit=5")
    tasks = data if isinstance(data, list) else data.get("tasks", [])
    inbox = [{"id": t["id"], "title": t.get("title","")[:80]} for t in tasks if t.get("status") == "inbox"]
    # Active
    data2 = mc(f"/api/tasks?assigned_to={dbid}&limit=5")
    tasks2 = data2 if isinstance(data2, list) else data2.get("tasks", [])
    active = [{"id": t["id"], "title": t.get("title","")[:80], "status": t.get("status","?")}
              for t in tasks2 if t.get("status") in ("in_progress", "review")]
    return {"inbox": inbox, "active": active}


def get_relevant_tasks(gid: str, fleet_graph: dict) -> list:
    """Get tasks from agents relevant to me.
    
    Orchestrator pattern (相邦): all managed agents are downstream.
    Worker pattern (萱萱): only upstream agents (those I depend on).
    """
    agents = fleet_graph.get("agents", {})
    my_info = agents.get(gid, {})
    
    # Determine pattern: if I manage others → orchestrator
    managed = [agid for agid, info in agents.items()
               if info.get("managed") and agid != gid]
    upstream_gids = [agid for agid, info in agents.items()
                     if info.get("upstream") and agid != gid]
    
    if managed:
        # Orchestrator: show all managed agents
        target_gids = managed
        label = "下游 (我管理的 agent)"
    elif upstream_gids:
        # Worker: show upstream dependencies
        target_gids = upstream_gids
        label = "上游依赖 (我需要他们的产出)"
    else:
        return [], ""
    
    tasks = []
    for agid in target_gids:
        dbid = GID_TO_DBID.get(agid)
        if not dbid:
            continue
        data = mc(f"/api/tasks?assigned_to={dbid}&limit=3")
        task_list = data if isinstance(data, list) else data.get("tasks", [])
        for t in task_list:
            if t.get("status") in ("in_progress", "review"):
                info = agents.get(agid, {})
                tasks.append({
                    "agent": info.get("name", agid),
                    "id": t["id"],
                    "title": t.get("title", "")[:60],
                    "status": t.get("status", "?"),
                })
    return tasks, label


def assemble(gid: str) -> str:
    """Assemble prefill JSON from component files + MC."""
    ctx_dir = CONTEXT_HOME / gid
    ctx_dir.mkdir(parents=True, exist_ok=True)

    # ─── Read persistent files (READ ONLY) ───
    identity = read_json(ctx_dir / "identity.json")
    memory = read_json(ctx_dir / "memory.json")
    plantree = read_json(ctx_dir / "plantree.json")
    focus = read_json(ctx_dir / "focus.json")
    fleet_graph = read_json(ctx_dir / "fleet-graph.json")

    # ─── Fetch live data from MC ───
    snapshot = get_fleet_snapshot()
    my_tasks = get_my_tasks(gid)
    relevant_tasks, relevant_label = get_relevant_tasks(gid, fleet_graph)

    # ─── Write fleet-snapshot (transient, overwrite OK) ───
    (ctx_dir / "fleet-snapshot.json").write_text(json.dumps(snapshot, ensure_ascii=False, indent=2))

    # ─── Build context blocks ───
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    name = identity.get("agent", AGENT_NAMES.get(gid, f"Agent-{gid}"))

    # Fleet status summary
    alive = [f"{info['name']}" for g, info in snapshot.get("agents", {}).items()
             if info["alive"] and g != gid]
    offline = [f"{info['name']}({info['secs_ago']}s)" for g, info in snapshot.get("agents", {}).items()
               if not info["alive"] and g != gid]

    # My tasks
    my_inbox = "\n".join(f"  T{t['id']}: {t['title']}" for t in my_tasks.get("inbox", [])) or "  无"
    my_active = "\n".join(f"  T{t['id']} [{t['status']}]: {t['title']}" for t in my_tasks.get("active", [])) or "  无"

    # Upstream / downstream tasks
    up_lines = "\n".join(f"  {u['agent']}: T{u['id']} [{u['status']}] {u['title'][:50]}" for u in relevant_tasks) or "  无"

    # Memory entries (last N)
    mem_entries = memory.get("entries", [])[-15:]
    mem_text = "\n".join(f"§ {e}" for e in mem_entries)

    # PlanTree
    pt_lines = plantree.get("active_lines", [])
    pt_text = "\n".join(f"  • {l}" for l in pt_lines[-10:])

    # Focus
    watching = "\n".join(f"  👁 {w}" for w in focus.get("watching", [])[-5:])
    active_f = "\n".join(f"  ▶ {a}" for a in focus.get("active", [])[-5:])
    pending = "\n".join(f"  ⏳ {p}" for p in focus.get("pending", [])[-5:])

    content = f"""# {name} Context — {now}
Agent GID={gid} | 仙秦帝国舰队 | 上下文引擎 v2

## 舰队状态
  在线: {', '.join(alive) if alive else '—'}
  {"离线: " + ', '.join(offline) if offline else ''}

## 我的任务
  待领取:
{my_inbox}
  进行中:
{my_active}

## {relevant_label}
{up_lines}

## 持久记忆
{mem_text}

## Plan-Tree 活跃线
{pt_text}

## 当前关注
{watching}
{active_f}
{pending}

---
> 上下文引擎 v2: 组装器只读。各组件独立维护，防覆写。"""

    # ─── Build prefill JSON array ───
    prefill = [{"role": "system", "content": content}]

    # Atomic write: temp → rename
    tmp = ctx_dir / ".prefill.json.tmp"
    dst = ctx_dir / "prefill.json"
    tmp.write_text(json.dumps(prefill, ensure_ascii=False, indent=2))
    tmp.rename(dst)

    # Also write a human-readable markdown version for debugging
    (ctx_dir / "context-pack.md").write_text(content)

    return str(dst)


if __name__ == "__main__":
    gid = sys.argv[1] if len(sys.argv) > 1 else "105"
    result = assemble(gid)
    print(f"✅ {result}")
