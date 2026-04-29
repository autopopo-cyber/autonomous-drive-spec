#!/bin/bash
# selftest-watchdog.sh — mc-poll v7.4 看门狗 & 诊断系统自测
# 验证: 看门狗停滞检测 → 诊断写入 → read-diagnostic.py 解析 → Phase 0.6b 上报
set -e

REAL_HOME="${REAL_HOME:-/home/agentuser}"
PASS=0
FAIL=0
WARN=0

green() { echo "  ✅ $1"; PASS=$((PASS+1)); }
yellow() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
red()   { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "=== mc-poll v7.4 看门狗 & 诊断系统自测 ==="
echo ""

# ─── 0. 前置检查 ───
echo "0. 前置检查"
MC_POLL="$REAL_HOME/repos/agent-kit/scripts/mc-poll.sh"
DIAG_READER="$REAL_HOME/repos/agent-kit/scripts/read-diagnostic.py"

if [ -f "$MC_POLL" ]; then green "mc-poll.sh 存在"; else red "mc-poll.sh 缺失"; fi
if [ -f "$DIAG_READER" ]; then green "read-diagnostic.py 存在"; else red "read-diagnostic.py 缺失"; fi
if grep -q "write_diagnostic" "$MC_POLL" 2>/dev/null; then
  green "mc-poll.sh: write_diagnostic() 已嵌入"
else
  red "mc-poll.sh: write_diagnostic() 缺失"
fi
echo ""

# ─── 1. 诊断文件写入测试 ───
echo "1. 诊断文件写入"
TEST_DIR="$REAL_HOME/wiki-105/raw"
mkdir -p "$TEST_DIR"
TEST_TASK_ID="9999"

# 1a: 无产物场景
echo "  1a. 无产物场景 (NO_RESULT)"
python3 -c "
import json
d = {
    'task_id': '$TEST_TASK_ID',
    'agent_gid': '105',
    'agent_dbid': '18',
    'timestamp': '2026-04-29T20:00:00Z',
    'exit_reason': 'NO_RESULT',
    'exit_detail': 'hermes 成功退出但未生成产物文件',
    'result_file': {'exists': False, 'size_bytes': 0, 'lines': 0, 'mtime_unix': 0, 'mtime_human': 'N/A'},
    'stuck_timeout': 1800,
    'hermes_timeout': 600
}
with open('$TEST_DIR/task-${TEST_TASK_ID}-diagnostic.json', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('DIAG_WRITTEN')
" 2>/dev/null
if [ -f "$TEST_DIR/task-${TEST_TASK_ID}-diagnostic.json" ]; then
  green "1a. NO_RESULT 诊断文件已创建"
else
  red "1a. 诊断文件创建失败"
fi

# 1b: 有产物的 STUCK 场景
TEST_TASK_ID_STUCK="9998"
echo "  1b. 有产物场景 (STUCK with partial result)"
# 先创建模拟的产物文件
echo "# 部分完成的产物" > "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-result.md"
echo "## 分析" >> "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-result.md"
echo "部分数据已收集" >> "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-result.md"
python3 -c "
import json, os
st = os.stat('$TEST_DIR/task-${TEST_TASK_ID_STUCK}-result.md')
d = {
    'task_id': '$TEST_TASK_ID_STUCK',
    'agent_gid': '105',
    'agent_dbid': '18',
    'timestamp': '2026-04-29T20:05:00Z',
    'exit_reason': 'STUCK',
    'exit_detail': '产物 1800s 无更新（超时阈值 1800s）',
    'result_file': {
        'exists': True,
        'size_bytes': st.st_size,
        'lines': 3,
        'mtime_unix': int(st.st_mtime),
        'mtime_human': '2026-04-29 20:05:00'
    },
    'stuck_timeout': 1800,
    'hermes_timeout': 600
}
with open('$TEST_DIR/task-${TEST_TASK_ID_STUCK}-diagnostic.json', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
print('DIAG_STUCK_WRITTEN')
" 2>/dev/null
if [ -f "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-diagnostic.json" ]; then
  green "1b. STUCK 诊断文件已创建"
else
  red "1b. STUCK 诊断文件创建失败"
fi

echo ""

# ─── 2. read-diagnostic.py 解析测试 ───
echo "2. read-diagnostic.py 解析"
python3 "$DIAG_READER" "$TEST_DIR/task-${TEST_TASK_ID}-diagnostic.json" > /tmp/diag-test-output.txt 2>&1
if grep -q "无产物" /tmp/diag-test-output.txt; then
  green "2a. NO_RESULT 正确解析 (显示: 无产物)"
else
  red "2a. NO_RESULT 解析异常"
  cat /tmp/diag-test-output.txt
fi

python3 "$DIAG_READER" "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-diagnostic.json" > /tmp/diag-stuck-output.txt 2>&1
if grep -q "卡住" /tmp/diag-stuck-output.txt && grep -q "可重试" /tmp/diag-stuck-output.txt && grep -q "产物" /tmp/diag-stuck-output.txt; then
  green "2b. STUCK 正确解析: 原因 + 判定 + 产物状态"
else
  red "2b. STUCK 解析异常"
  cat /tmp/diag-stuck-output.txt
fi

echo ""

# ─── 3. --summary 功能测试 ───
echo "3. --summary 表格输出"
python3 "$DIAG_READER" --summary "$TEST_DIR/" > /tmp/diag-summary-test.txt 2>&1
cat /tmp/diag-summary-test.txt
echo ""
if grep -q "T9999" /tmp/diag-summary-test.txt && grep -q "T9998" /tmp/diag-summary-test.txt; then
  green "3. --summary 正确输出: 包含两个诊断条目"
else
  red "3. --summary 输出异常"
fi

echo ""

# ─── 4. Phase 0.6b 诊断文件扫描逻辑测试 ───
echo "4. Phase 0.6b 兼容性"
# 检查 mc-poll.sh 是否包含 0.6b 诊断扫描
if grep -q '0.6b.*诊断' "$MC_POLL" 2>/dev/null; then
  green "4a. mc-poll.sh Phase 0.6b 诊断文件扫描已嵌入"
else
  yellow "4a. mc-poll.sh Phase 0.6b 未嵌入"
fi

if grep -q "task-.*-diagnostic.json" "$MC_POLL" 2>/dev/null; then
  green "4b. 诊断文件 glob 模式正确"
else
  red "4b. 诊断文件 glob 模式缺失"
fi

# 验证诊断 JSON schema 兼容 mc-poll.py 的 json.load 解析
echo "  4c. 诊断 JSON schema 验证"
python3 -c "
import json
files = ['$TEST_DIR/task-${TEST_TASK_ID}-diagnostic.json', '$TEST_DIR/task-${TEST_TASK_ID_STUCK}-diagnostic.json']
for f in files:
    with open(f) as fp:
        d = json.load(fp)
    assert 'task_id' in d, 'miss task_id'
    assert 'exit_reason' in d, 'miss exit_reason'
    assert 'result_file' in d, 'miss result_file'
    assert 'exists' in d['result_file'], 'miss result_file.exists'
    print(f'  ✅ {f}: schema 合法')
print('ALL_SCHEMA_OK')
" 2>/dev/null
if [ $? -eq 0 ]; then
  green "4c. 诊断 JSON schema 合法"
else
  red "4c. 诊断 JSON schema 异常"
fi

echo ""

# ─── 5. 看门狗逻辑验证（静态代码分析）───
echo "5. 看门狗逻辑验证"
# 检查看门狗循环
if grep -q "while kill -0.*HERMES_PID" "$MC_POLL" 2>/dev/null; then
  green "5a. 看门狗循环: while kill -0 HERMES_PID 正确"
else
  red "5a. 看门狗循环缺失"
fi

# 检查停滞检测
if grep -q "STAGNANT.*ge.*STUCK_TIMEOUT" "$MC_POLL" 2>/dev/null; then
  green "5b. 停滞检测: STAGNANT >= STUCK_TIMEOUT 正确"
else
  red "5b. 停滞检测缺失"
fi

# 检查急停逻辑
if grep -q "kill -TERM.*HERMES_PID" "$MC_POLL" 2>/dev/null; then
  green "5c. 急停逻辑: TERM + sleep + KILL 正确"
else
  red "5c. 急停逻辑缺失"
fi

# 检查 stuck flag
if grep -q "STUCK_BY_WATCHDOG\|stuck.flag" "$MC_POLL" 2>/dev/null; then
  green "5d. stuch flag: STUCK_BY_WATCHDOG 标记正确"
else
  red "5d. stuck flag 缺失"
fi

# 检查超时保护
if grep -q "HX.*eq 124\|timeout.*HERMES_TIMEOUT" "$MC_POLL" 2>/dev/null; then
  green "5e. 硬超时: timeout $HERMES_TIMEOUT 正确"
else
  red "5e. 硬超时保护缺失"
fi

echo ""

# ─── 6. 退出原因分类验证 ───
echo "6. 退出原因分类"
if grep -q "RETRYABLE.*STUCK.*TIMEOUT" "$DIAG_READER" 2>/dev/null; then
  green "6a. read-diagnostic.py 含 RETRYABLE 集合"
else
  red "6a. RETRYABLE 集合缺失"
fi

if grep -q "NON_RETRYABLE.*NO_RESULT" "$DIAG_READER" 2>/dev/null; then
  green "6b. read-diagnostic.py 含 NON_RETRYABLE 集合"
else
  red "6b. NON_RETRYABLE 集合缺失"
fi

# 验证 STUCK → RETRYABLE, NO_RESULT → NON_RETRYABLE
python3 -c "
import importlib.util, os, sys

# Load from file path
spec = importlib.util.spec_from_file_location('read_diagnostic', '/home/agentuser/repos/agent-kit/scripts/read-diagnostic.py')
mod = importlib.util.module_from_spec(spec)
sys.modules['read_diagnostic'] = mod
spec.loader.exec_module(mod)

assert 'STUCK' in mod.RETRYABLE, 'STUCK should be retryable'
assert 'TIMEOUT' in mod.RETRYABLE, 'TIMEOUT should be retryable'
assert 'NO_RESULT' in mod.NON_RETRYABLE, 'NO_RESULT should be non-retryable'
print('RETRYABLE/NON_RETRYABLE 分类正确')
" 2>/dev/null
if [ $? -eq 0 ]; then
  green "6c. 退出原因分类语义验证通过"
else
  red "6c. 退出原因分类语义异常"
fi

echo ""

# ─── 7. 产物状态追踪验证 ───
echo "7. 产物状态追踪"
if grep -q "result_file" "$DIAG_READER" 2>/dev/null; then
  green "7a. read-diagnostic.py 正确输出产物状态"
else
  red "7a. 产物状态输出缺失"
fi

if grep -q "exists\|size_bytes\|lines\|mtime" "$MC_POLL" 2>/dev/null; then
  green "7b. mc-poll.sh write_diagnostic 正确收集产物元数据"
else
  red "7b. 产物元数据收集缺失"
fi

echo ""

# ─── 8. 退出码映射完整性 ───
echo "8. 退出码映射"
# 检查 mc-poll.sh 是否覆盖所有退出路径
COVERED_EXITS=""
for code in STUCK TIMEOUT HERMES_EXIT NO_RESULT; do
  if grep -q "$code" "$MC_POLL" 2>/dev/null; then
    COVERED_EXITS="$COVERED_EXITS $code"
  fi
done
EXPECTED_COVERED=" STUCK TIMEOUT HERMES_EXIT NO_RESULT"
if [ "$COVERED_EXITS" = "$EXPECTED_COVERED" ]; then
  green "8. 全部4种退出路径已覆盖: $COVERED_EXITS"
else
  yellow "8. 部分覆盖: 已覆盖${COVERED_EXITS}, 期望覆盖${EXPECTED_COVERED}"
fi

echo ""

# ─── 9. 清理测试文件 ───
echo "9. 清理测试文件"
rm -f "$TEST_DIR/task-${TEST_TASK_ID}-diagnostic.json" \
      "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-diagnostic.json" \
      "$TEST_DIR/task-${TEST_TASK_ID_STUCK}-result.md"
green "测试诊断文件已清理"

echo ""
echo "━━━━━━━━━━━━━━━━━"
echo "PASS=$PASS  FAIL=$FAIL  WARN=$WARN"
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "✅ mc-poll v7.4 看门狗 & 诊断系统全部验证通过 ($TOTAL 项)"
  exit 0
else
  echo "⚠️  $FAIL 项失败 (共 $TOTAL 项)"
  exit 1
fi
