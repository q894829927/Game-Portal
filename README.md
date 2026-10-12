# Game-Portal · 独立静态游戏大厅

无构建、零依赖的暗黑奇幻风格游戏选择页，位于 ECS 根路径 `/`，独立于两个游戏仓库。

## 已开放的入口

- **[异界共振](https://github.com/q894829927/Rift-Resonance)**：多人 Roguelike，路径 `/games/rift/`。
- **[未命名战棋](https://github.com/q894829927/Tactics-Game)**：已开放原创奇幻回合制战棋**单机原型**，路径 `/games/tactics/`；目前为 10×8 地图、4v6 单关卡，角色成长、更多关卡及正式美术仍在开发中。

## 生产发布

门户独立使用 GitHub Actions 验证和 ECS `game-portal-deploy.timer` 每约 5 分钟检查 `main` 已通过 CI 的提交。更新首页、游戏链接及素材后只需提交并推送到 `main`。

- [门户 ECS 独立部署与回滚](docs/PORTAL-AUTO-DEPLOY.md)
- [GitHub CI](.github/workflows/validate-portal.yml)
- [游戏大厅首次迁移记录](docs/DEPLOY.md)

**不要再次执行** `scripts/migrate-ecs.sh apply`，也不要更改《异界共振》或战棋的现有自动部署任务。

## 本地预览（可选）

```bash
python -m http.server 5173
```

打开 `http://localhost:5173/`。网站入口：编辑 `config.js` 中的 `riftUrl` 与 `tacticsUrl`；页面文字、游戏卡片编辑 `index.html`；配色与布局编辑 `styles.css`。游戏示意插画位于 `assets/`，不包含其他商业游戏的官方素材。

## 研发安排

战棋仍作为独立仓库推进战斗预览、成长、角色职业、装备、章节内容。游戏大厅仅显示真实可玩的阶段，不将尚未实现的玩法标记为完成。
