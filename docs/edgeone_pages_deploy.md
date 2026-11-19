# 部署到腾讯云 EdgeOne Pages

工作流：`.github/workflows/deploy-web.yml`。

每次推送 `main`，GitHub Actions 都会安装 Godot 4.7.2 和对应导出模板，从源码生成 Web 产物，检查 HTML/JS/WASM/PCK，再使用固定版本 `edgeone@1.7.3` 的官方 CLI 发布到 EdgeOne Pages。工作流不部署到 GitHub Pages，也不再更新 COS。

## 1. 创建 API Token

1. 打开[腾讯云 EdgeOne Pages 控制台](https://console.cloud.tencent.com/edgeone/pages)，选择要长期存放本项目的工作空间。
2. 打开 **API Token** 页签，创建一个仅用于本仓库自动部署的 Token，并按团队安全策略设置有效期。
3. 在 GitHub 仓库 **Settings → Secrets and variables → Actions** 中新建 Secret：

| Secret 名称 | 填写内容 |
| --- | --- |
| `EDGEONE_API_TOKEN` | 刚创建的 EdgeOne Pages API Token |

Token 绑定工作空间，部署会进入该工作空间。不要把 Token 发到聊天、提交到仓库或写进工作流；如需更换，只需更新 GitHub Secret。Token 到期前需要轮换。

## 2. 直接上传项目

- 工作流使用项目名 `mydearwife`，首次部署会自动创建直接上传项目，之后更新同一项目，无需预先手动创建。
- 如果工作空间里已经有同名项目，它必须是**直接上传**类型；否则请改用另一个项目名，避免把 Git 集成项目改成不同的发布方式。
- 创建时使用 `global` 加速区域。项目创建后，CLI 的 `--area` 不会改变既有项目区域。
- 发布目录只有 CI 新生成的 `build/web`，不会上传源码、`.godot/` 或本地存档。

## 3. 发布与验收

- 推送 `main` 会自动发布；也可以在 **Actions → Deploy Godot Web to EdgeOne Pages → Run workflow** 手动触发。
- CLI 的最后一行 JSON 提供部署 URL，`tools/edgeone_pages_result.py` 只接受最终成功的 HTTPS 地址，并把它写入部署环境链接。
- Action 对四个关键文件执行 HTTPS HEAD 检查，再对首页执行真实 GET，要求 `text/html` 且不能以附件形式下载。HEAD 200 不代表游戏已经可玩，发布后的最终验收还应运行 `tools/web_counter_smoke.py`，用真实 Chrome 检查游戏启动和受影响操作。
- 部署命令使用 `--skip-ai-gateway-sync`，本游戏没有 AI Gateway 或云函数依赖。

## 4. COS 迁移说明

原 COS 桶及其文件不会被新工作流删除或清理，旧地址也不会再自动更新。是否关闭旧静态网站、删除旧对象或移除 `TENCENT_*` GitHub Secrets，可在确认新地址稳定后另行手动处理。

COS 默认域名曾对本项目的真实 HTML GET 返回 `Content-Disposition: attachment` 和 `x-cos-force-download: true`，即使对象元数据已设置为 `Content-Disposition: inline` 也仍然强制下载，因此不再把该默认域名作为游戏入口。
