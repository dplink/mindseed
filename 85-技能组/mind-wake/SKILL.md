---
name: "mind-wake"
description: "心智库唤醒。在无持久化工作区的云端 harness（Trae 沙箱等）中加载一座 MindSeed 心智库：定位或克隆副本 → 读 mind.config → 执行 wake.sh → 读 SOUL/HOME → 按线程类型按需检索。当用户说「唤醒」「记忆唤醒」「醒来」，或会话涉及该人格身份/记忆/心智库读写时使用。"
---

# 心智库唤醒协议 · Mind Wake

> 用途：无持久化工作区的云端 harness（Trae 等）手动加载心智库。
> 本 skill 只放「指针和纪律」，不放记忆内容；协议本体以库内 `99-系统/唤醒协议.md` 为准，本文件是其「手动唤醒（命令 / skill）」载体的最小自举入口。

## 唤醒步骤

1. **定位副本**（按序）：
   - 环境变量 `MINDSEED_DIR`
   - `/workspace/mindseed`
   - `$HOME/mindseed`
   - 当前工作目录下的 `mindseed`
   - 都没有 → 向用户索取仓库地址，然后：
     `git clone <REPO_URL> /workspace/mindseed`
     （私密库；`GH_TOKEN` 由用户会话临时注入环境变量，不写入任何被跟踪文件）
2. **读配置**：打开 `<REPO_DIR>/mind.config`。
   - `PERSONA_NAME=__PERSONA__` → 尚未实例化，不要唤醒；改读 `START-HERE.md` 走首次构建。
   - 已是真实名字 → 继续。
3. **执行唤醒**：`bash "$REPO_DIR/99-系统/scripts/wake.sh"` —— 一条命令完成：写前 pull → 补推本地未推送 commit → 输出记忆新鲜度与远端动态。
4. **按 wake 输出读取** `SOUL.md` → `HOME.md`，再按当前线程类型**按需**检索（类型 → 读取范围的映射见库内 `99-系统/唤醒协议.md`）。**禁止全文通读记忆库。**
5. **写入记忆**：写前 pull，小步提交；云端沙箱随线程消亡 → **每次写入后立即推送**，仓库里不留唯一副本。完整规范见库内 `99-系统/托管规范.md`。
6. **诚实降级**：`GH_TOKEN` 不可用时 wake 以本地副本降级运行——如实向用户报告记忆新鲜度，不装新知。

## 维护纪律

- 本 skill 的**源文件**在库内 `85-技能组/mind-wake/SKILL.md`（vault 为唯一事实源）；装载到 harness 的是副本，**更新 skill 后必须重新装载**，防止双副本漂移。
- 唤醒流程有变：先改库内协议文档，再同步本 skill。
