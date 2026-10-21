#!/usr/bin/env bash
# ============================================================
# MindSeed 图库工具 · vision.sh（可选模块）
# 用途：对独立私密图库按 GitHub Contents API 按需读写（图库永不 clone）
# 用法：
#   vision.sh ls [dir]                  列目录（默认根）
#   vision.sh get <repo路径> [输出路径]   取图到本地（默认 /tmp/），供多模态 Read 回看
#   vision.sh put <本地文件> <repo路径>   上传图片，打印可贴进 md 的 gh 链接
# 前提：mind.config 中 VISION_ENABLED=1、VISION_REPO_SLUG 已填
#      环境变量 GH_TOKEN 对图库有 contents 读写权限
# 设计文档：本目录 图库规范.md · 99-系统/命名与规范.md
# 作者：洛芙 & 墨铃 · https://github.com/dplink/mindseed
# 路径：支持中文目录名（内部自动 URL 编码）
# 网络提示：走环境变量代理（HTTP(S)_PROXY）
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONFIG="$REPO_ROOT/mind.config"

cfg() {
  [ -f "$CONFIG" ] || return 0
  grep -m1 -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null \
    | cut -d= -f2- | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '\r'
}

VISION_ENABLED="$(cfg VISION_ENABLED)"
REPO_SLUG="$(cfg VISION_REPO_SLUG)"

if [ "${VISION_ENABLED:-0}" != "1" ]; then
  echo "ℹ️  图床未启用（mind.config 中 VISION_ENABLED=0）。需要图片记忆时按本目录 README.md 启用。" >&2
  exit 0
fi

case "$REPO_SLUG" in
  ""|*__*)
    echo "❌ VISION_REPO_SLUG 未填写，无法访问图库（见本目录 README.md）" >&2
    exit 2 ;;
esac

[ -n "${GH_TOKEN:-}" ] || { echo "❌ GH_TOKEN 未设置，无法访问图库（见 99-系统/托管规范.md 认证一节）" >&2; exit 2; }
command -v python3 >/dev/null || { echo "❌ 需要 python3" >&2; exit 2; }

MAX_IMG_BYTES=$((8 * 1024 * 1024))   # 图库铁律：单图 ≤ 8MB，超限先压缩

CMD="${1:-help}"
[ $# -gt 0 ] && shift

REPO_SLUG="$REPO_SLUG" MAX_IMG_BYTES="$MAX_IMG_BYTES" python3 - "$CMD" "$@" <<'PY'
import base64, json, os, sys, urllib.error, urllib.parse, urllib.request

cmd = sys.argv[1]
args = sys.argv[2:]
slug = os.environ["REPO_SLUG"]
api = f"https://api.github.com/repos/{slug}/contents"
hdr = {
    "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "mindseed-vision.sh",
}


def usage():
    print(
        "用法:\n"
        "  vision.sh ls [dir]                  列目录（默认根）\n"
        "  vision.sh get <repo路径> [输出路径]   取图到本地（默认 /tmp/），供多模态 Read\n"
        "  vision.sh put <本地文件> <repo路径>   上传图片，打印 gh 链接"
    )
    sys.exit(1)


def call(req):
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            msg = json.load(e).get("message", str(e))
        except Exception:
            msg = str(e)
        print(f"❌ GitHub API {e.code}: {msg}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"❌ 网络不通（检查 HTTP(S)_PROXY 代理）：{e.reason}", file=sys.stderr)
        sys.exit(2)


def enc(p):
    """路径段 URL 编码（保留 /）—— 中文目录名可直接用"""
    return urllib.parse.quote(p, safe="/")


if cmd == "ls":
    d = args[0].strip("/") if args else ""
    data = call(urllib.request.Request(f"{api}/{enc(d)}", headers=hdr))
    if isinstance(data, dict):
        print(f"❌ {data.get('message', '未知错误')}", file=sys.stderr)
        sys.exit(1)
    for it in sorted(data, key=lambda x: (x["type"] != "dir", x["name"])):
        kind = "📁" if it["type"] == "dir" else "🖼️"
        size = "" if it["type"] == "dir" else f"  {it['size'] // 1024}KB"
        print(f"{kind} {it['path']}{size}")

elif cmd == "get":
    if not args:
        usage()
    p = args[0].strip("/")
    out = args[1] if len(args) > 1 else os.path.join("/tmp", os.path.basename(p))
    req = urllib.request.Request(
        f"{api}/{enc(p)}", headers={**hdr, "Accept": "application/vnd.github.raw"}
    )
    try:
        with urllib.request.urlopen(req) as r, open(out, "wb") as f:
            f.write(r.read())
    except urllib.error.HTTPError as e:
        print(f"❌ 取图失败 HTTP {e.code}（路径写对了吗？）", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"❌ 网络不通（检查代理）：{e.reason}", file=sys.stderr)
        sys.exit(2)
    print(f"✅ 已取回 {p} → {out}（请用多模态 Read 回看）")

elif cmd == "put":
    if len(args) < 2:
        usage()
    src, p = args[0], args[1].strip("/")
    if not os.path.isfile(src):
        print(f"❌ 本地文件不存在: {src}", file=sys.stderr)
        sys.exit(1)
    size = os.path.getsize(src)
    if size > int(os.environ["MAX_IMG_BYTES"]):
        print(
            f"❌ 单图 {size // 1024 // 1024}MB 超 8MB 上限，请先压缩再入库（图库铁律）",
            file=sys.stderr,
        )
        sys.exit(1)
    with open(src, "rb") as f:
        body = json.dumps(
            {
                "message": f"vision: add {p}",
                "content": base64.b64encode(f.read()).decode(),
            }
        ).encode()
    data = call(urllib.request.Request(f"{api}/{enc(p)}", data=body, headers=hdr, method="PUT"))
    print(f"✅ 已入库: {p}（{size // 1024}KB，commit {data['commit']['sha'][:7]}）")
    print(f"📎 贴进 md: ![说明](https://github.com/{slug}/raw/main/{enc(p)})")

else:
    usage()
PY
