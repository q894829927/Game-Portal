# Game-Portal · 极简游戏大厅

独立的静态游戏选择页，部署在 ECS 根路径 `/`。首页只保留品牌、标题、两张全卡片游戏入口；不展示项目进度、版本流水、规划说明或冗长文案。

## 游戏入口

- [异界共振](https://github.com/q894829927/Rift-Resonance)：`/games/rift/`，合作生存 / Roguelike。
- [Wildfield Tactics](https://github.com/q894829927/Tactics-Game)：`/games/tactics/`，单机策略战棋。

两款游戏由各自仓库独立迭代，门户不伪装为实时游戏版本看板。

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
