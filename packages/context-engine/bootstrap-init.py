#!/usr/bin/env python3
"""
Bootstrap Init — 灌顶脚本：为新 agent 从 wiki 和 MC 提取初始 context。

用法: python3 bootstrap-init.py <GID> [--force]

读取:
  - MC API: agent SOUL, 当前任务
  - llm-wiki/仙秦帝国/: 舰队架构文档
  - wiki-5/: 萱萱的架构设计文档
  - repos/agent-kit/docs/: 工程文档

写入 ~/.xianqin/context/{GID}/:
  - identity.json    (从 MC SOUL 同步)
  - memory.json      (从 wiki 提取知识点)
  - plantree.json    (构造初始决策轨迹)
  - focus.json       (从 MC 任务推导当前关注)
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

# Wiki 路径（本机）
WIKI_ROOT = Path("/home/agentuser")
LLM_WIKI = WIKI_ROOT / "llm-wiki" / "仙秦帝国"
WIKI_5 = WIKI_ROOT / "wiki-5"
DOCS_DIR = WIKI_ROOT / "repos" / "agent-kit" / "docs"


def mc(path: str) -> dict:
    try:
        r = subprocess.run(
            ["curl", "-sf", "-m", "5", "-H", f"x-api-key: {MC_API_KEY}", f"{MC_URL}{path}"],
            capture_output=True, text=True, timeout=10
        )
        return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else {}
    except Exception:
        return {}


def read_file(path: Path) -> str:
    try:
        return path.read_text()[:5000]  # 只读前 5KB
    except Exception:
        return ""


def extract_knowledge(gid: str) -> list:
    """从 wiki 提取通用知识 + agent 特定知识."""
    entries = []

    # ─── 通用知识（所有 agent 共享）───
    # 舰队架构
    for fname in ["软件开发流程.md", "新我恢复指南.md"]:
        content = read_file(LLM_WIKI / fname)
        if content:
            for line in content.split("\n"):
                line = line.strip()
                if line.startswith("- ") or line.startswith("* "):
                    entries.append(f"舰队架构: {line.lstrip('- *').strip()[:120]}")
                if len(entries) > 30: break

    # Plan-Tree
    pt = read_file(WIKI_5 / "design-plantree-outline.md")
    if pt:
        entries.append("Plan-Tree v4: 四维时空预测模型(流入/转化/流出/关联/NOW)，决策点字段记录分叉选择理由")

    # Context 引擎
    ctx = read_file(WIKI_5 / "arch-context-engine-v2.md")
    if ctx:
        entries.append("Context引擎: 分文件持久化(identity/memory/plantree/focus/fleet-graph)，组装器只读，四层兜底(agent:end→agent:step→cron10min→原子写入)")
        entries.append("MC解耦: MC是分发平台不直接控制agent，agent自注册自拉任务自打卡")

    # 工程文档
    for fname in ["heartbeat-and-lock-architecture-v7.2.md", "ONBOARDING-GUIDE.md"]:
        content = read_file(DOCS_DIR / fname)
        if content:
            title = content.split("\n")[0].lstrip("#").strip()
            entries.append(f"工程文档-{fname}: {title[:100]}...")

    # mc-poll 机制
    entries.append("mc-poll v7.4: 心跳→锁检查→产物自检→拉任务→hermes执行(600s超时+看门狗)→验证→PlanTree增量")
    entries.append("GID→DBID映射: 同左。诊断文件: task-{id}-diagnostic.json。超时/卡住时自动写入。")

    # ─── Agent 特定知识 ───
    name = AGENT_NAMES.get(gid, f"Agent-{gid}")
    entries.append(f"我是{name}(GID={gid})，仙秦舰队成员。三层验证: 自检→QA审计→相邦监管。")
    entries.append(f"MC URL: {MC_URL}。上下文持久化于 ~/.xianqin/context/{gid}/。每次cron触发时刷新。")

    # 截断到 20 条
    return entries[:20]


def build_identity(gid: str) -> dict:
    """从 MC SOUL 同步角色定义."""
    data = mc("/api/agents")
    agents = data.get("agents", [])
    for a in agents:
        if str(a.get("global_id")) == gid:
            soul = a.get("soul_content", "") or ""
            # 提取关键字段
            name = a.get("name", AGENT_NAMES.get(gid, ""))
            role = a.get("role", "")
            rank = a.get("rank_title", "")
            score = a.get("rank_score", 0)
            # 从 SOUL 提取 description 第一行
            lines = soul.split("\n")
            desc = next((l.split(": ",1)[1] for l in lines if l.startswith("description:")), "")
            return {
                "agent": name,
                "gid": gid,
                "role": role,
                "specialty": desc[:120] if desc else role,
                "rank": rank,
                "score": score,
                "version": 2,
                "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
    # 回退
    return {"agent": AGENT_NAMES.get(gid), "gid": gid, "version": 2}


def build_plantree(gid: str) -> dict:
    """构造初始 PlanTree."""
    name = AGENT_NAMES.get(gid, f"Agent-{gid}")
    return {
        "version": 1,
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "decisions": [],
        "active_lines": [
            f"{name} 舰队日常运维",
            "执行 MC 任务 → 产出 → 更新 PlanTree",
            "学习 wiki → 积累经验 → 提升能力",
        ],
        "dependencies": {
            "upstream": {},
            "downstream": {},
        }
    }


def build_focus(gid: str) -> dict:
    """从 MC 任务推导当前关注."""
    dbid = GID_TO_DBID.get(gid, gid)
    data = mc(f"/api/tasks?assigned_to={dbid}&limit=8")
    tasks = data if isinstance(data, list) else data.get("tasks", [])

    watching = []
    active = []
    pending = []

    for t in tasks:
        s = t.get("status", "")
        title = t.get("title", "")[:60]
        if s in ("in_progress",):
            active.append(f"T{t['id']}: {title}")
        elif s in ("review",):
            watching.append(f"T{t['id']}: {title}")
        elif s in ("inbox", "assigned"):
            pending.append(f"T{t['id']}: {title}")

    return {
        "version": 1,
        "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "watching": watching[:5] or ["等待任务分配"],
        "active": active[:5] or ["空闲中"],
        "pending": pending[:5] or ["无"],
    }


def bootstrap(gid: str, force: bool = False) -> str:
    ctx_dir = CONTEXT_HOME / gid
    ctx_dir.mkdir(parents=True, exist_ok=True)

    results = []

    # identity — merge, don't overwrite
    if (ctx_dir / "identity.json").exists():
        existing = json.loads((ctx_dir / "identity.json").read_text())
        new_ident = build_identity(gid)
        # 只补充空字段
        for k, v in new_ident.items():
            if not existing.get(k):
                existing[k] = v
        (ctx_dir / "identity.json").write_text(json.dumps(existing, ensure_ascii=False, indent=2))
        results.append(f"identity: merged {existing['agent']}")
    else:
        ident = build_identity(gid)
        (ctx_dir / "identity.json").write_text(json.dumps(ident, ensure_ascii=False, indent=2))
        results.append(f"identity: {ident['agent']} role={ident.get('role','?')}")

    # memory — merge, don't overwrite
    if (ctx_dir / "memory.json").exists():
        existing = json.loads((ctx_dir / "memory.json").read_text())
        new_entries = extract_knowledge(gid)
        old_set = set(existing.get("entries", []))
        added = [e for e in new_entries if e not in old_set]
        existing["entries"] = existing.get("entries", []) + added
        existing["version"] = existing.get("version", 0) + 1
        existing["updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        (ctx_dir / "memory.json").write_text(json.dumps(existing, ensure_ascii=False, indent=2))
        results.append(f"memory: {len(existing['entries'])} 条 (+{len(added)} 新增)")
    else:
        entries = extract_knowledge(gid)
        mem = {"version": 2, "updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "entries": entries}
        (ctx_dir / "memory.json").write_text(json.dumps(mem, ensure_ascii=False, indent=2))
        results.append(f"memory: {len(entries)} 条知识点")

    # plantree
    if force or not (ctx_dir / "plantree.json").exists():
        pt = build_plantree(gid)
        (ctx_dir / "plantree.json").write_text(json.dumps(pt, ensure_ascii=False, indent=2))
        results.append(f"plantree: {len(pt['active_lines'])} 条活跃线")

    # focus
    if force or not (ctx_dir / "focus.json").exists():
        focus = build_focus(gid)
        (ctx_dir / "focus.json").write_text(json.dumps(focus, ensure_ascii=False, indent=2))
        results.append(f"focus: watching={len(focus['watching'])} active={len(focus['active'])} pending={len(focus['pending'])}")

    return "\n".join(results)


if __name__ == "__main__":
    gid = sys.argv[1] if len(sys.argv) > 1 else "105"
    force = "--force" in sys.argv
    result = bootstrap(gid, force)
    print(f"Bootstrap GID={gid}:\n{result}")
