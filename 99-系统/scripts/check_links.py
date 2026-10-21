#!/usr/bin/env python3
"""MindSeed 心智库 · 双链完整性检查
扫描所有 .md 文件中的 [[双链]]，校验目标文件是否存在。
用法：python3 99-系统/scripts/check_links.py
退出码：0 = 全部通过；1 = 存在断链
"""
import re
import sys
from pathlib import Path

# Windows 控制台默认 GBK，打印 ❌/✅ 会 UnicodeEncodeError —— 强制 UTF-8
try:
    sys.stdout.reconfigure(encoding="utf-8")
except (AttributeError, OSError):
    pass

ROOT = Path(__file__).resolve().parents[2]  # 仓库根（scripts 在 99-系统/scripts/ 下）

# 本地存在但云端本就不存在的文件（不入云但被合法引用）
ALLOWLIST = {"user-profile"}

LINK_RE = re.compile(r"\[\[([^\[\]]+?)\]\]")
FENCE_RE = re.compile(r"```.*?```", re.S)   # 围栏代码块里的 [[xx]] 是示例
CODE_RE = re.compile(r"`[^`]*`")            # 行内代码里的 [[xx]] 是语法示例


def normalize(target: str) -> str:
    """取链接目标主干：去别名、去标题锚点、去扩展名。"""
    target = target.split("|")[0].strip()
    target = target.split("#")[0].strip()
    if target.endswith((".md", ".base")):
        target = target.rsplit(".", 1)[0]
    return target


def build_index() -> dict[str, Path]:
    """文件名主干 / 相对路径主干 → 文件。"""
    index: dict[str, Path] = {}
    for f in ROOT.rglob("*"):
        if not f.is_file() or f.suffix not in (".md", ".base"):
            continue
        stem = f.stem
        index.setdefault(stem, f)
        rel = f.relative_to(ROOT).with_suffix("")
        index.setdefault(rel.as_posix(), f)  # 链接写的是 `/`，Windows 上 str(Path) 会给反斜杠
    return index


def main() -> int:
    index = build_index()
    broken: list[str] = []
    checked = 0
    for md in ROOT.rglob("*.md"):
        text = md.read_text(encoding="utf-8")
        text = FENCE_RE.sub("", text)   # 先剔除围栏代码块
        text = CODE_RE.sub("", text)    # 再剔除行内代码
        for match in LINK_RE.finditer(text):
            checked += 1
            target = normalize(match.group(1))
            if not target or target in ALLOWLIST:
                continue
            if target not in index:
                broken.append(f"{md.relative_to(ROOT).as_posix()} → [[{match.group(1)}]]")

    print(f"已检查 {checked} 条双链")
    if broken:
        print(f"❌ 断链 {len(broken)} 条：")
        for b in broken:
            print(f"  {b}")
        return 1
    print("✅ 双链完整")
    return 0


if __name__ == "__main__":
    sys.exit(main())
