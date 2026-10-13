# Game-Portal · 独立静态游戏大厅

无构建、零依赖的暗黑奇幻风格游戏选择页，位于 ECS 根路径 `/`，独立于两个游戏仓库。

## 已开放的入口

- **[异界共振](https://github.com/q894829927/Rift-Resonance)**：`v0.1.5`，单人或多人四分钟生存原型，开放火焰弹 / 虚空法球双武器及 II / III 分支强化；其他武器和长期平衡仍在开发。入口 `/games/rift/`。
- **[Wildfield Tactics（暂定名）](https://github.com/q894829927/Tactics-Game)**：`v0.1.19.5`，10×8 战场、4v6 单关卡，已具备 16 种武器数据、背包换装、攻击预测、经验升级和手机触控。更多关卡、转职、剧情及存档尚未开放。入口 `/games/tactics/`。

上述为 **2026-10-14 的功能与版本快照**。游戏代码仓库会独立更新；门户静态文案不会自动随游戏版本变化，须根据实际完成内容再同步。

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

战棋与《异界共振》仍由各自仓库独立迭代。游戏大厅仅标注截至页面更新时的已实现能力，未实装的内容继续注明开发中。
