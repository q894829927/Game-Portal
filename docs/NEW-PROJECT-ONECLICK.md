# 新项目一键接入 ECS：静态项目与 Vite 项目（V1）

本指南记录 Game-Portal、Rift、Tactics、Our-Little-World 现有部署经验，将它们的核心机制抽象为可复用的独立站点：**GitHub main 推送 → Actions 构建 site → ECS 三分钟检查 → SHA/CI 校验 → 原子发布与失败回滚**。

**适用范围：公开 GitHub 仓库中的静态 HTML/CSS/JavaScript 或 Vite 单页应用。** 已运行的四个网站均保留自身的部署器，不用这里的脚本重装。私有网站、后端、数据库、WebSocket 和上传存储需要单独安全部署，见文末。

## 一、快速使用（三步）

### 1. 本地生成新的项目

从干净的 Game-Portal main 仓库运行：

    python3 scripts/scaffold-static-site.py \
      --repo q894829927/MyGame \
      --slug mygame \
      --title "我的新游戏" \
      --kind vite \
      --output ../MyGame

支持 --kind vite 或 --kind static。Vite 模板自动设定 base=/games/mygame/；静态模板所有资源同样使用 /games/mygame/ 前缀。生成器拒绝覆盖已有目录；对已有项目，请人工合并生成的工作流和 base 设置，不要覆盖源码。

slug 限 2～31 个小写英文字母/数字/连字符，以字母开头且无连续双连字符，不得使用 rift 或 tactics。新项目固定挂载在 /games/<slug>/，不会抢占 /、/games/rift/、/games/tactics/、/love/ 或 /health。

### 2. 新建 GitHub 公开仓库并推送 main

先在 GitHub 新建空的公开仓库 q894829927/MyGame。然后：

    cd ../MyGame
    git init -b main
    git add .
    git commit -m "chore: initialize ECS app"
    git remote add origin https://github.com/q894829927/MyGame.git
    git push -u origin main

在 GitHub Actions 中确认 Publish managed static site 工作流由 main push 触发并成功，且已生成 site 分支。若 Actions 权限配置阻止写入 site，请给**新仓库**的 Actions 工作流启用 Contents: write，不改其它项目。

Vite 项目建议先本地 npm install 并提交 package-lock.json，这样构建使用 npm ci 并锁定依赖。初始无锁文件时 GitHub 工作流也能 npm install 并构建。

### 3. ECS 只需安装一次

确保既有四个站点的 HTTP/HTTPS 访问正常，并从 GitHub 更新 /root/Game-Portal 的 main 后：

    cd /root/Game-Portal
    git status --short
    git fetch origin main
    git merge --ff-only FETCH_HEAD
    bash -n scripts/install-managed-static-ecs.sh
    bash scripts/install-managed-static-ecs.sh \
      --slug mygame \
      --repo q894829927/MyGame

如果 ECS 访问 GitHub 的 HTTPS 网络受阻，请先使用你已经核验的 SSH 443 凭据更新 Game-Portal 源码；不要关闭 SSH 主机指纹检查。

安装器严格预检原大厅、Rift、Tactics、情侣网站，检查 Nginx 路由冲突和 GitHub 公共仓库；备份原 /etc/nginx/conf.d/rift.conf；仅增加自己项目的 Nginx snippet；创建独立 systemd unit 和 timer；从 GitHub 已审查通过的 site 分支首次部署；校验 HTTP 和 HTTPS 实际 HTML 字节。如果首次部署失败则撤销本次 Nginx 改动与新建资源，保留原配置备份。

预计成功输出：

    [Managed Site] SUCCESS: mygame at https://47.119.122.133/games/mygame/ ...
    [Managed Install] SUCCESS: https://47.119.122.133/games/mygame/ ...

普通网页更新以后不用再运行安装器。

## 二、后续自动更新与检查

新项目每次执行 git push origin main：GitHub Actions 构建 dist，把产物、.source-sha、.site-kind 和 .site-slug 放到 site 分支。ECS 中 portal-site-<slug>.timer 约三分钟检查一次：

1. 获取公开 GitHub main 和 site 的当前提交 SHA；若已发布最新版则立即跳过。
2. 查询与 main SHA 相同的 push 工作流记录，要求 CI completed/success。
3. 核对 site 内的源码 SHA 和指定 slug，拒绝错误来源的构建；不在 ECS 执行来自新项目的任意 build 或 npm。
4. 解包到 /var/www/game-portal/managed-sites/<slug>/releases/，拒绝 symlink/额外 dotfile，原子切换 current。
5. 校验 HTTP 与 HTTPS 返回的首页字节与发布目录完全相同，且原门户、Rift、Tactics 和 /health 仍返回 200；失败恢复旧版软链接。

手动检查（把 mygame 换成你的 slug）：

    systemctl is-enabled portal-site-mygame.timer
    systemctl is-active portal-site-mygame.timer
    journalctl -u portal-site-mygame.service -n 50 --no-pager
    readlink -f /var/www/game-portal/managed-sites/mygame/current
    cat /var/www/game-portal/managed-sites/mygame/current/.source-sha
    curl -fsS https://47.119.122.133/games/mygame/ -o /dev/null

手动触发安全检查（仍必须通过 CI/SHA 验证）：

    systemctl start portal-site-mygame.service

新增站点**不会自动往游戏大厅加卡片**。要在首页显示入口，另在 Game-Portal 的 index.html、styles.css 中添加入口并走门户自身 CI/CD；避免部署器自动修改已有门户 UI。

## 三、布局与隔离

- 根 HTTP Nginx 文件：/etc/nginx/conf.d/rift.conf。新增站点只注入 /etc/nginx/snippets/game-portal-managed-<slug>.conf。
- 公共 HTTPS 路由继续转发原 HTTP/80，已有 /love/ 与 /love/api/ 仍由专用 HTTPS 路由处理。**不要覆盖 HTTPS 独立虚拟主机**。
- 新项目数据与版本：/var/www/game-portal/managed-sites/<slug>。
- Git 对象缓存：/opt/game-portal/managed-sites/<slug>/repo。
- 每个项目的 timer：portal-site-<slug>.timer，独立启动与暂停。
- 共享只读发布器：/opt/game-portal/bin/deploy-managed-static.sh，由 Game-Portal 仓库的审查过的脚本首次安装。

更新 Game-Portal 仓库中的安装器不会自动以 root 权限执行新版本。已有共享发布器如果和审查版本不同，安装器会拒绝静默覆盖：这是避免新脚本意外波及所有站点的保护。

## 四、故障和回滚

- URL 冲突、原游戏未通过健康检查：不会进入安装阶段，**不要强制覆盖**。
- GitHub 无 main/site：先完成公开仓库创建和 Actions 发布。私有库不支持这个 V1。
- CI 失败或未完成、来源 SHA 不匹配：保留当前站点。
- 更新后 HTML 无法获取：自动恢复旧软链接；日志见 portal-site-<slug>.service。
- 网站 HTML 能打开但 JS、网络、WebSocket 不工作：需要浏览器开发工具和真实交互验收；HTTP 200 不等于功能正常。
- 初次安装失败：安装器用事前备份回滚原 Nginx 并只清理本次新建项目。备份位于 /var/backups/game-portal-managed-install/。不要把旧快照直接覆盖后续新配置，必须先核对差异。

切勿重新运行 Rift 原安装器、Game-Portal 的 migrate-ecs.sh apply，也不要删除 /var/www 或重装整个 Nginx。

## 五、特殊项目仍需额外设计

这里的一键配置**不负责自动创建 GitHub 仓库或设置 GitHub 登录凭据**；这两步需开发者拥有相关权限。对私有库、Node.js/Fastify API、数据库、账号登录、上传照片、Colyseus/WS 等场景，需要单独设计：低权限服务账号、机密配置、端口隔离、systemd、数据库备份和迁移、WebSocket 代理、登录/联机 E2E、失效回滚，并明确 HTTP/HTTPS 行为。不要把私人业务数据写进公开静态产物。

首次接入最终验收应包括：main CI、site SHA、两个端口的路由、timer enabled/active、旧四个站点不受影响，以及新项目真实浏览器操作。V1 是一次性安装工具，未在新的真实 ECS 项目上实测前不能声称已完成生产验证。


## GitHub HTTPS 网络故障：每项目独立 SSH 443 Deploy Key

某些 ECS 网络连接 GitHub 的 HTTPS (github.com:443) 不稳定。安装器的报错 "GitHub public site build is not accessible" 不代表 site 分支不存在。新版安装器/自动发布器都会先尝试每项目独立 SSH 443 Deploy Key，失败则回退公开 HTTPS。

首次注册新项目时，只在需要 SSH 的情况下运行：

    cd /root/Game-Portal
    bash scripts/provision-managed-ssh-ecs.sh \
      --slug pinball --repo q894829927/Neon-Pinball

脚本检查已有经过验证的 Game-Portal SSH known_hosts，生成 **仅属于 pinball 的一把新公私钥**，打印公钥。将打印的 SSH PUBLIC KEY 添加到：

https://github.com/q894829927/Neon-Pinball/settings/keys

在 GitHub 点击 Add deploy key，填写备注，**不要勾选 Allow write access**。不要提交私钥、粘贴私钥或向任何人发送私钥。公钥添加后重新执行一次安装命令：

    bash scripts/install-managed-static-ecs.sh \
      --slug pinball --repo q894829927/Neon-Pinball

定时器后续将使用同一项目的只读 SSH 443 Key，优先访问新仓库 main/site，并保留 GitHub HTTPS 回退。它不会使用现有 Portal、Rift 或 Tactics 的 Deploy Key，也不会更改它们的 Nginx 或定时器。

注意：Actions 成功检查仍需 api.github.com 可用，网络/API 失败时保留旧版本。私人仓库和后端服务仍不属于 V1 模板范围。
