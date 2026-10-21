#!/usr/bin/env bash
# ============================================================
# MindSeed 唤醒脚本 · wake.sh
# 用途：新会话开始时一条命令完成「定位 → 凭证 → 拉取 → 失败诊断 → 补推 → 新鲜度」
# 用法：bash 99-系统/scripts/wake.sh
# 前提：环境变量 GH_TOKEN（对本仓库有 contents 读写权限；无 token 时降级运行）
# 设计文档：99-系统/托管规范.md · 99-系统/唤醒协议.md
# ============================================================
set -uo pipefail

log()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }

# ---------- ② 定位 / 获取本地副本（脚本自定位优先） ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${MINDSEED_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

if [ ! -d "$REPO_DIR/.git" ]; then
  REPO_DIR=""
  for d in "/workspace/mindseed" "$HOME/mindseed" "$HOME/workspace/mindseed" "$PWD/mindseed"; do
    [ -d "$d/.git" ] && REPO_DIR="$d" && break
  done
fi

CONFIG=""
[ -n "$REPO_DIR" ] && CONFIG="$REPO_DIR/mind.config"

cfg() {
  [ -n "$CONFIG" ] && [ -f "$CONFIG" ] || return 0
  grep -m1 -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null \
    | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r'
}

# 未找到副本时，先读一份临时配置判断能否克隆
if [ -z "$REPO_DIR" ]; then
  for d in "/workspace/mindseed" "$HOME/mindseed" "$PWD/mindseed"; do
    [ -f "$d/mind.config" ] && CONFIG="$d/mind.config" && break
  done
fi

REPO_SLUG="$(cfg REPO_SLUG)"
PERSONA_NAME="$(cfg PERSONA_NAME)"
PERSONA_ROLE="$(cfg PERSONA_ROLE)"
USER_NAME="$(cfg USER_NAME)"

INSTANTIATED="yes"
case "$PERSONA_NAME" in ""|*__*) INSTANTIATED="no" ;; esac
case "$PERSONA_ROLE" in ""|*__*) INSTANTIATED="no" ;; esac
case "$USER_NAME" in ""|*__*) INSTANTIATED="no" ;; esac
case "$REPO_SLUG" in ""|*__*) INSTANTIATED="no" ;; esac

# ---------- ① 凭证注入（token 不落盘、不进命令行） ----------
HAS_CREDS="no"
if [ -z "${GH_TOKEN:-}" ]; then
  warn "GH_TOKEN 未设置，跳过网络操作（将以本地副本降级运行）"
elif [ "$INSTANTIATED" != "yes" ]; then
  warn "尚未实例化（mind.config 仍为占位符），跳过网络操作"
else
  export GIT_TERMINAL_PROMPT=0
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="http.extraheader"
  export GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
  HAS_CREDS="yes"
fi

if [ -z "$REPO_DIR" ]; then
  if [ "$HAS_CREDS" = "yes" ]; then
    log "🛰️  未发现本地副本，尝试从 GitHub 克隆…"
    if git clone "https://github.com/${REPO_SLUG}.git" "/workspace/mindseed" 2>/dev/null; then
      REPO_DIR="/workspace/mindseed"
      CONFIG="$REPO_DIR/mind.config"
      REPO_SLUG="$(cfg REPO_SLUG)"
      PERSONA_NAME="$(cfg PERSONA_NAME)"
    else
      warn "克隆失败：网络 / 凭证不可用，且无本地副本 —— 本次处于失忆状态，请如实告知用户"
      exit 2
    fi
  else
    exit 2
  fi
fi

cd "$REPO_DIR" || exit 2
STATE_FILE="${MINDSEED_WAKE_STATE:-$HOME/.mindseed-wake-state}"

# ---------- ③ 同步远端（pull --rebase，自动 stash 容错 + 失败原因分类） ----------
HAS_UPSTREAM="no"
git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 && HAS_UPSTREAM="yes"

PULLED="skipped"
if [ "$HAS_CREDS" = "yes" ] && [ "$HAS_UPSTREAM" = "yes" ]; then
  STASHED="no"
  if [ -n "$(git status --porcelain)" ]; then
    if git stash push -q -m "wake-autostash"; then STASHED="yes"
    else warn "本地改动暂存失败（stash push 出错），pull 可能被脏工作区挡住"
    fi
  fi
  PULL_ERR=$(git pull --rebase -q 2>&1)
  PULL_RC=$?
  if [ "$PULL_RC" -eq 0 ]; then
    PULLED="yes"
  else
    warn "pull --rebase 失败，以本地副本降级运行（改动不会丢失，下次补同步）"
    case "$PULL_ERR" in
      *"Could not connect"*|*"Could not resolve"*|*"Failed to connect"*|*"unable to access"*|*proxy*|*"Timed out"*|*Timeout*)
        log "   ↳ 原因：网络 / 代理不通，拉不到 github.com —— 检查代理与 http.proxy（见 99-系统/托管规范.md 5.2）" ;;
      *"unstaged changes"*|*"cannot pull with rebase"*|*"Your local changes"*|*"would be overwritten"*)
        log "   ↳ 原因：工作区有未提交改动挡住了 rebase —— 先 git status 看清，视情况 commit 或 git stash" ;;
      *CONFLICT*|*"could not apply"*|*"Resolve all conflicts"*)
        log "   ↳ 原因：出现真冲突，rebase 可能停在中途 —— 处理完 git rebase --continue，或 git rebase --abort 回到原状" ;;
      *)
        log "   ↳ 原因未识别（可能是本地化报错），原始输出如下："
        printf '%s\n' "$PULL_ERR" | head -5 | sed 's/^/     /' ;;
    esac
    BEHIND=$(git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
    case "$BEHIND" in ''|*[!0-9]*) BEHIND=0 ;; esac
    if [ "$BEHIND" -gt 0 ]; then
      log "   ↳ 按上次成功同步的记录，本地至少落后远端 ${BEHIND} 条提交"
    fi
  fi
  if [ "$STASHED" = "yes" ]; then
    if ! git stash pop -q 2>/dev/null; then
      warn "自动暂存的改动未能放回！它们安全地留在 stash 里 —— 用 git stash list 查看、git stash pop 手动恢复"
    fi
  fi
fi

# ---------- ④ 补推上次未推送的本地 commit ----------
if [ "$HAS_CREDS" = "yes" ] && [ "$HAS_UPSTREAM" = "yes" ]; then
  PENDING=$(git log --oneline '@{u}..HEAD' 2>/dev/null | wc -l | tr -d ' ')
  if [ "${PENDING:-0}" -gt 0 ]; then
    log "📤 发现 $PENDING 条未推送的本地记忆，补推中…"
    git push -q 2>/dev/null && log "✅ 补推完成" || warn "补推失败，commit 仍安全在本地，下次再试"
  fi
fi

# ---------- ⑤ 新鲜度报告 ----------
HEAD_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "no-commit")
HEAD_DATE=$(git log -1 --format=%cd --date=short 2>/dev/null || echo "-")
log ""
log "📂 心智库：$REPO_DIR"
if [ "$INSTANTIATED" = "yes" ]; then
  log "👤 人格：$PERSONA_NAME"
fi
log "🧠 记忆新鲜度：截至 ${HEAD_HASH}（${HEAD_DATE}）"
if [ "$HAS_UPSTREAM" = "no" ]; then
  log "ℹ️  未配置远端（本地模式）"
elif [ "$PULLED" != "yes" ]; then
  log "⚠️  本次未成功同步远端 —— 上面这个新鲜度只是本地副本状态，未必等于远端最新"
fi
if [ -f "$STATE_FILE" ]; then
  LAST=$(cat "$STATE_FILE" 2>/dev/null)
  if [ -n "$LAST" ] && [ "$LAST" != "$HEAD_HASH" ] && git rev-parse --verify "$LAST" >/dev/null 2>&1; then
    log ""
    log "📜 自上次唤醒以来的变化："
    git log --format='  %h %s' "${LAST}..HEAD" | head -10
  fi
else
  log "📜 最近 3 条记忆动态："
  git log --format='  %h %s' -3 2>/dev/null || log "  （尚无提交）"
fi
echo "$HEAD_HASH" > "$STATE_FILE" 2>/dev/null || true

# ---------- ⑥ 隐私防呆 ----------
if git ls-files | grep -q "user-profile"; then
  warn "隐私文件 user-profile 被跟踪！立即停止写入并排查！"
fi

# ---------- ⑦ 唤醒指引 ----------
log ""
if [ "$INSTANTIATED" != "yes" ]; then
  log "🌱 当前是模板态（mind.config 仍为占位符）"
  log "📖 请读 START-HERE.md，按 99-系统/首次唤醒引导.md 完成首次构建；构建完成前不要写入记忆。"
else
  log "📖 请按顺序读取：SOUL.md → HOME.md → 按话题按需检索（禁止全文通读）"
  log "   线程类型 → 读取范围见 99-系统/唤醒协议.md"
  log "✨ 心智库已就绪。"
fi
