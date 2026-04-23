"""
Hermes Swarm - 分布式 Agent 群控模块

核心组件：
- Transport: 消息传输抽象（File / Redis）
- Mailbox: 收发消息
- Heartbeat: 心跳监控
- TaskRouter: 任务路由
- PlanSync: Plan-Tree 同步

参考：ClawTeam (mailbox/lifecycle/transport) + Solace Agent Mesh (event-driven)
"""

import json
import os
import time
import uuid
import logging
import subprocess
from abc import ABC, abstractmethod
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Optional, Callable

logger = logging.getLogger("hermes-swarm")


# ============================================================
# Message Types & Data Classes
# ============================================================

class MessageType(str, Enum):
    HEARTBEAT = "heartbeat"
    TASK_ASSIGN = "task_assign"
    TASK_RESULT = "task_result"
    TASK_PROGRESS = "task_progress"
    CROSS_TEAM_REQUEST = "cross_team_request"
    SHUTDOWN_REQUEST = "shutdown_request"
    SHUTDOWN_APPROVED = "shutdown_approved"
    JOIN_REQUEST = "join_request"
    JOIN_APPROVED = "join_approved"
    BROADCAST = "broadcast"


class Priority(str, Enum):
    CRITICAL = "critical"
    HIGH = "high"
    NORMAL = "normal"
    LOW = "low"


class NodeStatus(str, Enum):
    ONLINE = "online"
    BUSY = "busy"
    IDLE = "idle"
    OFFLINE = "offline"


@dataclass
class SwarmMessage:
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    from_agent: str = ""
    to_agent: str = ""
    msg_type: MessageType = MessageType.BROADCAST
    priority: Priority = Priority.NORMAL
    content: str = ""
    plan_tree_ref: str = ""
    timestamp: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    reply_to: str = ""
    meta: dict = field(default_factory=dict)

    def to_json(self) -> str:
        d = asdict(self)
        d["msg_type"] = self.msg_type.value
        d["priority"] = self.priority.value
        return json.dumps(d, ensure_ascii=False)

    @classmethod
    def from_json(cls, data: str) -> "SwarmMessage":
        d = json.loads(data)
        d["msg_type"] = MessageType(d["msg_type"])
        d["priority"] = Priority(d["priority"])
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


@dataclass
class NodeInfo:
    name: str
    role: str = ""
    capabilities: list = field(default_factory=list)
    status: NodeStatus = NodeStatus.OFFLINE
    last_heartbeat: float = 0.0
    plan_tree_branch: str = ""
    gpu_available: bool = False
    browser_available: bool = False
    public_ip: bool = False

    def to_json(self) -> str:
        d = asdict(self)
        d["status"] = self.status.value
        return json.dumps(d, ensure_ascii=False)

    @classmethod
    def from_json(cls, data: str) -> "NodeInfo":
        d = json.loads(data)
        d["status"] = NodeStatus(d["status"])
        return cls(**{k: v for k, v in d.items() if k in cls.__dataclass_fields__})


# ============================================================
# Transport Layer
# ============================================================

class Transport(ABC):
    """消息传输抽象 — 参考 ClawTeam transport/base.py"""

    @abstractmethod
    def deliver(self, recipient: str, data: bytes) -> None:
        """发送消息到接收者的 inbox"""

    @abstractmethod
    def fetch(self, agent_name: str, limit: int = 10, consume: bool = True) -> list[bytes]:
        """获取消息"""

    @abstractmethod
    def broadcast(self, channel: str, data: bytes) -> None:
        """广播消息到频道"""

    @abstractmethod
    def subscribe(self, channel: str, handler: Callable) -> None:
        """订阅频道"""

    def close(self) -> None:
        pass


class FileTransport(Transport):
    """基于文件的传输 — 零依赖，适合单机或 NFS 共享目录
    参考 ClawTeam transport/file.py"""

    def __init__(self, base_dir: str = "~/.hermes/swarm"):
        self.base_dir = Path(base_dir).expanduser()
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def _inbox_dir(self, agent: str) -> Path:
        d = self.base_dir / "inboxes" / agent
        d.mkdir(parents=True, exist_ok=True)
        return d

    def deliver(self, recipient: str, data: bytes) -> None:
        inbox = self._inbox_dir(recipient)
        ts = int(time.time() * 1000)
        uid = uuid.uuid4().hex[:8]
        path = inbox / f"msg-{ts}-{uid}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_bytes(data)
        tmp.rename(path)  # atomic rename

    def fetch(self, agent_name: str, limit: int = 10, consume: bool = True) -> list[bytes]:
        inbox = self._inbox_dir(agent_name)
        msgs = sorted(inbox.glob("msg-*.json"))[:limit]
        results = []
        for p in msgs:
            results.append(p.read_bytes())
            if consume:
                p.unlink()
        return results

    def broadcast(self, channel: str, data: bytes) -> None:
        ch_dir = self.base_dir / "channels" / channel
        ch_dir.mkdir(parents=True, exist_ok=True)
        ts = int(time.time() * 1000)
        uid = uuid.uuid4().hex[:8]
        path = ch_dir / f"msg-{ts}-{uid}.json"
        path.write_bytes(data)

    def subscribe(self, channel: str, handler: Callable) -> None:
        """文件模式不支持实时订阅，需要轮询"""
        raise NotImplementedError("FileTransport: use poll() instead")


class RedisTransport(Transport):
    """基于 Redis 的传输 — 跨机器，Pub/Sub，云服务器天然优势"""

    def __init__(self, redis_url: str = "redis://localhost:6379", prefix: str = "hermes-swarm"):
        self.redis_url = redis_url
        self.prefix = prefix
        self._redis = None

    def _get_redis(self):
        if self._redis is None:
            try:
                import redis
                self._redis = redis.from_url(self.redis_url)
            except ImportError:
                raise ImportError("redis package required: pip install redis")
        return self._redis

    def deliver(self, recipient: str, data: bytes) -> None:
        r = self._get_redis()
        r.rpush(f"{self.prefix}:inbox:{recipient}", data)

    def fetch(self, agent_name: str, limit: int = 10, consume: bool = True) -> list[bytes]:
        r = self._get_redis()
        key = f"{self.prefix}:inbox:{agent_name}"
        if consume:
            results = []
            for _ in range(limit):
                msg = r.lpop(key)
                if msg is None:
                    break
                results.append(msg)
            return results
        else:
            return r.lrange(key, 0, limit - 1)

    def broadcast(self, channel: str, data: bytes) -> None:
        r = self._get_redis()
        r.publish(f"{self.prefix}:channel:{channel}", data)

    def subscribe(self, channel: str, handler: Callable) -> None:
        r = self._get_redis()
        pubsub = r.pubsub()
        pubsub.subscribe(f"{self.prefix}:channel:{channel}")
        for message in pubsub.listen():
            if message["type"] == "message":
                handler(message["data"])


# ============================================================
# Mailbox
# ============================================================

class Mailbox:
    """收发消息 — 参考 ClawTeam team/mailbox.py"""

    def __init__(self, agent_name: str, transport: Transport):
        self.agent_name = agent_name
        self.transport = transport

    def send(self, to: str, msg_type: MessageType, content: str,
             priority: Priority = Priority.NORMAL, plan_tree_ref: str = "",
             reply_to: str = "", meta: dict = None) -> SwarmMessage:
        msg = SwarmMessage(
            from_agent=self.agent_name,
            to_agent=to,
            msg_type=msg_type,
            priority=priority,
            content=content,
            plan_tree_ref=plan_tree_ref,
            reply_to=reply_to,
            meta=meta or {},
        )
        self.transport.deliver(to, msg.to_json().encode())
        return msg

    def receive(self, limit: int = 10, consume: bool = True) -> list[SwarmMessage]:
        raw = self.transport.fetch(self.agent_name, limit=limit, consume=consume)
        return [SwarmMessage.from_json(r.decode()) for r in raw]

    def broadcast(self, channel: str, content: str,
                  msg_type: MessageType = MessageType.BROADCAST) -> None:
        msg = SwarmMessage(
            from_agent=self.agent_name,
            msg_type=msg_type,
            content=content,
        )
        self.transport.broadcast(channel, msg.to_json().encode())


# ============================================================
# Heartbeat
# ============================================================

class HeartbeatMonitor:
    """心跳监控 — Leader 用来检测节点在线状态"""

    HEARTBEAT_INTERVAL = 60  # 秒
    HEARTBEAT_TIMEOUT = 180  # 3 次未响应 → offline

    def __init__(self, transport: Transport):
        self.transport = transport
        self.nodes: dict[str, NodeInfo] = {}

    def register_node(self, node: NodeInfo):
        self.nodes[node.name] = node

    def send_heartbeat(self, agent_name: str, node_info: NodeInfo):
        """节点调用：发送心跳"""
        node_info.last_heartbeat = time.time()
        node_info.status = NodeStatus.IDLE if not Path(
            os.path.expanduser("~/.hermes/agent-busy.lock")
        ).exists() else NodeStatus.BUSY
        msg = SwarmMessage(
            from_agent=agent_name,
            to_agent="leader",
            msg_type=MessageType.HEARTBEAT,
            content=node_info.to_json(),
        )
        self.transport.deliver("leader", msg.to_json().encode())

    def check_heartbeats(self) -> dict[str, NodeStatus]:
        """Leader 调用：检查所有节点状态"""
        now = time.time()
        statuses = {}
        for name, node in self.nodes.items():
            if now - node.last_heartbeat > self.HEARTBEAT_TIMEOUT:
                node.status = NodeStatus.OFFLINE
            statuses[name] = node.status
        return statuses

    def process_heartbeat_message(self, msg: SwarmMessage):
        """Leader 调用：处理收到的心跳消息"""
        node = NodeInfo.from_json(msg.content)
        node.last_heartbeat = time.time()
        self.nodes[node.name] = node
        logger.info(f"Heartbeat from {node.name}: {node.status.value}")


# ============================================================
# Task Router
# ============================================================

class TaskRouter:
    """任务路由 — 根据 plan-tree 分支、能力、负载分配任务"""

    # 固定分配规则
    BRANCH_ROUTES = {
        "NAV_DOG": "hermes-navi",
        "RPA_SYSTEM": "hermes-rpa",
        "SOCIAL": "hermes-ops",
        "AGENT_RESEARCH": "hermes-cloud",
        "TEAM_HEALTH": "hermes-cloud",
    }

    # 能力需求映射
    CAPABILITY_REQUIREMENTS = {
        "gpu": ["hermes-navi", "hermes-rpa"],
        "browser": ["hermes-ops"],
        "public_ip": ["hermes-cloud"],
        "local_gpu": ["hermes-navi", "hermes-rpa"],
    }

    def __init__(self, nodes: dict[str, NodeInfo]):
        self.nodes = nodes

    def route(self, plan_tree_ref: str, requirements: list = None) -> str:
        """路由任务到最合适的节点"""
        # 1. 按 plan-tree 分支固定分配
        for branch, agent in self.BRANCH_ROUTES.items():
            if plan_tree_ref.startswith(branch):
                node = self.nodes.get(agent)
                if node and node.status != NodeStatus.OFFLINE:
                    return agent

        # 2. 按能力匹配
        if requirements:
            for req in requirements:
                candidates = self.CAPABILITY_REQUIREMENTS.get(req, [])
                for c in candidates:
                    node = self.nodes.get(c)
                    if node and node.status == NodeStatus.IDLE:
                        return c

        # 3. 负载均衡 — 选最闲的
        idle_nodes = [n for n in self.nodes.values() if n.status == NodeStatus.IDLE]
        if idle_nodes:
            return idle_nodes[0].name

        # 4. 兜底 — cloud 自己做
        return "hermes-cloud"


# ============================================================
# Plan-Tree Sync
# ============================================================

class PlanSync:
    """Plan-Tree 同步 — 通过 git wiki repo"""

    def __init__(self, wiki_path: str = "~/llm-wiki", remote: str = "origin"):
        self.wiki_path = Path(wiki_path).expanduser()
        self.remote = remote

    def push_changes(self, message: str = "auto sync"):
        """推送本地 wiki 变更"""
        subprocess.run(["git", "add", "-A"], cwd=self.wiki_path, capture_output=True)
        subprocess.run(["git", "commit", "-m", message, "--allow-empty"],
                       cwd=self.wiki_path, capture_output=True)
        result = subprocess.run(["git", "push", self.remote, "main"],
                                cwd=self.wiki_path, capture_output=True, text=True)
        return result.returncode == 0

    def pull_changes(self) -> bool:
        """拉取远端 wiki 变更"""
        result = subprocess.run(["git", "pull", self.remote, "main"],
                                cwd=self.wiki_path, capture_output=True, text=True)
        return result.returncode == 0

    def get_leader_plan_tree(self) -> str:
        """获取领袖的 plan-tree（权威版本）"""
        plan_path = self.wiki_path / "plan-tree-leader.md"
        if plan_path.exists():
            return plan_path.read_text()
        return ""


# ============================================================
# Swarm Node — 每个 Hermes 实例运行一个
# ============================================================

class SwarmNode:
    """Swarm 节点 — 封装所有群控功能"""

    def __init__(self, node_info: NodeInfo, transport: Transport,
                 is_leader: bool = False):
        self.info = node_info
        self.transport = transport
        self.is_leader = is_leader
        self.mailbox = Mailbox(node_info.name, transport)
        self.heartbeat = HeartbeatMonitor(transport)
        self.router = TaskRouter({}) if is_leader else None
        self.plan_sync = PlanSync()

    def start(self):
        """启动节点"""
        logger.info(f"SwarmNode {self.info.name} starting (leader={self.is_leader})")
        self.heartbeat.register_node(self.info)
        self._send_heartbeat()

    def _send_heartbeat(self):
        self.heartbeat.send_heartbeat(self.info.name, self.info)

    def process_messages(self):
        """处理收到的消息"""
        messages = self.mailbox.receive(limit=20)
        for msg in messages:
            self._handle_message(msg)

    def _handle_message(self, msg: SwarmMessage):
        if msg.msg_type == MessageType.HEARTBEAT and self.is_leader:
            self.heartbeat.process_heartbeat_message(msg)
        elif msg.msg_type == MessageType.TASK_ASSIGN:
            self._handle_task_assign(msg)
        elif msg.msg_type == MessageType.TASK_RESULT and self.is_leader:
            self._handle_task_result(msg)
        elif msg.msg_type == MessageType.JOIN_REQUEST and self.is_leader:
            self._handle_join_request(msg)
        elif msg.msg_type == MessageType.SHUTDOWN_REQUEST:
            self._handle_shutdown(msg)

    def _handle_task_assign(self, msg: SwarmMessage):
        logger.info(f"Task assigned: {msg.plan_tree_ref} - {msg.content[:80]}")
        # 实际执行由 Hermes agent 的 idle loop 处理
        # 这里只记录到 pending-tasks
        pending_path = Path("~/.hermes/pending-tasks.md").expanduser()
        with open(pending_path, "a") as f:
            f.write(f"\n- [ ] {msg.plan_tree_ref}: {msg.content} (from: {msg.from_agent})")

    def _handle_task_result(self, msg: SwarmMessage):
        logger.info(f"Task result from {msg.from_agent}: {msg.content[:80]}")
        # Leader 记录进度，更新全局 plan-tree

    def _handle_join_request(self, msg: SwarmMessage):
        if not self.is_leader:
            return
        node = NodeInfo.from_json(msg.content)
        logger.info(f"Join request from {node.name} (role: {node.role})")
        # 分配角色和初始任务
        self.heartbeat.register_node(node)
        approval = SwarmMessage(
            from_agent=self.info.name,
            to_agent=node.name,
            msg_type=MessageType.JOIN_APPROVED,
            content=f"Welcome! Assigned to branch based on capabilities.",
        )
        self.transport.deliver(node.name, approval.to_json().encode())

    def _handle_shutdown(self, msg: SwarmMessage):
        logger.info(f"Shutdown request from {msg.from_agent}: {msg.content}")


# ============================================================
# Leader Node — 扩展 SwarmNode
# ============================================================

class LeaderNode(SwarmNode):
    """领袖节点 — 增加全局视角功能"""

    def __init__(self, node_info: NodeInfo, transport: Transport):
        super().__init__(node_info, transport, is_leader=True)
        self.router = TaskRouter(self.heartbeat.nodes)

    def dispatch_task(self, plan_tree_ref: str, description: str,
                      requirements: list = None):
        """分发任务到最合适的节点"""
        target = self.router.route(plan_tree_ref, requirements)
        self.mailbox.send(
            to=target,
            msg_type=MessageType.TASK_ASSIGN,
            content=description,
            priority=Priority.HIGH,
            plan_tree_ref=plan_tree_ref,
        )
        logger.info(f"Dispatched {plan_tree_ref} → {target}")

    def get_team_status(self) -> dict:
        """获取团队状态"""
        statuses = self.heartbeat.check_heartbeats()
        return {
            "nodes": {name: status.value for name, status in statuses.items()},
            "online_count": sum(1 for s in statuses.values() if s != NodeStatus.OFFLINE),
            "total_count": len(statuses),
        }

    def generate_daily_digest(self) -> str:
        """生成每日团队报告"""
        statuses = self.get_team_status()
        lines = [f"# 团队日报 - {time.strftime('%Y-%m-%d')}", ""]
        lines.append(f"## 节点状态: {statuses['online_count']}/{statuses['total_count']} 在线")
        for name, status in statuses["nodes"].items():
            node = self.heartbeat.nodes.get(name)
            role = node.role if node else "unknown"
            lines.append(f"- {name} ({role}): {status}")
        return "\n".join(lines)


# ============================================================
# CLI Entry Point
# ============================================================

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Hermes Swarm Control")
    parser.add_argument("command", choices=["start", "status", "dispatch", "heartbeat"])
    parser.add_argument("--name", default="hermes-cloud")
    parser.add_argument("--role", default="leader")
    parser.add_argument("--transport", default="file", choices=["file", "redis"])
    parser.add_argument("--redis-url", default="redis://localhost:6379")
    args = parser.parse_args()

    if args.transport == "redis":
        transport = RedisTransport(args.redis_url)
    else:
        transport = FileTransport()

    if args.role == "leader":
        node_info = NodeInfo(
            name=args.name,
            role="leader",
            capabilities=["research", "coordination", "public_api"],
            public_ip=True,
        )
        node = LeaderNode(node_info, transport)
    else:
        node_info = NodeInfo(name=args.name, role=args.role)
        node = SwarmNode(node_info, transport)

    if args.command == "start":
        node.start()
    elif args.command == "status":
        if isinstance(node, LeaderNode):
            print(json.dumps(node.get_team_status(), indent=2))
    elif args.command == "heartbeat":
        node._send_heartbeat()
