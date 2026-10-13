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

## 2026-10-14：ECS Git SSH 443 优先、HTTPS 回退

游戏大厅的部署程序现在只在检测到 **门户专用只读 Deploy Key** 时优先连接 `ssh.github.com:443` 查询 `main` 并拉取代码；失败后自动尝试原 HTTPS，未配置专用密钥时仍保持原先的 HTTPS 行为。

- 保留 `/opt/game-portal/repo` 的原始 HTTPS `origin`，部署脚本继续校验其精确来源；实际网络拉取使用明确的 SSH URL。
- systemd service 带有 `ProtectHome=true`，不可直接使用 `/root/.ssh`。服务的独立凭据路径是 `/etc/game-portal/ssh/game_portal_deploy` 与 `/etc/game-portal/ssh/github_known_hosts`。
- `ssh` 禁止交互、只使用指定密钥、严格核对主机指纹并限制连接时间。SSH 或 HTTPS 均失败时不切换线上版本。
- **GitHub Actions 工作流批准仍依赖 `api.github.com` HTTPS**；CI 通过与 SHA 一致性、安全发布及 HTTP 校验、回滚依旧是必需步骤。
- 《异界共振》的 `rift-deploy.service`、Node 服务、Nginx 路由、`/var/www/rift` 和战棋相关部署任务均不在此改动范围内。

### 1. 创建门户专用只读 Deploy Key（不可复用战棋密钥）

在 ECS 的 root shell 检查是否已有同名密钥，若已存在则跳过生成，绝不要覆盖：

```bash
ls -l /root/.ssh/game_portal_deploy* 2>/dev/null || true
# 仅在文件不存在时生成：
test ! -e /root/.ssh/game_portal_deploy &&
  ssh-keygen -t ed25519 -f /root/.ssh/game_portal_deploy \
    -C "game-portal-ecs-readonly" -N ""
cat /root/.ssh/game_portal_deploy.pub
```

只复制 `.pub` 的公钥，添加到 [Game-Portal Deploy Keys](https://github.com/q894829927/Game-Portal/settings/keys)，**不要勾选 Allow write access**。不同仓库通常需要不同的 Deploy Key，不要把战棋的私钥上传或重复登记到门户。

先通过安全途径核对 `ssh.github.com:443` 的 GitHub Ed25519 指纹：

`SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`

使用已经经过核验的 `/root/.ssh/tactics_known_hosts`，如果该文件没有对应 `ssh.github.com:443` 的正确主机密钥，停止操作并先进行独立核对；**不能使用 `StrictHostKeyChecking=no` 绕过检查。**

```bash
install -d -o root -g root -m 0700 /etc/game-portal/ssh
install -o root -g root -m 0600 /root/.ssh/game_portal_deploy \
  /etc/game-portal/ssh/game_portal_deploy
install -o root -g root -m 0644 /root/.ssh/tactics_known_hosts \
  /etc/game-portal/ssh/github_known_hosts
ssh-keygen -lf /etc/game-portal/ssh/github_known_hosts
```

指纹核对无误后，用与运行服务完全相同的专用凭据测试：

```bash
GIT_SSH_COMMAND='ssh -i /etc/game-portal/ssh/game_portal_deploy -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/game-portal/ssh/github_known_hosts -o ConnectTimeout=8' \
  git -C /opt/game-portal/repo ls-remote \
  ssh://git@ssh.github.com:443/q894829927/Game-Portal.git refs/heads/main
```

必须输出合法的 `main` 提交 SHA 后才能继续；若收到 `Permission denied (publickey)`，先核对仓库 Deploy Key，不能直接发布。

### 2. 只更新已安装的部署脚本（不重做 Nginx 迁移）

服务器上的 `/opt/game-portal/bin/deploy.sh` **不会因为 GitHub push 自动更新**。先更新 `/root/Game-Portal` 的本地源码，使用已通过的 SSH Key（不是门户新密钥）的前提是 GitHub 对该仓库已有合法访问授权，否则用刚才门户专用的 Key：

```bash
cd /root/Game-Portal
GIT_SSH_COMMAND='ssh -i /root/.ssh/game_portal_deploy -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/tactics_known_hosts -o ConnectTimeout=8' \
  git fetch ssh://git@ssh.github.com:443/q894829927/Game-Portal.git main
git merge --ff-only FETCH_HEAD
bash -n scripts/deploy-portal-ecs.sh

systemctl stop game-portal-deploy.timer
while systemctl is-active --quiet game-portal-deploy.service; do sleep 2; done
backup="/opt/game-portal/bin/deploy.sh.before-ssh-$(date +%Y%m%d-%H%M%S)"
cp -p /opt/game-portal/bin/deploy.sh "$backup"
install -o root -g root -m 0755 scripts/deploy-portal-ecs.sh \
  /opt/game-portal/bin/deploy.sh.next
mv -f /opt/game-portal/bin/deploy.sh.next /opt/game-portal/bin/deploy.sh

systemctl reset-failed game-portal-deploy.service
systemctl start game-portal-deploy.service
systemctl start game-portal-deploy.timer
journalctl -u game-portal-deploy.service -n 50 --no-pager -l
systemctl list-timers --all game-portal-deploy.timer
cat /var/www/game-portal/current/.portal-commit
```

服务日志应出现 `[Portal Deploy] Git transport: SSH 443 primary, HTTPS fallback`。当 `main` 版本更新且实际完成 Git 拉取时，出现 `main fetched over SSH 443`；若网站已是最新版本，则只显示 `Already serving ...`，不触发 fetch。

### 3. 回退脚本

保留第 2 步打印的实际备份文件路径。若新发布器未能按预期运行，暂停定时器、等待服务退出，将备份原子恢复，再恢复 timer：

```bash
systemctl stop game-portal-deploy.timer
while systemctl is-active --quiet game-portal-deploy.service; do sleep 2; done
# 下面的变量需替换为上面实际输出的完整备份路径
backup="/opt/game-portal/bin/deploy.sh.before-ssh-实际时间戳"
test -f "$backup" || exit 1
install -o root -g root -m 0755 "$backup" /opt/game-portal/bin/deploy.sh.next
mv -f /opt/game-portal/bin/deploy.sh.next /opt/game-portal/bin/deploy.sh
systemctl start game-portal-deploy.timer
```

切勿重跑 `scripts/migrate-ecs.sh apply` 或 `scripts/install-ecs-ci.sh` 来升级已经运行的服务；这可能误改其他受控配置。
