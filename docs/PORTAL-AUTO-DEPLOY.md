# Game-Portal 独立 CI/CD · ECS 一次性安装

> 游戏大厅的网页路由已从 `/` 迁移完成；《异界共振》继续位于 `/games/rift/`。双人联机由使用者在浏览器中确认正常。本文件是**后续静态网页更新**的独立部署流程，不要再次运行 `migrate-ecs.sh apply`。

## 发布链路

```text
GitHub Game-Portal/main (push)
           |
           v
GitHub Actions: Validate Portal
  - JS 和 Shell 语法
  - 静态文件 HTTP 检查
  - Python 单元测试：CI gate / 资源版本
           |
    success for EXACT commit SHA
           |
           v
ECS: game-portal-deploy.timer (every ~5 minutes)
           |
     GitHub main SHA + push CI approval
           |
     Git fetch and verify same SHA
           |
     /var/www/game-portal/releases/<SHA>
           |
     atomic symlink switch
           |
  HTTP content comparison + Rift health
           |
      success / auto rollback
```

不会在 GitHub 保存服务器的 SSH 密钥，也不需要 GitHub 主动 SSH 登录 ECS。Portal 和 Rift 使用不同 systemd timer 与发布目录；Portal 仅更新门户软链接，不改 Nginx、不重启 `rift-game`，不访问/覆写 `/var/www/rift`。

## 在已经迁移成功的 ECS 上首次安装

先确认 `/root/Game-Portal` 已存在，并且没有未提交改动：

```bash
cd /root/Game-Portal
git pull --ff-only origin main
bash -n scripts/deploy-portal-ecs.sh
bash -n scripts/install-ecs-ci.sh
python3 -m unittest discover -s tests -p 'test_*.py' -v

# 仅安装新的独立发布任务
bash scripts/install-ecs-ci.sh

# 查看定时器
systemctl status game-portal-deploy.timer --no-pager
systemctl list-timers --all | grep -E 'game-portal-deploy|rift-deploy'

# 立即手动触发首次检查（不需要再次迁移 Nginx）
systemctl start game-portal-deploy.service
journalctl -u game-portal-deploy.service -n 80 --no-pager
```

安装器仅从已拉取的本地仓库初始化 `/opt/game-portal/repo`，将已审核的发布脚本复制到 `/opt/game-portal/bin`，创建 `game-portal-deploy.service` 与 `game-portal-deploy.timer`。**不修改现有 `rift-deploy.timer`、`rift-game.service`、Nginx 规则**。不要重新执行原《异界共振》安装包的 `install.sh`。

如果 `git pull` 由于 GitHub 网络故障而失败，等待网络恢复，**不要用过期脚本继续安装**。定时器检查失败时旧门户仍保持可访问，下一次重试。

## 后续如何发布

只需修改 Game-Portal 的页面内容，提交并 push 到 `main`。CI 通过后，ECS 定时器会在下一轮检查并拉取该 SHA；CI 失败、尚未完成、被取消、只有 PR CI、GitHub 网络故障，均**不会发布**。

- [CI Workflow](../.github/workflows/validate-portal.yml)
- [ECS deployer](../scripts/deploy-portal-ecs.sh)
- [CI 许可校验](../scripts/ci_gate.py)
- [发布文件准备](../scripts/prepare_release.py)
- [自动化测试](../tests/test_deployment.py)

每次成功上线会显示 `[Portal Deploy] SUCCESS. Now serving <SHA>`。可以检查：

```bash
readlink -f /var/www/game-portal/current
cat /var/www/game-portal/current/.portal-commit
curl -fsS -H 'Host: 47.119.122.133' http://127.0.0.1/ | grep 'rift-enter'
curl -fsS -H 'Host: 47.119.122.133' http://127.0.0.1/health
journalctl -u game-portal-deploy.service -n 100 --no-pager
```

发布器为 HTML 引用的 `styles.css`、`app.js`、`config.js` 与 SVG 附加当前 SHA 版本查询参数，降低浏览器缓存旧资源的问题；门户图仍在 `/portal-assets/`，绝不抢占《异界共振》的 `/assets/`。

## 失败与回滚

CI 未通过或 GitHub 请求失败：**不切换网站**。发布后首页、JS、CSS 或图片逐字节检查不通过，或原游戏首页和 `/health` 无法读取：自动把 `/var/www/game-portal/current` 切回上一个版本。不需要重载 Nginx。

如果想人工回滚门户，请先停止门户定时器，防止下一次自动部署又切回新的 GitHub `main`：

```bash
systemctl stop game-portal-deploy.timer
readlink -f /var/www/game-portal/current
ls -lt /var/www/game-portal/releases
# 选择一个已确认可用的旧发布目录后，手动原子切换
ln -s /var/www/game-portal/releases/已确认的旧版本目录 /var/www/game-portal/.manual-rollback
mv -Tf /var/www/game-portal/.manual-rollback /var/www/game-portal/current
```

待 GitHub 修复问题、CI 通过后，用 `systemctl start game-portal-deploy.timer` 恢复检查。

**注意：** `scripts/deploy-portal-ecs.sh`、`scripts/ci_gate.py`、`scripts/prepare_release.py` 和 systemd 单元本身不由自动发布器自动执行新仓库版本。它们是 ECS 上已安装的**受控发布工具**，更新这些文件后应先审查，再重新运行 `bash scripts/install-ecs-ci.sh` 进行升级；后续普通 HTML/CSS/JS/图片修改不必重装。不要让仓库中的任意变更直接以 root 权限执行新的部署脚本。

## 安全和约束

本方案无需 GitHub Secrets（纯公开仓库读取），也不把 SSH 私钥提交到 GitHub。使用 `systemd` 锁避免重复并行发布；使用不可变 SHA 发布目录与软链接原子切换。ECS GitHub API 匿名限流为每 IP 每小时一定请求数；五分钟检查频率通常低于该限制，如遇 API 限流或 GitHub 网络波动则保留现有版本，下轮重试。

当前是基于仓库代码与之前的 ECS 迁移日志设计；**尚未在你的真实 ECS 上安装独立 timer**，只有你运行上面的安装命令后才会开始自动发布。
