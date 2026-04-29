#!/bin/bash
# context-engine selftest — 验证所有 agent context 生成正确性
set -e

PASS=0
FAIL=0
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ASSEMBLER="$PACKAGE_DIR/assemble-v2.py"
CONTEXT_HOME="${CONTEXT_HOME:-$HOME/.xianqin/context}"

echo "========================================="
echo " context-engine 自测"
echo "========================================="

# ─── Test 1: 组装器可执行 ───
echo -n "[TEST 1] 组装器语法检查... "
if python3 -c "import py_compile; py_compile.compile('$ASSEMBLER', doraise=True)" 2>/dev/null; then
    echo "✅"
    PASS=$((PASS+1))
else
    echo "❌"
    FAIL=$((FAIL+1))
fi

# ─── Test 2-9: 每个 agent 生成 context ───
for gid in 101 102 103 104 105 106 107 108; do
    echo -n "[TEST $((gid-99+1))] GID=$gid context 生成... "
    if MC_API_KEY="${MC_API_KEY:-}" python3 "$ASSEMBLER" "$gid" > /dev/null 2>&1; then
        ctx_dir="$CONTEXT_HOME/$gid"
        # 验证文件存在
        errors=0
        [ -f "$ctx_dir/prefill.json" ] || { echo -n " NO_PREFILL"; errors=1; }
        [ -f "$ctx_dir/context-pack.md" ] || { echo -n " NO_CONTEXT_MD"; errors=1; }
        # 验证 prefill.json 是合法 JSON 数组
        python3 -c "import json; d=json.load(open('$ctx_dir/prefill.json')); assert isinstance(d,list); assert d[0]['role']=='system'" 2>/dev/null || { echo -n " INVALID_JSON"; errors=1; }
        # 验证内容不为空
        lines=$(wc -l < "$ctx_dir/context-pack.md" 2>/dev/null || echo 0)
        [ "$lines" -ge 10 ] || { echo -n " TOO_SHORT($lines)"; errors=1; }
        if [ $errors -eq 0 ]; then
            echo "✅"
            PASS=$((PASS+1))
        else
            echo " ❌"
            FAIL=$((FAIL+1))
        fi
    else
        echo "❌ (assembler crash)"
        FAIL=$((FAIL+1))
    fi
done

# ─── Test 10: MC 不可达时降级 ───
echo -n "[TEST 10] MC不可达时优雅降级... "
if MC_URL="http://dead:1" MC_API_KEY="bad" python3 "$ASSEMBLER" 105 > /dev/null 2>&1; then
    ctx="$CONTEXT_HOME/105/context-pack.md"
    if grep -q "在线: —" "$ctx" && grep -q "持久记忆" "$ctx"; then
        echo "✅ (舰队=空, 记忆=保留)"
        PASS=$((PASS+1))
    else
        echo "❌ (降级不完整)"
        FAIL=$((FAIL+1))
    fi
else
    echo "❌ (崩溃)"
    FAIL=$((FAIL+1))
fi

# ─── Test 11: 防覆写验证（持久文件不被组装器修改）───
echo -n "[TEST 11] 组装器不覆写持久文件... "
# 记录当前文件 mtime
declare -A MTIMES_BEFORE
for f in identity memory plantree focus fleet-graph; do
    MTIMES_BEFORE[$f]=$(stat -c %Y "$CONTEXT_HOME/105/${f}.json" 2>/dev/null || echo 0)
done
# 运行组装器
MC_API_KEY="${MC_API_KEY:-}" python3 "$ASSEMBLER" 105 > /dev/null 2>&1
# 检查 mtime 不变
errors=0
for f in identity memory plantree focus fleet-graph; do
    after=$(stat -c %Y "$CONTEXT_HOME/105/${f}.json" 2>/dev/null || echo 0)
    if [ "$after" != "${MTIMES_BEFORE[$f]}" ]; then
        echo -n " ${f}:MODIFIED"
        errors=1
    fi
done
if [ $errors -eq 0 ]; then
    echo "✅ (所有持久文件未修改)"
    PASS=$((PASS+1))
else
    echo " ❌"
    FAIL=$((FAIL+1))
fi

echo ""
echo "========================================="
echo " 结果: $PASS PASS, $FAIL FAIL"
echo "========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1