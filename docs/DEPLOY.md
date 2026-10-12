# 部署顺序（必须按顺序）

**当前 ECS 根路径 `/` 已是《异界共振》，不要直接把本静态首页覆盖到 `/`。**

## 安全顺序

1. 在 GitHub 独立的 `Game-Portal` 仓库维护本项目；可先通过 GitHub Pages 或本地 `python -m http.server 5173` 预览（这是纯静态页面）。
2. 为《异界共振》准备**新路径** `/games/rift/`。这一步涉及：
   - 游戏前端构建工具的 `base` 配置；避免 Vite 静态资源仍从根路径加载。
   - 现有 Nginx 路由：静态页面、前端 SPA fallback、WebSocket 升级/代理、健康检查等；不得影响原有 Colyseus 房间和协议。
   - ECS 现有定时部署脚本的产物目录（不得在部署游戏时覆盖门户根目录）。
   - 新路径的真实浏览器双人联机验收和手机适配验收。
3. 在迁移完成且新路径验证通过后，先把游戏静态资源和游戏服务分开部署，再把首页设为根路径 `/`。
4. 确认 `config.js` 中的 `riftUrl` 与最终路由一致（目前预设为 `/games/rift/`）。
5. 为第二款原创战棋单独创建仓库，完成最小可玩原型后再在门户加正式入口；当前首页该卡片只指向本页“开发计划”，不会导航到不存在的游戏。

## 注意

- 本门户无需 Node 服务、数据库或自有登录系统，Nginx 托管静态 HTML/CSS/JS 即可。
- 本门户自身不做用户登录或游戏数据共享；两个游戏的存档和多人房间先各自管理。
- 不要把现有 ECS IP 直接写入 `config.js` 作为根地址链接，否则门户上线后可能点击回到门户造成循环。
- 当前配置只是**期望未来的生产路径**，并不表示该地址已经存在。
- 不要把“静态首页已写好”等同于“已部署生产环境”。

## ECS 迁移脚本：预检、执行与回滚

在 ECS 上运行 [scripts/migrate-ecs.sh](../scripts/migrate-ecs.sh)。它会保留现有 `rift-deploy.timer`、`rift-game.service`、`/opt/rift/bin/deploy.sh` 和 Colyseus 代理，仅新增门户入口与 `/games/rift/` 路由。

**先找到正在使用的 Nginx 站点文件：**

```bash
sudo nginx -T 2>&1 | grep -E '^# configuration file|server_name|root /var/www/rift|proxy_pass' | head -100
```

以下 `/etc/nginx/sites-enabled/rift` **只是示例**，必须替换成服务器上的真实路径。选中的文件必须恰好有一个 `server {`，且由当前 Nginx 加载：

```bash
cd ~
git clone https://github.com/q894829927/Game-Portal.git
cd Game-Portal
bash -n scripts/migrate-ecs.sh
sudo bash scripts/migrate-ecs.sh preflight --site /etc/nginx/sites-enabled/rift --host 47.119.122.133
```

预检报告 `Preflight OK` 才能继续。执行修改：

```bash
sudo bash scripts/migrate-ecs.sh apply --site /etc/nginx/sites-enabled/rift --host 47.119.122.133
```

脚本先把旧 Nginx 配置备份至 `/var/backups/game-portal-migration/<UTC时间>`，然后克隆 Game-Portal 到独立发布目录，生成 `/portal-assets/` 图片路径，设置门户软链接，增加 Nginx include。通过 `nginx -t` 后 reload 并检查门户、游戏新路径、原 Vite `/assets/` 文件的逐字节完整性和 `/health`。失败则尝试自动回滚。

**人工验收**：打开 `http://47.119.122.133/` 和 `http://47.119.122.133/games/rift/`，用两个浏览器创建/加入 Colyseus 房间并实际测试 WebSocket、移动与升级；HTTP 冒烟检查不能替代联机实测。

需要恢复时，使用执行日志显示的真实备份目录：

```bash
sudo bash scripts/migrate-ecs.sh rollback --backup /var/backups/game-portal-migration/实际备份时间
```

本脚本**尚未在你的 ECS 上执行**。若站点有多个 server、已经有 `location = /` 或 Nginx 校验不通过，必须暂停并检查实际配置，不能强行执行。由于原游戏仍使用绝对路径 `/assets/`，这是兼容现有发布链路的过渡方案；未来第二款游戏建议独立设置 Vite `base`。
