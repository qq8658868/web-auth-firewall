# Web Authentication Firewall (Linux)

一个自包含安装脚本，把主流 Linux 服务器改造成“先登录、后放行”的白名单访问模型。

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
- 登录成功页面提供“退出登录”按钮：只返回登录页以便切换账号，不会删除该 IP 的白名单。
- 默认用户名为 `admin`，默认密码为 `P@ssw0rd`，可通过命令行管理菜单重置。
- 凭据以 root-only SHA-256 哈希保存；支持 `chattr +i` 时还会加 immutable 锁。
- 白名单/黑名单状态保存在 `/var/lib/web-auth-firewall/state.json`，重启后自动恢复。
- 服务由 systemd 托管：`web-auth-firewall.service`。

## 安装

```bash
sudo ./setup_web_firewall.sh
```

运行后进入交互式管理菜单。选择 `1) 安装 / 更新` 即可完成安装。

也可以跳过菜单直接安装：

```bash
chmod +x setup_web_firewall.sh
sudo ./setup_web_firewall.sh --install
```

如果当前会话是通过 SSH 连接的，脚本会自动把当前 SSH 客户端 IP 加入白名单，避免安装完成后把自己锁在外面。默认只对当前已建立的连接生效，新 IP 仍需要先访问 18622 登录。

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
7) 查看服务状态与防火墙规则
8) 卸载 Web 认证防火墙
9) 自定义登录地址
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
sudo ./setup_web_firewall.sh --uninstall         # 卸载并恢复之前的规则
```

## 使用流程

1. 浏览器打开登录地址（默认 `http://服务器IP:18622/`；设置了自定义路径时，从命令行菜单顶部查看完整地址）。
2. 输入 `admin` / `P@ssw0rd` 登录。
3. 登录成功页面出现后，当前客户端 IP 已被加入 nftables 白名单，即可访问服务器的其他端口。
4. 登录成功页面会同时显示客户端自己的 IP，以及服务器当前开放的 TCP/UDP 端口列表。
5. 登录成功页面下方是“访问名单管理”：可以直接查看白名单/黑名单 IP，添加或删除任意地址。
6. 右上角“退出登录”只回到登录页面，白名单中的 IP 会继续保留。

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

状态文件中的白名单和黑名单都以 `{ "IP": 到期时间戳 }` 形式保存。到期条目由服务每 60 秒检查一次并自动从 nftables 和状态文件中清除。

## 重要说明

- 认证页面目前使用 HTTP，密码在网络中是明文传输。如果服务器暴露在公网，建议在前方加 HTTPS 反向代理，或至少通过 VPN/内网使用。
- 脚本会接管 `/etc/nftables.conf` 并执行 `flush ruleset`，安装前会备份原规则到 `/etc/nftables.conf.pre-web-auth`。
- 脚本会禁用 ufw 和 firewalld，避免两套防火墙互相冲突。
- 如果服务器运行 Docker，请先确认 Docker 的端口映射策略与本规则兼容；Docker 的 nftables/iptables 表可能被 `flush ruleset` 清理。
- 同一 IP 在 5 分钟内累计 3 次登录失败才会被拉黑；拉黑后无法再访问 18622 认证页面，需要管理员在命令行菜单中手动解除，或等待 48 小时自动过期。
- ping 使用 ICMP 协议，不属于 TCP/UDP 端口：默认情况下只有白名单 IP 可以 ping；如需让任意 IP 都能 ping，请使用 `--allow-icmp` 安装。
