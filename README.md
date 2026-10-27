# Game-Portal · 极简游戏大厅

独立的静态游戏选择页，部署在 ECS 根路径 `/`。首页保留品牌、标题、两张全卡片游戏入口，另在卡片下方提供独立的「我们的小小世界」私人空间入口；不展示项目进度、版本流水、规划说明或冗长文案。

## 游戏入口

- [异界共振](https://github.com/q894829927/Rift-Resonance)：`/games/rift/`，合作生存 / Roguelike。
- [Wildfield Tactics](https://github.com/q894829927/Tactics-Game)：`/games/tactics/`，单机策略战棋。

两款游戏由各自仓库独立迭代，门户不伪装为实时游戏版本看板。

## 私人空间入口

- 首页提供独立入口：`/love/`，并不作为第三张游戏卡片。
- `/love/` 的 Nginx 路由需要由独立私有仓库 [Our-Little-World](https://github.com/q894829927/Our-Little-World) 的 ECS 安装器首次配置，将其重定向至带双人访问保护的 HTTPS 网站。
- 在新网站尚未安装之前，入口可能返回 404 或其他尚未配置页面。**不要将门户仓库作为私人照片或账号数据的存储位置。**
- 新网站使用独立的静态发布、systemd timer、Nginx 配置及私有凭据；不复用 Game-Portal、Rift 或 Tactics 的部署服务。

## 发布

`main` → GitHub Actions [Validate Portal](.github/workflows/validate-portal.yml) → ECS `game-portal-deploy.timer`（SSH 443 优先、HTTPS 回退）→ CI、SHA、HTTP 校验后原子发布。更新 `index.html`、`styles.css`、`app.js` 等页面资源不需重装部署服务。

- [自动发布与回滚说明](docs/PORTAL-AUTO-DEPLOY.md)
- [首次迁移说明](docs/DEPLOY.md)

不要重新运行 `scripts/migrate-ecs.sh apply`，也不要改动独立的 Rift / Tactics 定时器和 Nginx 路由。

## 本地查看

```bash
python -m http.server 5173
```

访问 `http://localhost:5173/`。文案和布局分别由 `index.html` 和 `styles.css` 控制；路径由 `config.js` 管理。插画在 `assets/`，使用项目自有的 SVG。

## 新项目快速接入

想新建一个游戏并让 ECS 自动部署，不需要重新改 Portal / Rift / Tactics 的基础配置：

1. 用 [静态/Vite 脚手架](scripts/scaffold-static-site.py) 生成新仓库，设定独立路径 /games/<slug>/。
2. 推送到**公开** GitHub 仓库 main，GitHub Actions 自动构建 site。
3. 在 ECS 运行 [一次性安装器](scripts/install-managed-static-ecs.sh)，自动配置项目专属 Nginx 路由、systemd timer 和受 CI/SHA 保护的发布目录。

后续只需推送新项目 main，约三分钟自动检查更新，失败不覆盖旧版。**目前 V1 只适合公开静态网页/Vite**；Node 服务、数据库、私有仓库和 WebSocket 不会被此工具自动部署。不会自动往大厅插入卡片，也不会重装已有三个游戏与私密空间。

完整步骤、首次验收及回滚：[新项目一键接入说明](docs/NEW-PROJECT-ONECLICK.md)。
