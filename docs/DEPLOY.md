# 首次 Nginx 路由迁移记录（已完成）

> **当前状态：** 用户提供的 ECS 日志显示 `migrate-ecs.sh apply` 于 2026-10-12 成功，Portal `/`、Rift `/games/rift/` 和 `/health` 的 HTTP 检查通过；用户随后确认双人联机正常。**无需也不应再次执行初次迁移。** 今后 Game-Portal 更新请参照 [独立 CI/CD 安装说明](PORTAL-AUTO-DEPLOY.md)，只安装 `game-portal-deploy.timer`。

以下保留历史迁移步骤，仅作为维护与回滚参考。

> **2026-10-12 根据实际部署包核对：** 上传的 `rift-ecs-deploy-kit-fixed(1).zip` 内 `install.sh` 会将 Nginx 站点安装为 `/etc/nginx/conf.d/rift.conf`。该 `rift.conf` 已定义 `location = /index.html`，因此迁移脚本已改为修改原位置的 document root，**不再重复声明这个 location**。实际 ECS 可能在安装后被手动修改，仍以 `sudo nginx -T` 的实时输出为准。原 `location /assets/`、`location @rift_backend` 与游戏后端 2567 的代理规则保留。**不可重新运行 install.sh 来迁移门户**，因为安装器会覆盖站点配置并重新部署游戏。

**历史提醒：迁移之前，ECS 根路径 `/` 是《异界共振》。现在已迁移为 Game-Portal。**

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

根据旧安装包，配置应为 `/etc/nginx/conf.d/rift.conf`；实际 ECS 如果有变化，使用服务器上真实且已加载的路径。选中的文件必须恰好有一个 `server {`，且由当前 Nginx 加载：

```bash
cd ~
git clone https://github.com/q894829927/Game-Portal.git
cd Game-Portal
bash -n scripts/migrate-ecs.sh
sudo bash scripts/migrate-ecs.sh preflight --site /etc/nginx/conf.d/rift.conf --host 47.119.122.133
```

预检报告 `Preflight OK` 才能继续。执行修改：

```bash
sudo bash scripts/migrate-ecs.sh apply --site /etc/nginx/conf.d/rift.conf --host 47.119.122.133
```

脚本先把旧 Nginx 配置备份至 `/var/backups/game-portal-migration/<UTC时间>`，然后将 Game-Portal 的文件放入独立发布目录，生成 `/portal-assets/` 图片路径，设置门户软链接，增加 Nginx include。通过 `nginx -t` 后 reload 并检查门户、游戏新路径、原 Vite `/assets/` 文件的逐字节完整性和 `/health`。失败则尝试自动回滚。

**人工验收**：打开 `http://47.119.122.133/` 和 `http://47.119.122.133/games/rift/`，用两个浏览器创建/加入 Colyseus 房间并实际测试 WebSocket、移动与升级；HTTP 冒烟检查不能替代联机实测。

需要恢复时，使用执行日志显示的真实备份目录：

```bash
sudo bash scripts/migrate-ecs.sh rollback --backup /var/backups/game-portal-migration/实际备份时间
```

历史记录：该脚本已在 ECS 执行成功。若站点有多个 server、已经有 `location = /` 或 Nginx 校验不通过，必须暂停并检查实际配置，不能强行执行。由于原游戏仍使用绝对路径 `/assets/`，这是兼容现有发布链路的过渡方案；未来第二款游戏建议独立设置 Vite `base`。


### 与原安装包确认一致的事实

- `install.sh` 会安装 `$KIT/rift.conf` 到 `/etc/nginx/conf.d/rift.conf`，且是**覆盖安装**；迁移后不要重新执行原安装器，除非你了解它会恢复旧 Nginx 配置。
- `deploy.sh` 仅更改 `/opt/rift/current` 与 `/var/www/rift/current` 两个软链接，不覆盖门户的 `/var/www/game-portal/current`，所以它的定时更新可继续工作。
- 游戏前端使用 `VITE_SERVER_URL=http://47.119.122.133`（构建时注入），故新路径下仍向站点根路径请求联机与健康接口。当前 Nginx 的 `@rift_backend` 继续代理这些请求。
- **兼容式迁移**：不急于修改原 Vite `base`；游戏的 `/assets/` 必须由原网站目录响应，而门户自己的 SVG 使用独立的 `/portal-assets/`。后续独立新游戏必须配置新的静态资源基础路径。


### 更新：不再在迁移过程中克隆 GitHub（2026-10-12）

先前 `apply` 曾在再次执行 `git clone https://github.com/q894829927/Game-Portal.git` 时收到 `Failure when receiving data from the peer`，脚本成功回滚。修正版改为从当前脚本所在的 **Game-Portal 本地 Git 仓库** 用 `git archive HEAD` 发布已提交文件：**执行 apply 本身无需访问 GitHub**。避免临时 GitHub 连接异常造成迁移失败。

在 ECS 操作时先更新本地代码：

```bash
cd /root/Game-Portal
git pull --ff-only origin main
bash -n scripts/migrate-ecs.sh
bash scripts/migrate-ecs.sh preflight --site /etc/nginx/conf.d/rift.conf --host 47.119.122.133
bash scripts/migrate-ecs.sh apply --site /etc/nginx/conf.d/rift.conf --host 47.119.122.133
```

注意：`git pull` 本身仍需要访问 GitHub；但是如果它失败，不要继续使用旧版脚本。可等待网络恢复后重试。新脚本明确校验本地仓库远程来源、当前 `main` 分支和工作区是否干净；不会读取未提交的改动。新脚本继续打印备份目录并自动回滚。出现网页返回错误时，现在会记录具体 HTTP 状态、页面响应片段及 Nginx 错误日志。
