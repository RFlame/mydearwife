# 部署到腾讯云 COS 静态网站

工作流：`.github/workflows/deploy-web.yml`。

每次推送 `main`，GitHub Actions 都会从源码安装 Godot 4.7.2 和导出模板，生成 Web 产物，检查 HTML/JS/WASM/PCK，再用腾讯云官方 Python SDK 上传到 COS。上传后会对四个线上文件执行 HTTPS HEAD 检查，任一文件不可公开访问都会让部署失败。

## 1. 创建专用 COS 存储桶

1. 打开腾讯云控制台 → **对象存储 COS → 存储桶列表 → 创建存储桶**。
2. 选择地域，例如 `ap-guangzhou`。地域一旦创建不能修改。
3. 设置一个全局唯一的名称，创建一个**只存放本游戏的专用桶**。
4. 访问权限选择**公有读、私有写**。游戏文件需要公开读取，但上传和删除必须继续使用密钥鉴权。
5. 创建后记录完整桶名，格式为 `名称-APPID`，例如 `mydearwife-1250000000`；同时记录地域代码。

> `tools/tencent_cos_deploy.py` 会在全部文件上传成功后，删除桶内已经不在新 Web 产物中的旧文件，因此不要混放其他资料。上传失败的发布会终止在清理之前。

## 2. 开启静态网站

1. 进入存储桶 → **基础配置 → 静态网站**。
2. 开启静态网站功能。
3. 默认首页设置为 `index.html`。本游戏没有前端路由，不需要把不存在的资源重写到首页。
4. 保存后，默认访问地址为：

```text
https://完整桶名.cos-website.地域代码.myqcloud.com/
```

例如桶名为 `mydearwife-1250000000`、地域为 `ap-guangzhou` 时：

```text
https://mydearwife-1250000000.cos-website.ap-guangzhou.myqcloud.com/
```

此步骤只使用示例格式，不要把示例桶名直接填入 Secrets。

## 3. 创建最小权限访问密钥

1. 在 **访问管理 CAM → 用户 → 用户列表**创建一个子用户，建议只开启 **API 密钥访问**，不开放控制台登录。
2. 回到该 COS 桶的 **权限管理 → 存储桶访问权限**，给这个子用户授予该桶所需的**数据读取和数据写入**权限，不授予权限管理或其他桶的权限。
3. 在子用户的 **API 密钥管理**中创建 SecretId / SecretKey。

不要使用腾讯云主账号密钥。密钥只用于上传、同步、读取和清理这个专用游戏桶；如怀疑泄露，应立即在 CAM 中禁用并轮换。

## 4. 配置 GitHub Secrets

打开 GitHub 仓库 → **Settings → Secrets and variables → Actions → New repository secret**，依次添加：

| Secret 名称 | 填写内容 | 是否敏感 |
| --- | --- | --- |
| `TENCENT_SECRET_ID` | CAM 子用户的 SecretId | 是 |
| `TENCENT_SECRET_KEY` | CAM 子用户的 SecretKey | 是 |
| `TENCENT_COS_BUCKET` | 完整桶名，含 `-APPID` | 否，但仍统一存放在 Secrets |
| `TENCENT_COS_REGION` | 地域代码，例如 `ap-guangzhou` | 否，但仍统一存放在 Secrets |

不要把 SecretId、SecretKey 发到聊天、提交到仓库或写入工作流。工作流只通过 `${{ secrets.* }}` 和环境变量读取它们；部署脚本不写入本地配置文件，也不打印密钥。

## 5. 发布和验证

- 将工作流合入 `main` 会自动发布；也可以在 **Actions → Deploy Godot Web to Tencent COS → Run workflow** 手动触发。
- `Export and publish Web` 任务中的部署环境链接就是 COS 静态网站地址。
- 工作流上传时给文件设置 `Cache-Control: no-cache`，避免同名 JS/WASM/PCK 更新后继续命中旧缓存。
- 部署脚本按扩展名设置 Content-Type，其中 HTML 为 `text/html; charset=utf-8`、JavaScript 为 `text/javascript`、WASM 为 `application/wasm`，避免浏览器因错误 MIME 拒绝加载。
- 当前工作流不配置 CDN、自定义域名或 CDN 缓存刷新。后续接入 CDN 时，需要另加缓存刷新步骤；中国大陆自定义域名还需满足备案要求。
- 原来的 GitHub Pages 工作流已被本工作流替换，不再由该项目自动更新。已经存在的 Pages 站点是否关闭，可在 GitHub Pages 设置中另行决定。
