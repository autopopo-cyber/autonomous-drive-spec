#!/bin/bash
# init-context.sh — 为指定 agent 创建初始 context 文件（幂等，不覆盖已有）
# 用法: ./init-context.sh <GID> [agent_name]

set -e
CONTEXT_HOME="${CONTEXT_HOME:-$HOME/.xianqin/context}"
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$PACKAGE_DIR/templates"

GID="$1"
NAME="${2:-Agent-$GID}"

if [ -z "$GID" ]; then
    echo "用法: init-context.sh <GID> [agent_name]"
    exit 1
fi

CTX="$CONTEXT_HOME/$GID"
mkdir -p "$CTX"/{backups,tmp}

echo "初始化 $NAME (GID=$GID) → $CTX"

# 幂等：已存在的文件不覆盖
for tmpl in identity memory plantree focus; do
    if [ ! -f "$CTX/${tmpl}.json" ]; then
        sed "s/__GID__/$GID/g; s/__NAME__/$NAME/g" "$TEMPLATES/${tmpl}.json.tmpl" > "$CTX/${tmpl}.json"
        echo "  ✅ ${tmpl}.json"
    else
        echo "  ⏭️ ${tmpl}.json (已存在)"
    fi
done

# fleet-graph 全局共享
if [ ! -f "$CTX/fleet-graph.json" ]; then
    cp "$TEMPLATES/fleet-graph.json" "$CTX/fleet-graph.json"
    echo "  ✅ fleet-graph.json"
fi

echo "完成。运行 assemble-v2.py $GID 测试。"