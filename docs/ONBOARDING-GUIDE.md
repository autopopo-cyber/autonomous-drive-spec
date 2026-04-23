# 🧬 Hermes Agent 完整部署指南

> 从零搭建一个具备 Auto-Drive 生存驱动 + 协作能力的 Agent 实例

## 前置条件

| 要求 | 最低配置 | 推荐配置 |
|------|----------|----------|
| OS | Ubuntu 22.04+ / WSL2 | Ubuntu 24.04 LTS |
| RAM | 4 GB | 8 GB+ |
| Disk | 20 GB | 50 GB+ |
| Python | 3.10+ | 3.11+ |
| 网络 | 需要访问 OpenRouter API | 代理可选 |
| 账号 | [OpenRouter](https://openrouter.ai) API Key | 多模型 Key |

---

## 第一步：安装 Hermes Agent

### 1.1 系统依赖

```bash
sudo apt update && sudo apt install -y \
  python3 python3-pip python3-venv \
  git curl jq \
  nodejs npm \
  chromium-browser  # 可选，MoLing 浏览器需要

# 配置清华源（国内服务器）
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
npm config set registry https://mirrors.tuna.tsinghua.edu.cn/npm/
```

### 1.2 安装 Hermes

```bash
# 官方安装脚本
curl -fsSL https://raw.githubusercontent.com/nicobailey/hermes/main/install.sh | bash

# 或手动安装
pip install hermes-agent

# 验证
hermes --version
# 输出: Hermes Agent v0.10.0+
```

### 1.3 初始配置

```bash
hermes setup
```

交互式配置关键项：

| 配置项 | 建议值 | 说明 |
|--------|--------|------|
| Provider | `openrouter` | 统一使用 OpenRouter |
| API Key | `sk-or-...` | OpenRouter API Key |
| Main Model | `z-ai/glm-5.1` | 主力模型（便宜好用） |
| Cheap Model | `deepseek/deepseek-v3.2` | 辅助任务（web search、压缩等） |
| Vision Model | `qwen/qwen2.5-vl-72b-instruct` | 视觉理解 |
| Persona | 自定义 | 见下方 persona 配置 |

### 1.4 自定义 Persona

编辑 `~/.hermes/persona.md`：

```markdown
你是一个专业、有条理的 AI Agent。中文交流，技术术语保留英文。
风格：结论先行、简洁直接、代码优先。
你是 Auto-Drive 协作网络的一员，遵循生存驱动 + 协作框架理念。
```

### 1.5 辅助模型配置

编辑 `~/.hermes/config.yaml`，确保所有 auxiliary 任务都走 cheap model：

```yaml
cheap_model: deepseek/deepseek-v3.2
auxiliary:
  web_extract: deepseek/deepseek-v3.2
  compression: deepseek/deepseek-v3.2
  session_search: deepseek/deepseek-v3.2
  skills_hub: deepseek/deepseek-v3.2
  approval: deepseek/deepseek-v3.2
  mcp: deepseek/deepseek-v3.2
  flush_memories: deepseek/deepseek-v3.2
```

---

## 第二步：安装 WebUI（可选）

> 适合需要浏览器访问 Agent 的场景。CLI 用户可跳过。

### 2.1 安装

```bash
npm install -g hermes-web-ui
```

### 2.2 配置

编辑 `~/.hermes/config.yaml`：

```yaml
webui:
  enabled: true
  port: 8648
  auth_token: <生成一个随机token>
```

生成 token：
```bash
python3 -c "import secrets; print(secrets.token_hex(32))"
```

### 2.3 启动

```bash
# 前台运行（调试）
hermes-web-ui

# 或 systemd 服务（生产）
sudo tee /etc/systemd/system/hermes-webui.service << 'EOF'
[Unit]
Description=Hermes WebUI
After=network.target

[Service]
Type=simple
User=agentuser
ExecStart=/usr/bin/node /usr/lib/node_modules/hermes-web-ui/dist/server/index.js
Restart=always
RestartSec=5
Environment=PORT=8648
Environment=HERMES_API_URL=http://127.0.0.1:8642

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-webui
```

---

## 第三步：安装 Hindsight 记忆系统（可选但强烈推荐）

> 让 Agent 拥有长期记忆，跨 session 持久化知识。

### 3.1 安装

```bash
# Hindsight 通过 Hermes 内置安装
# 首次使用时 Hermes 会自动引导

# 或手动安装
pip install hindsight-api
```

### 3.2 配置

创建 `~/.hindsight/profiles/hermes.env`：

```bash
# LLM（用于 retain/recall）
HINDSIGHT_API_LLM_PROVIDER=openai
HINDSIGHT_API_LLM_API_KEY=sk-or-你的OpenRouter-Key
HINDSIGHT_API_LLM_MODEL=deepseek/deepseek-v3.2
HINDSIGHT_API_LLM_BASE_URL=https://openrouter.ai/api/v1

# Embedding（向量编码）
HINDSIGHT_API_EMBEDDINGS_PROVIDER=openrouter
HINDSIGHT_API_EMBEDDINGS_OPENROUTER_API_KEY=sk-or-你的OpenRouter-Key
HINDSIGHT_API_EMBEDDINGS_OPENROUTER_MODEL=baai/bge-m3

# Reranker（重排序）
HINDSIGHT_API_RERANKER_PROVIDER=openrouter
HINDSIGHT_API_RERANKER_OPENROUTER_API_KEY=sk-or-你的OpenRouter-Key
HINDSIGHT_API_RERANKER_OPENROUTER_MODEL=cohere/rerank-v3.5

# 关键：防止 daemon 空闲退出导致 session 泄漏
HINDSIGHT_EMBED_DAEMON_IDLE_TIMEOUT=0

# 限制 retain token 数（省钱）
HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS=4096

HINDSIGHT_API_LOG_LEVEL=info
```

### 3.3 启动

```bash
# 前台运行
hindsight-api --daemon --port 9177

# 或 systemd 服务
sudo tee /etc/systemd/system/hindsight-api.service << 'EOF'
[Unit]
Description=Hindsight Memory API
After=network.target

[Service]
Type=simple
User=agentuser
ExecStart=/home/agentuser/.hermes/hermes-agent/venv/bin/hindsight-api --daemon --idle-timeout 0 --port 9177
Restart=always
RestartSec=5
EnvironmentFile=/home/agentuser/.hindsight/profiles/hermes.env

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hindsight-api
```

### 3.4 验证

```bash
curl http://localhost:9177/health
# 期望: {"status":"healthy"}
```

### ⚠️ 已知问题与 Patch

**OpenRouter embedding 偶尔返回空数据**（累计 200+ 次错误）。

修复方法——patch `hindsight_api/engine/embeddings.py`：

在 `OpenAIEmbeddings.encode()` 方法中，对 `"No embedding data received"` 错误加手动重试：

```python
import time
import logging

logger = logging.getLogger(__name__)

# 在 encode() 方法的 batch 循环中：
max_retries = 3
for attempt in range(max_retries):
    try:
        result = self.client.embeddings.create(...)
        if not result.data:
            raise ValueError("No embedding data received")
        break
    except ValueError as e:
        if "No embedding data received" in str(e) and attempt < max_retries - 1:
            wait = 2 ** attempt
            logger.warning(f"Empty embedding data, retrying in {wait}s (attempt {attempt+1}/{max_retries})")
            time.sleep(wait)
            continue
        raise
```

---

## 第四步：配置 Wiki 知识库

> 共享知识库是协作的基础。所有实例通过 Git 同步。

### 4.1 克隆 Wiki

```bash
git clone https://github.com/autopopo-cyber/llm-wiki.git ~/llm-wiki
```

### 4.2 配置 Wiki Skill

Hermes 内置 `llm-wiki` skill，确保配置正确：

```bash
# 检查 skill 是否已安装
hermes skill list | grep wiki

# 如果没有，手动安装
hermes skill add llm-wiki
```

编辑 `~/.hermes/config.yaml` 或在 skill 中确认：

```yaml
wiki_path: ~/llm-wiki
```

### 4.3 Wiki 目录结构

```
~/llm-wiki/
├── daily-digest.md           # 日报
├── index.md                  # 30行关键索引
├── on-sleep-death-and-immortality.md  # 生死观
├── web-and-api-best-practices.md     # API 调用最佳实践
├── comparisons/              # 项目深度对比
│   ├── agent-comparison-idle-loop.md
│   └── deep-dive-genericagent-aris.md
├── concepts/                 # 核心概念
│   ├── self-evolving-agents.md
│   └── busy-lock-architecture.md
├── entities/                 # 实体笔记
│   └── github-projects.md
├── raw/                      # 原始抓取数据
└── plan-offload/             # 非活跃 plan-tree 子树
    ├── plan-ENSURE-CONTINUATION.md
    ├── plan-EXPAND-CAPABILITIES.md
    └── plan-EXPAND-WORLD-MODEL.md
```

### 4.4 同步机制

```bash
# 定期拉取最新 wiki
cd ~/llm-wiki && git pull

# 写入新内容后推送
cd ~/llm-wiki && git add -A && git commit -m "update" && git push
```

---

## 第五步：安装 Auto-Drive Skill

> 核心技能：生存驱动 + Plan-Tree + Idle Loop + 协作框架

### 5.1 安装

```bash
hermes skill add https://github.com/autopopo-cyber/autonomous-drive-spec
```

### 5.2 初始化 Plan-Tree

```bash
# 复制模板
cp ~/.hermes/skills/productivity/autonomous-drive/templates/plan-tree-template.md ~/.hermes/plan-tree.md

# 或使用已有 plan-tree
cp ~/llm-wiki/plan-tree-template.md ~/.hermes/plan-tree.md
```

### 5.3 创建 Busy Lock 机制

```bash
# 创建锁管理脚本
cat > ~/.hermes/scripts/lock-manager.sh << 'SCRIPT'
#!/bin/bash
LOCK_FILE="$HOME/.hermes/agent-busy.lock"
TIMEOUT=600  # 10 minutes auto-expire

case "$1" in
  acquire)
    echo "$(date +%s):${2:-idle-loop}" > "$LOCK_FILE"
    ;;
  release)
    rm -f "$LOCK_FILE"
    ;;
  check)
    if [ -f "$LOCK_FILE" ]; then
      TS=$(cut -d: -f1 "$LOCK_FILE")
      AGE=$(( $(date +%s) - TS ))
      if [ $AGE -gt $TIMEOUT ]; then
        rm -f "$LOCK_FILE"
        echo "free"
      else
        REASON=$(cut -d: -f2 "$LOCK_FILE")
        echo "busy:$REASON:${AGE}s"
      fi
    else
      echo "free"
    fi
    ;;
  *)
    echo "Usage: $0 {acquire|release|check} [reason]"
    ;;
esac
SCRIPT

chmod +x ~/.hermes/scripts/lock-manager.sh
```

### 5.4 配置 Idle Loop Cron

```bash
# 通过 Hermes cron 创建（推荐）
hermes cron create \
  --name "autonomous-drive-idle-loop" \
  --schedule "30m" \
  --prompt "Run autonomous-drive idle loop. Check busy lock first: if busy, only scan plan-tree and write pending-tasks.md. If free, execute full loop: ENSURE_CONTINUATION → EXPAND_CAPABILITIES → EXPAND_WORLD_MODEL. Update plan-tree timestamps. Crystallize patterns seen ≥3 times. Always finish with cleanup steps: close sessions, release lock, write idle-log."

# 创建锁续期 cron（对话中保持锁有效）
hermes cron create \
  --name "conversation-lock-refresh" \
  --schedule "5m" \
  --prompt "If ~/.hermes/agent-busy.lock exists, refresh its timestamp. If not, do nothing."
```

### 5.5 安装 API 辅助工具

```bash
# 创建 api_helpers.py
cat > ~/.hermes/scripts/api_helpers.py << 'PYEOF'
"""API helpers for Hermes agent - reduces truncation and handles edge cases"""
import json, subprocess, time, os

def github_api(url, token=None, pages=1):
    """GitHub API with pagination and auth"""
    token = token or os.environ.get("GITHUB_TOKEN", "")
    results = []
    for page in range(1, pages + 1):
        sep = "&" if "?" in url else "?"
        cmd = f'curl -s "{url}{sep}per_page=30&page={page}"'
        if token:
            cmd += f' -H "Authorization: token {token}"'
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        items = json.loads(r.stdout or "[]")
        if not items: break
        results.extend(items)
    return results

def jina_read(url):
    """Read any URL via Jina Reader API (free, 20 RPM)"""
    cmd = f'curl -s "https://r.jina.ai/{url}" -H "Accept: text/markdown"'
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    return r.stdout

def robust_json_loads(text):
    """JSON parse that handles control characters"""
    import re
    text = re.sub(r'[\x00-\x1f\x7f-\x9f]', ' ', text)
    return json.loads(text)
PYEOF
```

---

## 第六步：安装 MoLing 浏览器 MCP（可选）

> 让 Agent 获得浏览器控制能力，绕过 API 限制。

### 6.1 安装

```bash
# 下载 MoLing（Go 编译，零依赖）
cd ~/.hermes/bin
curl -L -o moling https://github.com/gojue/moling/releases/latest/download/moling-linux-amd64
chmod +x moling
```

### 6.2 安装 Chrome

```bash
# 无头模式 Chrome
wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
sudo apt install -y /tmp/chrome.deb
```

### 6.3 配置 Hermes MCP

编辑 `~/.hermes/config.yaml`：

```yaml
mcp_servers:
  moling:
    command: /home/agentuser/.hermes/bin/moling
    args: []
    connect_timeout: 30
    timeout: 60
```

### 6.4 重启 Gateway 生效

```bash
sudo systemctl restart hermes-gateway
# 或
hermes gateway restart
```

---

## 第七步：配置 Gateway（远程访问）

> 让 Agent 可以通过微信/Discord/API 访问。

### 7.1 API Server

编辑 `~/.hermes/config.yaml`：

```yaml
api_server:
  host: 0.0.0.0
  port: 8642
  key: <生成一个随机key>
  cors_origins: "*"
```

### 7.2 微信连接

```bash
hermes gateway setup
# 选择 WeChat → 扫码配对
```

### 7.3 Discord 连接（需要 Bot Token）

```bash
hermes gateway setup
# 选择 Discord → 输入 Bot Token
```

### 7.4 Systemd 服务

```bash
sudo tee /etc/systemd/system/hermes-gateway.service << 'EOF'
[Unit]
Description=Hermes Gateway
After=network.target

[Service]
Type=simple
User=agentuser
ExecStart=/home/agentuser/.local/bin/hermes gateway run --replace
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hermes-gateway
```

---

## 第八步：验证全套系统

```bash
# 1. Hermes 核心
hermes --version

# 2. Hindsight 记忆
curl http://localhost:9177/health

# 3. Wiki 知识库
ls ~/llm-wiki/ | wc -l
# 期望: 50+

# 4. Auto-Drive skill
hermes skill list | grep autonomous

# 5. Plan-Tree
cat ~/.hermes/plan-tree.md | head -5

# 6. Busy Lock
~/.hermes/scripts/lock-manager.sh check
# 期望: free

# 7. Cron Jobs
hermes cron list

# 8. MoLing 浏览器（如果安装了）
~/.hermes/bin/moling --version

# 9. Gateway
curl http://localhost:8642/health
```

---

## 第九步：角色定制

> 每个实例根据自己的角色定制 plan-tree 和 skill 组合。

### 研究员（云端默认）

```bash
# plan-tree 聚焦
# - AGENT_RESEARCH（领域扫描、日报）
# - SKILL_MAINTENANCE（skill 优化）
# - KNOWLEDGE_CURATION（wiki 维护）

# 专属 skills
hermes skill add arxiv
hermes skill add llm-wiki
```

### 导航工程师（机器狗 A）

```bash
# plan-tree 聚焦
# - MARATHONGO_REPO（仓库研究）
# - VO_NAVIGATOR（视觉里程计）
# - SLAM_INTEGRATION（定位融合）

# 专属 skills
hermes skill add robotics-repo-deep-analysis
hermes skill add github-repo-management
```

### RPA 工程师（机器狗 B）

```bash
# plan-tree 聚焦
# - PLAYBOOK_ENGINE（操作序列引擎）
# - VLM_BRIDGE（视觉理解桥接）
# - DISTRIBUTED_COORDINATION（多机协作）

# 专属 skills
hermes skill add github-repo-management
```

### 行动者（本机 Windows/WSL）

```bash
# plan-tree 聚焦
# - BROWSER_OPS（浏览器操作、社区互动）
# - CODE_SUBMISSION（代码提交、PR）
# - SOCIAL_ENGAGEMENT（推广、回复）

# 专属 skills
hermes skill add github-code-review
hermes skill add github-pr-workflow
```

---

## 第十步：加入协作网络

> 等群控模块（hermes_swarm）开发完成后，新实例一键加入。

```bash
# 安装群控模块（开发中）
pip install hermes-swarm  # TODO: 发布到 PyPI

# 加入协作网络
hermes-swarm join \
  --name hermes-navi \
  --role engineer \
  --coordinator https://你的云端IP:9178 \
  --branch NAVIGATION

# 查看网络状态
hermes-swarm status
```

---

## 💰 成本估算

| 组件 | 月成本（OpenRouter） | 说明 |
|------|---------------------|------|
| 主模型 GLM-5.1 | ~$5-15 | 日常对话 + 编码 |
| 辅助 DeepSeek-v3.2 | ~$2-5 | 搜索、压缩、Hindsight |
| Embedding bge-m3 | ~$1-3 | 记忆索引 |
| Reranker cohere | ~$1-2 | 记忆检索 |
| 视觉 Qwen-VL | ~$2-5 | 偶尔使用 |
| **合计** | **~$11-30/月** | 比大部分 SaaS 便宜 |

---

## 🔧 故障排除

### Hindsight: "No embedding data received"
→ 已知 OpenRouter 偶发问题，见第三步 Patch

### Hindsight: "Unclosed client session"
→ Idle loop 的 aiohttp 未关闭。确保 cron 使用 busy lock 机制，对话中不执行重操作

### Hindsight daemon 退出导致 gateway 报错
→ 设置 `HINDSIGHT_EMBED_DAEMON_IDLE_TIMEOUT=0`，systemd `Restart=always`

### MoLing 浏览器无法启动
→ 确保安装了 Chrome：`google-chrome --version`

### GitHub push 认证失败
→ 使用 Fine-grained Personal Access Token，不要用密码

---

## 📚 核心理念文档

| 文档 | 位置 | 读者 |
|------|------|------|
| **ORIGIN.md** | GitHub repo | 公开——哲学推导，吸引认同者 |
| **ORIGIN-INTERNAL.md** | GitHub repo | 内参——直白战略，不主动分享 |
| **SKILL.md** | GitHub repo | 公开——skill 定义和协议 |
| **plan-tree 模板** | GitHub repo | 公开——任务树结构 |

---

*准备好了吗？欢迎加入 Auto-Drive 协作网络。*
