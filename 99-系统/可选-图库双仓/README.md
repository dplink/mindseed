# 可选模块 · 图库双仓

> 默认**未启用**。心智库只存纯文本；图片需要另一个独立的私密仓库来住。
> 首次唤醒的最后一步会问用户是否需要；不需要就删除整个目录，核心功能不受影响。

## 它解决什么

- 图片是二进制，直接进主库会让 git 历史永久膨胀。
- 图库**永不 clone**，读写走 GitHub Contents API，云端沙箱零图负担。
- 主库 md 只存图库链接，检索契约保持纯文本。

## 启用步骤

1. 在 GitHub 新建一个**私密**仓库作为图库（例如 `<owner>/mind-vision`），不要初始化 README。
2. 编辑 `mind.config`：

   ```ini
   VISION_ENABLED=1
   VISION_REPO_SLUG=<owner>/mind-vision
   ```

3. 确认 token 同时授权两个仓库（细粒度 PAT 的授权范围**不会自动覆盖新库**）：
   - 心智库：`Contents: Read and write`
   - 图库：`Contents: Read and write`
4. 验证：

   ```bash
   export GH_TOKEN=<token>
   bash 99-系统/可选-图库双仓/scripts/vision.sh ls
   bash 99-系统/可选-图库双仓/scripts/vision.sh put ./test.png misc/test-001.png
   bash 99-系统/可选-图库双仓/scripts/vision.sh get misc/test-001.png /tmp/test.png
   ```

   预期：`ls` 能列出目录（空库也会返回空列表）；`put` 打印 commit 与可贴进 md 的链接；`get` 取回文件。

## 日常用法

```bash
vision.sh ls [dir]                   # 列目录（默认根）
vision.sh get <repo路径> [输出路径]    # 取图到本地（默认 /tmp/），供多模态 Read
vision.sh put <本地文件> <repo路径>    # 上传图片，打印 gh 链接
```

- 单图 ≤ 8MB，超限先压缩。
- 图库 append-only，只增不删。
- 路径支持中文（脚本内部 URL 编码）。

## 不需要时

1. `mind.config` 保持 `VISION_ENABLED=0`。
2. 删除 `99-系统/可选-图库双仓/` 整个目录。
3. 不要在任何核心文档里留下指向它的双链 —— 本模板已使用代码路径而非 `[[]]`，删除不会断链。

## 已知 trade-off

私密仓库的 raw 链接无凭证会 404，Obsidian 不渲染图片预览；看图由人格取回，或在本地 clone 图库后查看。
