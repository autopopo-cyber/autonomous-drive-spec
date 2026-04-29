# 微信 Tool Progress Patch

> 版本: v1.0 | 日期: 2026-04-29 | 目标: hermes-agent gateway/run.py

## 问题

微信（WeChat）不支持消息编辑，hermes gateway 在发送工具执行进度时，
检测到平台不支持编辑后，**直接丢弃所有进度消息**。

微信用户看不到任何中间进度（"正在执行 terminal..."等）。

## 修复

对不支持编辑的平台，降级为**发新消息**（而非编辑消息），每条工具调用
以独立消息发送，并做节流控制避免触发微信频率限制。

## 涉及文件

- `gateway/run.py` — `send_progress_messages()` 函数

## Git 提交

```
fda6f767 feat(gateway): tool progress for non-editing platforms (WeChat)
```

## 安装

```bash
cd ~/.hermes/hermes-agent
git cherry-pick fda6f767
```

如果 hermes 已升级且该提交不在新版本中，手动应用 `weixin-progress.patch`：

```bash
cd ~/.hermes/hermes-agent
git apply /path/to/weixin-progress.patch
```

应用后重启 gateway：

```bash
pkill -f 'gateway run'
hermes gateway run --accept-hooks &
```

## 验证

执行任意需要工具调用的任务，微信端应看到：

```
📞 terminal: apt install...
📄 write_file: main.py...
🔍 web_search: ...
```

## 升级注意

hermes 升级后，检查 `gateway/run.py:9489` 附近是否包含 `can_edit = not _no_edit_support`。
如果不包含，重新应用此 patch。
