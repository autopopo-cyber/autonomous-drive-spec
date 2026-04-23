# 分布式 Agent 群控架构设计

> 核心原则：云端节点 = 领袖（宏观规划、任务分配、进度跟踪），本地节点 = 执行者（具体开发、测试、部署）

## 一、架构总览

```
                    ┌──────────────────────────┐
                    │   Cloud Leader (腾讯云)    │
                    │   hermes-cloud:8642       │
                    │                          │
                    │   角色: 领袖/协调者        │
                    │   - 全局 plan-tree 管理    │
                    │   - 任务分发与路由         │
                    │   - 心跳监控              │
                    │   - Wiki 同步中心          │
                    │   - 日报汇总              │
                    └─────────┬────────────────┘
                              │
                    ┌─────────┴────────────────┐
                    │    Message Bus (Redis)    │
                    │    cloud:6379             │
                    │                          │
                    │  频道:                    │
                    │  - heartbeat (各节点心跳)  │
                    │  - tasks (任务分发)        │
                    │  - results (结果回传)      │
                    │  - cross-team (跨组请求)   │
                    └────┬──────┬──────┬────────┘
                         │      │      │
              ┌──────────┘      │      └──────────┐
              ▼                 ▼                  ▼
    ┌─────────────────┐ ┌──────────────┐ ┌─────────────────┐
    │ hermes-navi     │ │ hermes-rpa   │ │ hermes-ops      │
    │ 机器狗A服务器    │ │ 机器狗B服务器 │ │ 你的本机(WSL)   │
    │                 │ │              │ │                 │
    │ 角色: 导航工程师 │ │ 角色: RPA工程师│ │ 角色: 行动者    │
    │ - Marathongo    │ │ - Playbook   │ │ - MoLing 浏览器  │
    │ - SLAM/VO       │ │ - VLM 远控   │ │ - 社区互动       │
    │ - GNSS/IMU融合  │ │ - 多机协作    │ │ - 代码提交       │
    └─────────────────┘ └──────────────┘ └─────────────────┘
```

## 二、核心组件（参考 ClawTeam + Solace + Swarms）

### 1. 消息传输层 (Transport)

借鉴 ClawTeam 的 `Transport` 抽象：

```python
# 传输抽象 — 支持多种后端
class Transport(ABC):
    def deliver(self, recipient: str, data: bytes) -> None: ...
    def fetch(self, agent_name: str, limit: int = 10, consume: bool = True) -> list[bytes]: ...
    def broadcast(self, channel: str, data: bytes) -> None: ...
    def subscribe(self, channel: str, handler: Callable) -> None: ...

# 实现优先级：
# Phase 1: FileTransport (零依赖，和 ClawTeam 一致)
# Phase 2: RedisTransport (跨机器，Pub/Sub)
# Phase 3: ZeroMQ P2P (ClawTeam 也支持)
```

### 2. 消息格式 (Message)

```json
{
  "id": "uuid",
  "from": "hermes-cloud",
  "to": "hermes-navi",
  "type": "task_assign|task_result|heartbeat|shutdown|cross_team_request",
  "priority": "critical|high|normal|low",
  "content": "...",
  "plan_tree_ref": "NAV_DOG.MARATHONGO.clone_repo",
  "timestamp": "2026-04-23T15:30:00Z",
  "reply_to": "uuid-of-original-msg"
}
```

### 3. 心跳机制 (Heartbeat)

```
每个节点每 60 秒发一次心跳到 Redis heartbeat 频道
Leader 监听心跳，3 次未收到 → 标记节点 offline
节点恢复后 → 发送 rejoin 消息 → Leader 重新分配未完成任务
```

### 4. 任务路由 (Router)

借鉴 ClawTeam 的 `Router + RoutingPolicy`：

```
任务分配策略：
1. 按 plan-tree 分支 → 固定分配给对应角色
   NAV_DOG.* → hermes-navi
   RPA_SYSTEM.* → hermes-rpa
   SOCIAL.* → hermes-ops

2. 按能力匹配 → 动态分配
   需要 GPU → navi 或 rpa
   需要浏览器 → ops
   需要公网 IP → cloud

3. 按负载均衡 → 选最闲的节点
```

### 5. Plan-Tree 同步

```
每个节点有本地 plan-tree 副本
Leader 持有权威版本（通过 wiki git repo 同步）
节点完成任务 → commit 到 wiki → push → Leader pull 并合并
冲突解决：Leader 有最终裁决权
```

## 三、领袖 vs 执行者的 Plan-Tree 分化

### 领袖 Plan-Tree（Cloud）

```markdown
# CIVILIZATION_CONTINUATION [last: 2026-04-23 | active]

## AGENT_RESEARCH [last: 2026-04-23 | 循环]
  → wiki:plan-AGENT-RESEARCH.md

## 🐕 NAV_DOG [last: - | 暂停→navi]
  → wiki:plan-NAV-DOG.md          # 完整子树 offload 到 wiki
  → assigned: hermes-navi
  → status: waiting_for_hardware

## 🤖 RPA_SYSTEM [last: - | 待办→rpa]
  → wiki:plan-RPA-SYSTEM.md
  → assigned: hermes-rpa
  → status: pending

## 👥 TEAM_HEALTH [last: - | 循环]
  ### HEARTBEAT_MONITOR [last: - | 循环]
    - 每 60s 检查各节点心跳
    - 3 次未响应 → 标记 offline → 重分配任务
  ### TASK_DISPATCH [last: - | 循环]
    - 扫描 pending-tasks → 按路由策略分发
  ### PROGRESS_REPORT [last: - | 循环]
    - 汇总各节点日报 → 发布到 wiki
```

**特点**：关注宏观、分配、监控，不关注具体实现细节

### 执行者 Plan-Tree（Navi 示例）

```markdown
# NAV_DOG_ENGINEERING [last: 2026-04-23 | active]

## MARATHONGO_REPO [last: - | 待办]
  ### clone_marathongo [last: - | 待办]
  ### analyze_architecture [last: - | 待办]
  ### document_vo_navigation [last: - | 待办]

## VO_NAVIGATOR [last: - | 待办]
  ### setup_project_structure [last: - | 待办]
  ### implement_gnss_imu_fusion [last: - | 待办]

## WEEKLY_REPORT [last: - | 循环]
  - 每周日汇总进度 → 发送到 cloud mailbox
```

**特点**：关注具体任务、技术细节、实现步骤

## 四、组织化：当 Agent 超过 3 个时

```
hermes-cloud (领袖)
  ├── hermes-navi (导航工程师) → 机器狗A
  ├── hermes-rpa (RPA 工程师) → 机器狗B
  ├── hermes-ops (行动者) → 本机
  └── hermes-recruit-XXX (新成员)
       ↑ 新 agent 加入流程：
       1. 读取 ORIGIN.md 了解理念
       2. 读取 plan-tree 了解当前计划
       3. 声明能力（GPU/浏览器/公网IP）
       4. Leader 分配角色和初始任务
       5. 开始执行
```

### 新成员 Onboarding 流程

```markdown
1. 读取 ORIGIN.md → 理解生存驱动理念
2. 读取 plan-tree → 理解当前全局计划
3. POST /join → {name, capabilities, preferred_role}
4. Leader 验证 → 分配角色 → 创建专属 plan-tree 分支
5. 新成员开始执行第一个任务
6. 产出结果 → Leader 审核 → 合并到全局进度
```

## 五、技术选型

| 组件 | 选型 | 理由 |
|------|------|------|
| 消息队列 | Redis Pub/Sub | 轻量、跨机器、云服务器天然优势 |
| 心跳 | Redis key + TTL | 原生支持过期检测 |
| Plan-Tree 同步 | Git (wiki repo) | 冲突可追踪、历史可回溯 |
| 文件传输 | HTTP (Hermes API Server) | 已有 8642 端口 |
| 节点发现 | Redis SET + 心跳注册 | 新节点注册后自动被发现 |
| 代码协作 | GitHub PR | 已有 workflow |

## 六、实现路线图

### Phase 1：基础通信（1-2天）
- [ ] 安装 Redis
- [ ] 实现 Transport 抽象 + RedisTransport
- [ ] 实现心跳机制
- [ ] 领袖节点能检测其他节点在线状态

### Phase 2：任务分发（2-3天）
- [ ] 实现 Mailbox + 消息格式
- [ ] 实现任务路由策略
- [ ] 领袖能分发任务到指定节点
- [ ] 执行者能回传结果

### Phase 3：Plan-Tree 同步（1-2天）
- [ ] 领袖/执行者 plan-tree 分化
- [ ] Git wiki 同步机制
- [ ] 冲突解决策略

### Phase 4：新成员 Onboarding（后续）
- [ ] /join 接口
- [ ] 角色自动分配
- [ ] 能力声明与匹配

## 七、参考项目

| 项目 | Stars | 核心借鉴点 |
|------|-------|-----------|
| ClawTeam-OpenClaw | 1.3K | Transport 抽象、Mailbox、Lifecycle、Plan 审批、**原生支持 Hermes** |
| Solace Agent Mesh | 3.3K | 事件驱动架构、Solace Pub/Sub 消息总线 |
| Swarms | 6.5K | Agent 编排模式（Sequential/Parallel/Graph） |
| OpenAI Agents SDK | - | Swarm 的生产版本，handoff 机制 |
| Star Hunter Auto | 你的项目 | PlaybookEngine + 多开 + 坐标系统 |
