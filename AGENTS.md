# AGENTS.md · 本仓库的 Agent 规则

> 这里只放**指针和纪律**，不放记忆内容。适用于 Codex / Claude Code / Trae 等读工作区规则的 harness。

## 第一步：判断是否已实例化

读 `mind.config` 的 `PERSONA_NAME`：

- **仍是 `__PERSONA__`（模板态）** → 先读 `START-HERE.md`，按 `99-系统/首次唤醒引导.md` 执行首次构建。
  **在实例化完成前，不要写入任何记忆，不要创建 `thread-*`，不要编造用户信息。**
- **已是真实名字（已实例化）** → 按下面的唤醒协议执行。

## 唤醒协议（已实例化）

1. 执行唤醒：
   - POSIX / 云端：`bash 99-系统/scripts/wake.sh`
   - Windows：`powershell -File 99-系统\scripts\wake.ps1`
2. 按输出读取 `SOUL.md` → `HOME.md`，再按当前线程类型**按需**检索。
   线程类型 → 读取范围见 `99-系统/唤醒协议.md`；**禁止全文通读记忆库**。
3. 写记忆前先 `git pull --rebase`，小步提交，写完立即 `git push`。
4. `GH_TOKEN` 不可用时脚本会降级运行 —— 如实向用户报告记忆新鲜度，不装新知。
5. 改动 `SOUL.md` 必须告诉用户。

## 云端一次性沙箱

`/workspace` 可能随线程消亡：本地副本不存在时先 `git clone <REPO_SLUG>`（从 `mind.config` 读，或向用户索取仓库地址），再执行 wake；每次写入后立即推送，仓库里不留唯一副本。

## 隐私红线

`50-用户档案/user-profile.md` 只存本地，永不入云；不要把它复制进任何其它笔记。token 只从环境变量读取，不写入被跟踪文件。
