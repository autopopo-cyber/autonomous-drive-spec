#!/bin/bash
# install-weixin-patches.sh — 安装微信相关补丁到 hermes-agent
set -e

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes/hermes-agent}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo " 微信补丁安装器"
echo "========================================="

# ─── Patch 1: tool_progress ───
echo ""
echo "[1/2] 微信 tool_progress 补丁"
PATCH_FILE="$PATCH_DIR/0001-feat-gateway-tool-progress-for-non-editing-platforms.patch"

if [ ! -f "$PATCH_FILE" ]; then
    echo "  ❌ patch 文件不存在: $PATCH_FILE"
    exit 1
fi

cd "$HERMES_HOME"

# 检查是否已应用
if git log --oneline -1 | grep -q 'fda6f767'; then
    echo "  ✅ 已应用 (commit fda6f767)"
elif grep -q 'can_edit = not _no_edit_support' gateway/run.py 2>/dev/null; then
    echo "  ✅ 代码已包含修复（可能已手动合并）"
else
    echo "  应用 patch..."
    if git apply --check "$PATCH_FILE" 2>/dev/null; then
        git am "$PATCH_FILE" 2>/dev/null && echo "  ✅ 已应用" || {
            # fallback: direct apply
            git apply "$PATCH_FILE" 2>/dev/null && echo "  ✅ 已应用 (direct)" || echo "  ❌ 应用失败"
        }
    else
        echo "  ⚠️ patch 不兼容当前代码，请手动检查 gateway/run.py:9489"
        echo "  搜索: _no_edit_support = type(adapter).edit_message is BasePlatformAdapter.edit_message"
    fi
fi

# ─── Patch 2: weixin config ───
echo ""
echo "[2/2] 微信断连修复 (config.yaml)"

HERMES_CONFIG="$HOME/.hermes/profiles/xuanxuan/config.yaml"
if [ ! -f "$HERMES_CONFIG" ]; then
    HERMES_CONFIG="$HOME/.hermes/config.yaml"
fi

if grep -q 'weixin:' "$HERMES_CONFIG" 2>/dev/null; then
    echo "  ✅ weixin platform 已配置"
else
    echo "  添加 weixin platform 配置..."
    python3 -c "
import yaml
with open('$HERMES_CONFIG') as f:
    cfg = yaml.safe_load(f)
cfg.setdefault('platforms', {})
cfg['platforms']['weixin'] = {
    'enabled': True,
    'token': '\${WEIXIN_TOKEN}',
    'extra': {
        'account_id': '\${WEIXIN_ACCOUNT_ID}',
        'base_url': '\${WEIXIN_BASE_URL}',
        'dm_policy': '\${WEIXIN_DM_POLICY}',
    }
}
with open('$HERMES_CONFIG', 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False, allow_unicode=True)
" 2>/dev/null && echo "  ✅ 已添加" || echo "  ❌ 添加失败"
fi

echo ""
echo "========================================="
echo " 安装完成。重启 gateway 生效："
echo "   pkill -f 'gateway run'"
echo "   hermes gateway run --accept-hooks &"
echo "========================================="