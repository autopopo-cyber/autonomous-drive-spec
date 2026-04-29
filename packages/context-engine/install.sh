#!/bin/bash
# context-engine install — 为指定 agent 安装上下文引擎
# 用法: ./install.sh [GID]  不加参数=安装全部8个agent

set -e
CONTEXT_HOME="${CONTEXT_HOME:-$HOME/.xianqin/context}"
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSEMBLER="$PACKAGE_DIR/assemble-v2.py"
TEMPLATES="$PACKAGE_DIR/templates"

# 舰队 agent 清单
declare -A AGENT_NAMES
AGENT_NAMES[101]="相邦"
AGENT_NAMES[102]="白起"
AGENT_NAMES[103]="王翦"
AGENT_NAMES[104]="丞相"
AGENT_NAMES[105]="萱萱"
AGENT_NAMES[106]="俊秀"
AGENT_NAMES[107]="雪莹"
AGENT_NAMES[108]="红婳"

GID="${1:-}"
if [ -z "$GID" ]; then
    GIDS="101 102 103 104 105 106 107 108"
else
    GIDS="$GID"
fi

install_agent() {
    local gid="$1"
    local name="${AGENT_NAMES[$gid]}"
    local ctx_dir="$CONTEXT_HOME/$gid"
    
    echo "=== 安装 $name (GID=$gid) ==="
    mkdir -p "$ctx_dir"/{backups,tmp}
    
    # 1. 初始化 context 文件（不覆盖已存在的）
    for tmpl in identity memory plantree focus; do
        if [ ! -f "$ctx_dir/${tmpl}.json" ]; then
            if [ -f "$TEMPLATES/${tmpl}.json.tmpl" ]; then
                sed "s/__GID__/$gid/g; s/__NAME__/$name/g" "$TEMPLATES/${tmpl}.json.tmpl" > "$ctx_dir/${tmpl}.json"
                echo "  创建 ${tmpl}.json"
            else
                echo "  ⚠️ 模板 ${tmpl}.json.tmpl 不存在，跳过"
            fi
        else
            echo "  ${tmpl}.json 已存在，保留"
        fi
    done
    
    # fleet-graph.json 全舰队共享（软链或复制）
    if [ ! -f "$ctx_dir/fleet-graph.json" ]; then
        cp "$TEMPLATES/fleet-graph.json" "$ctx_dir/fleet-graph.json"
        echo "  创建 fleet-graph.json（全局共享）"
    fi
    
    # 2. 测试运行一次
    echo "  运行组装器..."
    MC_API_KEY="${MC_API_KEY:-}" python3 "$ASSEMBLER" "$gid" 2>/dev/null && echo "  ✅ 组装成功" || echo "  ❌ 组装失败"
    
    # 3. 显示输出统计
    if [ -f "$ctx_dir/context-pack.md" ]; then
        echo "  context-pack.md: $(wc -l < "$ctx_dir/context-pack.md") lines"
    fi
    
    # 4. 创建每日备份目录
    mkdir -p "$ctx_dir/backups"
}

for gid in $GIDS; do
    install_agent "$gid"
done

echo ""
echo "安装完成。下一步："

# ─── 灌顶：从wiki提取知识 ───
if [ -f "$PACKAGE_DIR/bootstrap-init.py" ]; then
  MC_API_KEY="${MC_API_KEY:-}" python3 "$PACKAGE_DIR/bootstrap-init.py" "$gid" 2>/dev/null || true
fi
echo "1. 配置 cron: context-assembler (每分钟) + context-backup (每天03:00)"
echo "2. 配置 hermes config.yaml: prefill_messages_file → prefill.json"
echo "3. 运行自测: ./scripts/selftest.sh"