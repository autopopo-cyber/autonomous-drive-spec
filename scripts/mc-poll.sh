#!/bin/bash
# MC Task Poller v7.4 — 超时检测 + 进度监控 + 急停 + 诊断留痕
set -e

# 绕过代理直连tailscale (100.64.0.0/10)
export no_proxy="${no_proxy:+$no_proxy,}localhost,127.0.0.1,10.0.0.0/8,100.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

MC_URL="${MC_URL:-http://100.80.136.1:3000}"
GID="${MC_AGENT_GLOBAL_ID:-}"
LLM_MODEL="${MC_AGENT_LLM_MODEL:-deepseek-chat}"

LOCK="$HOME/.xianqin/mc-poll-${GID}.lock"       # 格式: PID:TASK_ID
LOCK_TTL=600                                      # 10分钟

# ─── v7.4: 超时与进度监控 ───
STUCK_TIMEOUT="${MC_STUCK_TIMEOUT:-1800}"         # 30分钟无产物更新 → 视为卡住
HERMES_TIMEOUT="${MC_HERMES_TIMEOUT:-600}"        # 10分钟硬超时
PROGRESS_CHECK_INTERVAL=60                         # 每60秒检查一次产物

# ─── GID→DBid ───
case "$GID" in
  101) DBID=10 ;; 102) DBID=4 ;; 103) DBID=5 ;; 104) DBID=6 ;;
  105) DBID=18 ;; 106) DBID=19 ;; 107) DBID=20 ;; 108) DBID=21 ;;
  *)   DBID="" ;;
esac

# ─── API key: .env 优先 (DeepSeek 专用 key), config.yaml 其次 ───
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-}"
# 1. .env — DeepSeek 专用 key
if [ -z "$DEEPSEEK_KEY" ]; then
  DEEPSEEK_KEY=$(grep 'DEEPSEEK_API_KEY' "$HOME/.hermes/.env" 2>/dev/null | cut -d= -f2)
fi
# 2. config.yaml — 但跳过 OpenRouter key (sk-or-*)
if [ -z "$DEEPSEEK_KEY" ]; then
  CANDIDATE=$(grep -A2 'main:' "$HOME/.hermes/config.yaml" 2>/dev/null | grep 'api_key:' | awk '{print $2}')
  if [ -n "$CANDIDATE" ] && [ "${CANDIDATE:0:6}" != "sk-or-" ]; then
    DEEPSEEK_KEY="$CANDIDATE"
  fi
fi

# ─── 解析锁文件 (PID:TASK_ID) ───
parse_lock() {
  if [ ! -f "$LOCK" ]; then return 1; fi
  local content
  content=$(cat "$LOCK" 2>/dev/null)
  LOCK_PID=$(echo "$content" | cut -d: -f1)
  LOCK_TASK=$(echo "$content" | cut -d: -f2)
  LOCK_AGE=$(($(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || echo 0)))
  return 0
}

# ─── LLM ping ───
llm_ping() {
  if [ -z "$DEEPSEEK_KEY" ]; then
    echo "[#$GID] 无 API key, 跳过 ping" >&2
    return 0
  fi
  local resp http_code body ok
  resp=$(curl -sf -w '\n%{http_code}' -m 10 \
    -H "Authorization: Bearer $DEEPSEEK_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$LLM_MODEL"'","messages":[{"role":"user","content":"pong"}],"max_tokens":3}' \
    "https://api.deepseek.com/v1/chat/completions" 2>/dev/null) || return 1

  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  [ "$http_code" != "200" ] && { echo "[#$GID] LLM ping HTTP $http_code — 不打卡" >&2; return 1; }

  ok=$(echo "$body" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get('choices',[{}])[0].get('message',{}).get('content','')
    print('OK' if c else 'EMPTY')
except: print('PARSE_ERROR'
)" 2>/dev/null)
  [ "$ok" != "OK" ] && { echo "[#$GID] LLM ping 响应异常($ok) — 不打卡" >&2; return 1; }

  echo "[#$GID] LLM ping OK" >&2
  return 0
}

# ─── heartbeat: 永远先发，不受锁影响 ───
heartbeat() {
  if [ -n "$DBID" ]; then
    curl -sf -X POST -H "x-api-key: $MC_API_KEY" \
      -H "Content-Type: application/json" -d '{}' \
      "$MC_URL/api/agents/$DBID/heartbeat" > /dev/null 2>&1 && \
      echo "[#$GID] 心跳已发(DB#$DBID)" >&2
  fi
}

# ─── 僵尸锁判定 (parse_lock 后调用) ───
is_zombie_lock() {
  # 1. 过期?
  if [ "$LOCK_AGE" -le "$LOCK_TTL" ]; then
    echo "  → 锁有效(${LOCK_AGE}s < ${LOCK_TTL}s) — 不清理" >&2
    return 1
  fi

  # 2. PID 还活着?
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "  → 锁过期但进程 $LOCK_PID 仍在跑 — 不清理" >&2
    return 1
  fi

  # 3. 任务在MC中已结束?
  if [ -n "$LOCK_TASK" ] && [ -n "$MC_API_KEY" ]; then
    local ts
    ts=$(curl -sf -H "x-api-key: $MC_API_KEY" "$MC_URL/api/tasks/$LOCK_TASK" 2>/dev/null | \
         python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status','') if isinstance(d,dict) else d[0].get('status',''))" 2>/dev/null || echo "")
    if [ "$ts" = "review" ] || [ "$ts" = "completed" ] || [ "$ts" = "failed" ]; then
      echo "  → 僵尸锁: pid=$LOCK_PID 已死, 任务#$LOCK_TASK 已结束($ts)" >&2
      return 0
    fi
  fi

  # 4. PID死了 → 僵尸
  echo "  → 僵尸锁: pid=$LOCK_PID 已死, 任务#$LOCK_TASK 状态未知" >&2
  return 0
}

# ─── v7.4: 写入诊断文件（异常退出时调用）───
write_diagnostic() {
  local task_id="$1" reason="$2" extra="${3:-}"
  local diag_file="$HOME/wiki-${GID}/raw/task-${task_id}-diagnostic.json"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  
  # 收集产物状态
  local result_exists="false" result_size=0 result_lines=0 result_mtime=0
  if [ -f "$RESULT_FILE" ]; then
    result_exists="true"
    result_size=$(stat -c %s "$RESULT_FILE" 2>/dev/null || echo 0)
    result_lines=$(wc -l < "$RESULT_FILE" 2>/dev/null || echo 0)
    result_mtime=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
  fi
  
  python3 -c "
import json
d={
  'task_id': '$task_id',
  'agent_gid': '$GID',
  'agent_dbid': '$DBID',
  'timestamp': '$now',
  'exit_reason': '$reason',
  'exit_detail': '$extra',
  'result_file': {
    'exists': $result_exists,
    'size_bytes': $result_size,
    'lines': $result_lines,
    'mtime_unix': $result_mtime,
    'mtime_human': '$(date -d "@$result_mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")'
  },
  'stuck_timeout': $STUCK_TIMEOUT,
  'hermes_timeout': $HERMES_TIMEOUT
}
with open('$diag_file', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('DIAGNOSTIC_WRITTEN')
" 2>/dev/null && echo "[#$GID] 📋 诊断: $diag_file ($reason)" >&2 || echo "[#$GID] ⚠️ 诊断写入失败" >&2
  
  # 同时上报 MC
  if [ -n "$MC_API_KEY" ]; then
    curl -sf -X PUT -H "x-api-key: $MC_API_KEY" -H "Content-Type: application/json" \
      "$MC_URL/api/tasks/$task_id" \
      -d "{\"status\":\"failed\",\"outcome\":\"$reason: $(echo "$extra" | cut -c1-200)\"}" > /dev/null 2>&1 || true
  fi
}

# ═══════════════════════════════════════════
# Phase 0: 心跳 — 永远最先执行
# ═══════════════════════════════════════════
echo "[#$GID] $(date '+%H:%M:%S') cron 触发" >&2
if llm_ping; then
  heartbeat
else
  echo "[#$GID] LLM 不通, 心跳跳过" >&2
fi

# ═══════════════════════════════════════════
# ═══ context refresh ═══
MC_API_KEY="$MC_API_KEY" python3 /home/agentuser/.xianqin/packages/context-engine/assemble-v2.py "$GID" 2>/dev/null || true
# Phase 0.5: 锁检查 — 僵尸锁由心跳负责清理
# ═══════════════════════════════════════════
if parse_lock; then
  echo "[#$GID] 发现锁: pid=$LOCK_PID task=#$LOCK_TASK age=${LOCK_AGE}s" >&2
  if is_zombie_lock; then
    echo "[#$GID] 🧹 清理僵尸锁 (task=#$LOCK_TASK)" >&2
    rm -f "$LOCK"
  else
    echo "[#$GID] 锁有效 — 退出" >&2
    exit 0
  fi
fi

# ═══════════════════════════════════════════
# Phase 0.6: 产物自检 + 诊断报告 — 检查上次执行的成果，更新 MC 状态
# ═══════════════════════════════════════════
WIKI_DIR="$HOME/wiki-${GID}/raw"
if [ -d "$WIKI_DIR" ] && [ -n "$MC_API_KEY" ]; then
  # ─── 0.6a: 产物自检（原有逻辑）───
  for rf in "$WIKI_DIR"/task-*-result.md; do
    [ -f "$rf" ] || continue
    tid=$(basename "$rf" | sed 's/task-\([0-9]*\)-result\.md/\1/')
    [ -z "$tid" ] && continue
    
    ts=$(curl -sf -H "x-api-key: $MC_API_KEY" "$MC_URL/api/tasks/$tid" 2>/dev/null | \
         python3 -c "import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,dict) else d[0]; print(d.get('status',''))" 2>/dev/null || echo "")
    
    if [ "$ts" = "in_progress" ]; then
      curl -sf -X PUT -H "x-api-key: $MC_API_KEY" -H "Content-Type: application/json" \
        "$MC_URL/api/tasks/$tid" \
        -d "{\"status\":\"review\",\"outcome\":\"产物已生成: $(basename $rf)\"}" > /dev/null 2>&1 && \
        echo "[#$GID] 📤 产物自检: task=#$tid in_progress→review ($(basename $rf))" >&2
    fi
  done
  
  # ─── 0.6b: 诊断文件检查（v7.4 新增）───
  for df in "$WIKI_DIR"/task-*-diagnostic.json; do
    [ -f "$df" ] || continue
    tid=$(basename "$df" | sed 's/task-\([0-9]*\)-diagnostic\.json/\1/')
    [ -z "$tid" ] && continue
    
    # 读取诊断信息
    reason=$(python3 -c "import json; d=json.load(open('$df')); print(d.get('exit_reason',''))" 2>/dev/null || echo "")
    detail=$(python3 -c "import json; d=json.load(open('$df')); print(d.get('exit_detail','')[:100])" 2>/dev/null || echo "")
    
    ts=$(curl -sf -H "x-api-key: $MC_API_KEY" "$MC_URL/api/tasks/$tid" 2>/dev/null | \
         python3 -c "import json,sys; d=json.load(sys.stdin); d=d if isinstance(d,dict) else d[0]; print(d.get('status',''))" 2>/dev/null || echo "")
    
    # 如果MC状态尚未标记为 failed → 补充上报
    if [ "$ts" != "failed" ] && [ "$ts" != "review" ] && [ "$ts" != "completed" ]; then
      curl -sf -X PUT -H "x-api-key: $MC_API_KEY" -H "Content-Type: application/json" \
        "$MC_URL/api/tasks/$tid" \
        -d "{\"status\":\"failed\",\"outcome\":\"诊断报告: $reason — $detail\"}" > /dev/null 2>&1 && \
        echo "[#$GID] 🩺 诊断上报: task=#$tid failed ($reason)" >&2
    else
      echo "[#$GID] 📋 诊断文件: task=#$tid ($reason) — MC已$ts，跳过上报" >&2
    fi
  done
fi

# ═══════════════════════════════════════════
# Phase 1: 拉任务
# ═══════════════════════════════════════════
cd "$HOME/.xianqin/mc"
RESULT=$(MC_URL="$MC_URL" MC_API_KEY="$MC_API_KEY" MC_AGENT_GLOBAL_ID="$GID" python3 mc-poll.py 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "[#$GID] 巡逻完成(无任务)" >&2
  exit 0
fi

TASK_ID=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null)
TITLE=$(echo "$RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['title'])" 2>/dev/null)
[ -z "$TASK_ID" ] && { echo "[#$GID] 无有效任务" >&2; exit 0; }

# ─── 创建锁: PID:TASK_ID ───
echo "$$:$TASK_ID" > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
echo "[#$GID] 🔒 获取锁 pid=$$ task=#$TASK_ID" >&2

# ═══════════════════════════════════════════
# Phase 2: 执行（v7.4: 后台 + 看门狗 + 超时检测）
# ═══════════════════════════════════════════
# 先定义 RESULT_FILE（看门狗需要）
RESULT_FILE="$HOME/wiki-${GID}/raw/task-${TASK_ID}-result.md"

curl -sf -X PUT -H "x-api-key: $MC_API_KEY" "$MC_URL/api/tasks/$TASK_ID" \
  -H "Content-Type: application/json" \
  -d '{"status":"in_progress"}' > /dev/null 2>&1

echo "[#$GID] ▶ 执行任务 #$TASK_ID: $TITLE (超时=${HERMES_TIMEOUT}s, 卡住检测=${STUCK_TIMEOUT}s)" >&2

PROMPT="【MC任务 #$TASK_ID】$TITLE。

1. 完成代码/测试/文档，写入 ~/wiki-$GID/raw/task-$TASK_ID-result.md（含 ## 决策点 小节）
2. 完成后立即执行上报: curl -sf -X PUT -H 'x-api-key: $MC_API_KEY' -H 'Content-Type: application/json' '$MC_URL/api/tasks/$TASK_ID' -d '{\"status\":\"review\"}'
3. 然后 git add + git commit"

# ─── 注入 Plan-Tree 上下文（如果存在）───
PLANTREE_FILE="$HOME/plan-tree-v4.md"
if [ -f "$PLANTREE_FILE" ]; then
  PLANTREE_CTX=$(head -100 "$PLANTREE_FILE" 2>/dev/null | grep -E "决策|依赖|预测|关联|状态|in_progress|inbox" | head -20 | sed 's/^/  /')
  if [ -n "$PLANTREE_CTX" ]; then
    PROMPT="$PROMPT

【Plan-Tree 上下文 — 当前决策轨迹和跨Agent依赖】
$PLANTREE_CTX"
  fi
fi

HERMES_BIN="${HERMES_BIN:-$HOME/.local/bin/hermes}"
if [ ! -x "$HERMES_BIN" ]; then
  echo "[#$GID] hermes 不可用" >&2
  rm -f "$LOCK"
  exit 0
fi

# ─── v7.4: 后台执行 + 看门狗 ───
HX=0
STUCK_BY_WATCHDOG=0
HERMES_PID=""
WATCHDOG_PID=""

# 启动 hermes（后台，带超时）
timeout "$HERMES_TIMEOUT" "$HERMES_BIN" chat -q "$PROMPT" --yolo --model "$LLM_MODEL" &
HERMES_PID=$!
echo "[#$GID] 🚀 hermes started (pid=$HERMES_PID)" >&2

# ─── 看门狗: 监控产物文件 mtime ───
(
  STAGNANT=0
  LAST_MTIME=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
  
  while kill -0 "$HERMES_PID" 2>/dev/null; do
    sleep "$PROGRESS_CHECK_INTERVAL"
    
    # 检查产物是否有进展
    CURR_MTIME=$(stat -c %Y "$RESULT_FILE" 2>/dev/null || echo 0)
    if [ "$CURR_MTIME" -gt "$LAST_MTIME" ]; then
      LAST_MTIME="$CURR_MTIME"
      STAGNANT=0
      echo "[#$GID] 👁 看门狗: 产物已更新 (${STAGNANT}s 无停滞)" >&2
    else
      STAGNANT=$((STAGNANT + PROGRESS_CHECK_INTERVAL))
      echo "[#$GID] 👁 看门狗: 停滞 ${STAGNANT}s (产物无变化)" >&2
    fi
    
    # 超时检测
    if [ "$STAGNANT" -ge "$STUCK_TIMEOUT" ]; then
      echo "[#$GID] ⏰ 急停! 产物 ${STAGNANT}s 无更新 → 中断 hermes (pid=$HERMES_PID)" >&2
      # 优雅终止
      kill -TERM "$HERMES_PID" 2>/dev/null
      sleep 5
      # 强制终止（如果还活着）
      if kill -0 "$HERMES_PID" 2>/dev/null; then
        kill -KILL "$HERMES_PID" 2>/dev/null
        echo "[#$GID] 💀 强制终止 hermes" >&2
      fi
      # 写入诊断
      write_diagnostic "$TASK_ID" "STUCK" "产物 ${STAGNANT}s 无更新（超时阈值 ${STUCK_TIMEOUT}s）"
      echo "STUCK_BY_WATCHDOG" > "$HOME/.xianqin/mc-poll-${GID}-stuck.flag"
      break
    fi
  done
) &
WATCHDOG_PID=$!

# 等待 hermes 结束
set +e
wait "$HERMES_PID" 2>/dev/null
HX=$?
set -e

# 清理看门狗
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

# 检查是否被看门狗杀死
if [ -f "$HOME/.xianqin/mc-poll-${GID}-stuck.flag" ]; then
  rm -f "$HOME/.xianqin/mc-poll-${GID}-stuck.flag"
  echo "[#$GID] ⏰ 被看门狗急停 — 释放锁" >&2
  exit 0
fi

# 检查是否超时
if [ "$HX" -eq 124 ]; then
  echo "[#$GID] ⏱ hermes 超时 (${HERMES_TIMEOUT}s) — 写入诊断" >&2
  write_diagnostic "$TASK_ID" "TIMEOUT" "hermes 执行超过 ${HERMES_TIMEOUT}s（timeout 命令杀死）"
  exit 0
fi

# 检查 hermes 退出码
if [ "$HX" -ne 0 ]; then
  echo "[#$GID] ❌ hermes 异常退出 (exit=$HX) — 写入诊断" >&2
  write_diagnostic "$TASK_ID" "HERMES_EXIT_$HX" "hermes 退出码=$HX"
  exit 0
fi

# ═══════════════════════════════════════════
# Phase 3: 验证 + 交活 + 销毁锁
# ═══════════════════════════════════════════
if [ ! -s "$RESULT_FILE" ]; then
  echo "[#$GID] ❌ 产物缺失 — 写入诊断" >&2
  write_diagnostic "$TASK_ID" "NO_RESULT" "hermes 成功退出但未生成产物文件"
  exit 0
fi

echo "[#$GID] 📄 产物: $RESULT_FILE ($(wc -l < "$RESULT_FILE") lines)" >&2

# 也检查 Plan-Tree 是否更新
PLANTREE_FILE="$HOME/plan-tree-v4.md"
if [ -f "$PLANTREE_FILE" ]; then
  echo "[#$GID] 🌲 PlanTree: $PLANTREE_FILE ($(wc -l < "$PLANTREE_FILE") lines)" >&2
fi

if llm_ping; then
  heartbeat
  curl -sf -X PUT -H "x-api-key: $MC_API_KEY" "$MC_URL/api/tasks/$TASK_ID" \
    -H "Content-Type: application/json" \
    -d '{"status":"review"}' > /dev/null 2>&1
  echo "[#$GID] ✅ → review | 🔓 锁释放(trap EXIT)" >&2
  
  # ─── Phase 3.5: 增量更新 Plan-Tree（bash 提取，不用 LLM）───
  DECISIONS=$(sed -n '/^## 决策点/,/^## /p' "$RESULT_FILE" 2>/dev/null | grep -E '^\|' | head -10)
  if [ -n "$DECISIONS" ]; then
    NOW=$(date '+%Y-%m-%d %H:%M')
    if [ ! -f "$PLANTREE_FILE" ]; then
      # 首次创建
      cat > "$PLANTREE_FILE" << PTEOF
# $GID Plan-Tree v4 — 自动维护

> 更新: $NOW

## 决策点

| 时间 | 决策 | 选项 | 选择 | 理由 |
|------|------|------|------|------|
PTEOF
    fi
    echo "$DECISIONS" >> "$PLANTREE_FILE"
    echo "[#$GID] 🌲 PlanTree 增量更新 ($(echo "$DECISIONS" | wc -l) 条决策)" >&2
  fi
else
  echo "[#$GID] ⚠️ 执行完但LLM不通 — 释放锁" >&2
fi
# trap EXIT 自动 rm -f "$LOCK"
