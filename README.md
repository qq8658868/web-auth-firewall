# Web Authentication Firewall (Linux)

一个自包含安装脚本，把主流 Linux 服务器改造成“先登录、后放行”的白名单访问模型。

- 当前脚本版本：1.2.4
- 一键安装器版本：1.0.0

## 支持的系统

- Debian / Ubuntu（apt）
- RHEL / CentOS / Rocky Linux / AlmaLinux（dnf / yum）
- Fedora（dnf）
- openSUSE / SLES（zypper）
- Arch Linux / Manjaro（pacman）

脚本会自动识别发行版和包管理器，并安装 `nftables` 与 `python3`。需要 systemd；Alpine（OpenRC）暂不支持。

## 功能

- nftables INPUT 默认策略为 DROP，默认只放行 TCP 18622（认证服务）。
- 默认禁止 ping；只有加入白名单的 IP 可以 ping 并访问服务器所有 TCP/UDP 端口。
- 任意 IP 都可以访问登录页面（默认 `http://服务器IP:18622/`，可配置自定义路径，例如 `/sdfcxsd`）。
- 登录成功后，客户端 IP 写入白名单，可访问服务器全部端口和服务。
- 5 分钟内连续 3 次登录失败后，客户端 IP 写入黑名单，服务器所有端口（包括 18622）和 ping 均拒绝访问。
- 白名单地址保留 48 小时，到期自动清空；重新登录会刷新 48 小时有效期。
- 黑名单地址同样保留 48 小时，到期自动清除，管理员也可以随时手动清除。
- 登录成功页面内置访问名单管理：可查看当前白名单/黑名单，并手动添加、删除 IP。
- 白名单/黑名单 IP 会在 Web 页面显示国家/地区信息（GeoIP，中文显示）。
- 登录成功页面提供“更新 GeoIP 数据库”按钮；更新在后台执行，页面自动刷新状态，无需保持页面等待。
- GeoIP 下载和构建使用磁盘目录 `/var/lib/web-auth-firewall/geoip-tmp`，不会占满小容量 `/tmp`。
- Web 管理表单使用随机 CSRF Token，兼容 `Origin: null` 浏览器环境，同时阻止缺少 Token 的跨站提交。
- 重装时自动保留现有登录路径和端口，并在服务启动后通过运行时配置精确显示当前登录地址。
- Web 页面可全局设置白名单/黑名单有效期（1-720 小时，默认 48 小时）；修改后现有名单会立即按新时长刷新，列表中显示四舍五入后的剩余时间。
- 登录成功页面提供“退出登录”按钮：只返回登录页以便切换账号，不会删除该 IP 的白名单。
- 默认用户名为 `admin`，默认密码为 `P@ssw0rd`，可通过命令行管理菜单重置。
- 凭据以 root-only SHA-256 哈希保存；支持 `chattr +i` 时还会加 immutable 锁。
- 白名单/黑名单状态保存在 `/var/lib/web-auth-firewall/state.json`，重启后自动恢复。
- 服务由 systemd 托管：`web-auth-firewall.service`。

## 环境要求

- 需要 root 权限。
- 需要 systemd；Alpine/OpenRC 暂不支持。
- 需要可用的 `nftables` 和 `python3`，缺失时脚本会通过系统包管理器安装。
- 安装会接管 `/etc/nftables.conf`，并暂时停用 UFW 或 firewalld。
- 建议通过 SSH 会话安装，不要直接在 VPS 的无人值守控制台中缺少回退方案时操作。

## 一键安装

复制以下整行命令到 VPS 执行即可。安装器会下载主脚本、检查脚本结构、执行 Shell 语法检查，然后自动以 `--install` 参数启动安装：

```bash
curl -fsSL https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/install.sh | sudo bash -s --
```

也可以先下载安装器再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/install.sh -o /tmp/web-auth-install.sh && sudo bash /tmp/web-auth-install.sh
```

一键安装器支持透传主脚本参数：

```bash
curl -fsSL https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/install.sh | sudo bash -s -- --port 18622 --allow-icmp
```

常用参数包括 `--port`、`--path`、`--allow-icmp`、`--keep-ssh` 和 `--no-keep-ssh`。不传参数时默认使用 `--install`，不会进入交互菜单。

只下载并验证主脚本、不执行安装：

```bash
curl -fsSL https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/install.sh | sudo WEB_AUTH_DRY_RUN=1 bash -s --
```

直接通过管道执行远程脚本会信任 GitHub 上的最新内容。需要严格校验时，可以设置预期 SHA-256：

```bash
curl -fsSL https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/install.sh | sudo WEB_AUTH_EXPECTED_SHA256=<脚本SHA256> bash -s --
```

## 在线安装

推荐先下载并检查脚本，再以 root 运行：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/setup_web_firewall.sh \
  -o /tmp/setup_web_firewall.sh

less /tmp/setup_web_firewall.sh
chmod 700 /tmp/setup_web_firewall.sh
sudo bash /tmp/setup_web_firewall.sh
```

也可以直接进入安装：

```bash
curl -fsSL \
  https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/setup_web_firewall.sh \
  -o /tmp/setup_web_firewall.sh

sudo bash /tmp/setup_web_firewall.sh --install
```

使用 `wget` 的系统可以这样下载：

```bash
wget -O /tmp/setup_web_firewall.sh \
  https://raw.githubusercontent.com/qq8658868/web-auth-firewall/main/setup_web_firewall.sh
sudo bash /tmp/setup_web_firewall.sh
```

不建议直接把远程脚本通过管道交给 root shell。先保存文件并检查内容，可以避免下载内容异常时直接执行。

## 本地安装

```bash
chmod 700 setup_web_firewall.sh
sudo ./setup_web_firewall.sh
```

运行后进入交互式管理菜单，选择 `1) 安装 / 更新 Web 认证防火墙`。

也可以跳过菜单直接安装：

```bash
sudo ./setup_web_firewall.sh --install
```

安装完成后，浏览器打开：

```text
http://服务器IP:18622/
```

默认登录凭据为 `admin` / `P@ssw0rd`。首次登录后请通过命令行菜单第 6 项立即修改，不要长期使用默认密码。

如果当前会话通过 SSH 连接，脚本会尝试把当前 SSH 客户端 IP 写入白名单，避免安装后被默认 DROP 策略锁在服务器外。无法识别 SSH 来源时不会自动添加，因此请提前确认 VPS 提供商的控制台或救援模式可用。

卸载：

```bash
sudo bash /tmp/setup_web_firewall.sh --uninstall
```

## 命令行管理菜单

```bash
sudo ./setup_web_firewall.sh
```

菜单包含：

```text
登录地址: http://服务器IP:18622/
1) 安装 / 更新 Web 认证防火墙
2) 显示白名单 IP
3) 显示黑名单 IP
4) 手动管理白名单（添加 / 删除）
5) 手动管理黑名单（添加 / 删除）
6) 重置 / 修改用户名和密码
7) 显示当前登录账户 / 密码状态
8) 查看服务状态与防火墙规则
9) 卸载 Web 认证防火墙
10) 自定义登录地址
11) 自定义服务端口
12) 更新 GeoIP 数据库
0) 退出
```

菜单顶部会自动显示当前服务器的 Web 登录地址（包含自定义路径），方便忘记登录地址时随时查看。

“手动管理白名单/黑名单”进入后会先显示当前列表，输入 `a` 添加 IP、`d` 删除 IP、`q` 返回上级菜单，可连续操作。

也可以直接用安装后的管理脚本：

```bash
python3 /opt/web-auth-firewall/manage.py list whitelist
python3 /opt/web-auth-firewall/manage.py list blacklist
python3 /opt/web-auth-firewall/manage.py add whitelist 1.2.3.4
python3 /opt/web-auth-firewall/manage.py remove whitelist 1.2.3.4
python3 /opt/web-auth-firewall/manage.py add blacklist 1.2.3.4
python3 /opt/web-auth-firewall/manage.py remove blacklist 1.2.3.4
```

## 常用参数

```bash
sudo ./setup_web_firewall.sh --port 18622        # 自定义认证端口（默认 18622）
sudo ./setup_web_firewall.sh --path /sdfcxsd     # 自定义登录路径
sudo ./setup_web_firewall.sh --random-path       # 安装时自动生成随机登录路径
sudo ./setup_web_firewall.sh --no-keep-ssh       # 不自动放行当前 SSH IP
sudo ./setup_web_firewall.sh --allow-icmp        # 允许任意 IP ping（默认禁止）
sudo ./setup_web_firewall.sh --menu              # 打开交互式管理菜单
sudo ./setup_web_firewall.sh --change-credentials  # 修改用户名/密码
sudo ./setup_web_firewall.sh --update-geoip         # 手动更新 GeoIP 数据库
sudo ./setup_web_firewall.sh --uninstall         # 卸载并恢复之前的规则
```

## 使用流程

1. 浏览器打开登录地址（默认 `http://服务器IP:18622/`；设置了自定义路径时，从命令行菜单顶部查看完整地址）。
2. 输入 `admin` / `P@ssw0rd` 登录。
3. 登录成功页面出现后，当前客户端 IP 已被加入 nftables 白名单，即可访问服务器的其他端口。
4. 登录成功页面会同时显示客户端自己的 IP，以及服务器当前开放的 TCP/UDP 端口列表。
5. 登录成功页面下方是“访问名单管理”：可以直接查看白名单/黑名单 IP，添加或删除任意地址。
6. 管理区域下方的“更新 GeoIP 数据库”按钮会在后台下载并构建数据库，页面每 5 秒自动刷新进度。
7. 页面最下方的“退出登录”只回到登录页面，白名单中的 IP 会继续保留。

只有处于白名单中的客户端 IP 才能使用管理功能（默认 `/manage`，自定义路径下为 `/自定义路径/manage`）。删除自己的 IP 后会立即失去服务器访问权限，需要重新登录。

## 管理

查看当前规则：

```bash
nft list table inet web_auth
```

查看服务日志：

```bash
journalctl -u web-auth-firewall -f
```

手动移除某个 IP（白名单和黑名单同时移除），然后重启服务使状态文件重新生效：

```bash
python3 - <<'PY'
import json
path = "/var/lib/web-auth-firewall/state.json"
ip = "1.2.3.4"
with open(path, encoding="utf-8") as fh:
    state = json.load(fh)
for kind in ("whitelist", "blacklist"):
    for family in ("4", "6"):
        group = state[kind][family]
        if isinstance(group, dict):
            group.pop(ip, None)
        else:
            state[kind][family] = [x for x in group if x != ip]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2, sort_keys=True)
PY
systemctl restart web-auth-firewall
```

状态文件中的白名单和黑名单都以 `{ "IP": 到期时间戳 }` 形式保存。到期条目由服务定期检查并自动从 nftables 和状态文件中清除，默认检查间隔为 5 分钟。

## 重要说明

- 认证页面目前使用 HTTP，密码在网络中是明文传输。如果服务器暴露在公网，建议在前方加 HTTPS 反向代理，或至少通过 VPN/内网使用。
- 脚本会接管 `/etc/nftables.conf` 并执行 `flush ruleset`，安装前会备份原规则到 `/etc/nftables.conf.pre-web-auth`。
- 脚本会禁用 ufw 和 firewalld，避免两套防火墙互相冲突。
- 如果服务器运行 Docker，请先确认 Docker 的端口映射策略与本规则兼容；Docker 的 nftables/iptables 表可能被 `flush ruleset` 清理。
- 安装或重启认证服务前，请确认当前 SSH 客户端 IP 已在白名单中，并保留 VPS 提供商控制台作为应急入口。
- Web 管理表单使用每次服务启动时生成的 CSRF Token；认证服务重启后，请刷新管理页面再执行操作。
- GeoIP 更新需要至少 1 GiB 可用空间，临时文件保存在 `/var/lib/web-auth-firewall/geoip-tmp`。
- 同一 IP 在 5 分钟内累计 3 次登录失败才会被拉黑；拉黑后无法再访问 18622 认证页面，需要管理员在命令行菜单中手动解除，或等待设置的有效期自动过期。
- ping 使用 ICMP 协议，不属于 TCP/UDP 端口：默认情况下只有白名单 IP 可以 ping；如需让任意 IP 都能 ping，请使用 `--allow-icmp` 安装。

## 更新日志

### 一键安装器 1.0.0

- 新增 `install.sh` 一键引导安装器。
- 自动下载主安装脚本，并校验文件头、文件内容和 Shell 语法。
- 默认传递 `--install`，支持透传端口、路径、ICMP 和 SSH 白名单参数。
- 支持 `WEB_AUTH_DRY_RUN=1` 仅验证下载内容，以及 `WEB_AUTH_EXPECTED_SHA256` 固定版本校验。

### 1.2.4

- 重装脚本时自动继承现有的 Web 登录路径和认证端口，不再无提示地改回默认值。
- 安装完成后强制重启认证服务，避免配置文件已更新但旧进程继续使用旧路径。
- 认证服务启动时写入 `/var/lib/web-auth-firewall/runtime.json`，后台管理菜单优先显示当前进程实际生效的路径和端口。
- 保留显式 `--path`、`--random-path` 和 `--port` 参数的覆盖行为。

### 1.2.3

- Web 管理表单加入随机 CSRF Token，兼容 `Origin: null` 浏览器环境，同时继续拒绝缺少 Token 的跨站提交。
- Web 管理页增加 GeoIP 后台更新状态、失败提示和自动刷新。
- 修复 systemd `PrivateTmp` 环境下 `/var/tmp/web-auth-firewall` 不存在导致服务反复启动失败的问题。
- GeoIP 临时文件迁移到 `/var/lib/web-auth-firewall/geoip-tmp`，并要求至少 1 GiB 可用空间。
- GeoIP 数据库改为原子替换，更新失败不会破坏现有数据库；更新成功后热重载，无需重启认证服务。

### 1.2.2

- 修复管理请求的 Origin 校验过严问题，改为按主机名和端口进行规范化比较。
- 记录被拒绝管理请求的 Host、Origin、Referer 和 Sec-Fetch-Site，便于排查代理及浏览器兼容问题。

### 1.2.1

- GeoIP 临时目录迁移到状态目录下，避免 systemd `PrivateTmp=true` 使 `/var/tmp` 路径失效。

### 1.2.0

- Web 登录成功页新增“更新 GeoIP 数据库”按钮。
- GeoIP 更新改为后台任务，支持重复启动保护、状态展示、完成时间显示和失败原因提示。
- 增加 GeoIP 构建磁盘空间检查、原子输出和缓存热重载。

### 1.1.6

- GeoIP 更新临时文件从容量较小的 `/tmp` 迁移到磁盘临时目录，避免 `No space left on device`。

### 1.1.5

- 修复 db-ip 城市数据库 CSV 列解析错误：现在会正确保留省份和城市名称，可显示到“昆明”这一级城市。

### 1.1.4

- 扩充 GeoIP 中文翻译表：新增全球主要城市及更多国家城市的中文名称。
- 更新 GeoIP 数据库成功后自动重启认证服务，使新的数据库立即生效，无需手动重启。
- Web 登录页、登录成功页底部以及命令行管理面板顶部显示当前脚本版本号。

### 1.1.3

- 修复低内存（如 1G RAM）VPS 更新 GeoIP 数据库时被 OOM 杀掉的问题：下载与解压改为流式处理，不再把整份数据一次性读入内存。
- GeoIP 位置信息改为中文显示（大洲 / 国家 / 中国省级），兼容 v2ray .dat 与 db-ip CSV 两种数据源。
- 命令行菜单新增第 7 项“显示当前登录账户 / 密码状态”，可查看当前用户名、密码是否为默认、密码哈希和登录地址。

### 1.1.2

- 白名单/黑名单列表新增“刷新”按钮和一键“清空”按钮；清空操作会同步清空 nftables 集合和状态文件。

### 1.1.1

- 修复卸载时无法删除带 immutable 锁的 `credentials` 等文件的问题，卸载前会自动解除只读属性。

### 1.1.0

- Web 页面整体改为浅色调。
- 退出登录按钮移动到页面最底部居中。
- 黑白名单有效期设置分别显示在各自名单框右上角，可直接修改。
- 修改全局有效期后，已有白名单/黑名单 IP 会立即按新时长刷新剩余时间。
- 剩余小时数按四舍五入显示。
- 登录失败拉黑提示中的有效期改为跟随当前设置，不再写死 48 小时。

### 1.0.0

- 首个正式版本：Web 登录认证、白名单全端口放行、黑名单拦截、命令行管理菜单、GeoIP 显示、自定义端口/路径、48 小时自动过期。
