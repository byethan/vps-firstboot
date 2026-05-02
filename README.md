# VPS SSH Login Hardening

标准流程：

1. 先补基础工具，确保能下载脚本、能跑后续检查
2. 再执行一键脚本做 SSH 加固和 `fail2ban`
3. 按验收清单确认 SSH 和 `fail2ban` 状态
4. 最后再跑 `nq`

脚本本身只做这几件事：

- 给已有 SSH 用户安装 SSH key，默认是 `root`
- 关闭 SSH 密码登录
- root 只允许密钥登录
- SSH 端口改到你指定的值
- 安装并配置 `fail2ban` 保护 SSH 端口
- 处理 `ssh.socket` 仍监听 22 的问题

脚本不会创建用户，也不会配置 sudo。

## 1. 先补基础工具

有些新机器会缺：

- `curl`
- `wget`
- `tar`
- `bash`

这类基础工具没装好时，直接跑脚本或跑 `nq` 很容易报错。

### Debian / Ubuntu

```bash
apt update
apt install -y curl wget tar xz-utils gzip coreutils util-linux bash
```

### Rocky / Alma / CentOS / Oracle Linux

```bash
dnf install -y curl wget tar xz gzip coreutils util-linux bash
```

如果没有 `dnf`：

```bash
yum install -y curl wget tar xz gzip coreutils util-linux bash
```

### Alpine

```bash
apk add curl wget tar xz gzip coreutils util-linux bash
```

### 其他冷门系统

先看系统类型：

```bash
cat /etc/os-release
uname -a
```

然后再按系统选对应包管理器。不要在没确认系统类型前直接套 Debian 命令。

## 2. 跑一键脚本

先确认你本地有 SSH 公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

把脚本传到 VPS 后运行：

```bash
sudo bash vps-firstboot.sh \
  --port <ssh-port> \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果你当前就是 `root`，通常直接跑：

```bash
bash /root/vps-firstboot.sh \
  --port <ssh-port> \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果想换用户或端口：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果不想安装 `fail2ban`：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --no-fail2ban \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

脚本结束后不要关闭当前 SSH 会话。另开一个终端测试：

```bash
ssh -p <ssh-port> root@SERVER_IP
```

脚本运行结束时会顺手显示：

- `ssh_listen_target`
- `ssh_listen_22`
- `sshd_port`
- `pubkeyauthentication`
- `passwordauthentication`
- `permitrootlogin`
- `allowusers`
- `fail2ban_service`
- `fail2ban_jail_sshd`
- `fail2ban_banned`

确认能登录后，再关闭 root 会话。

## 3. 验收清单

每台机器跑完后，至少确认下面这几项：

- [ ] 本地能用新端口重新登录
- [ ] SSH 实际监听的是目标端口
- [ ] `passwordauthentication no`
- [ ] `permitrootlogin without-password`
- [ ] `allowusers root`
- [ ] `fail2ban` 服务是运行中
- [ ] `fail2ban` 的 `sshd` jail 已启用

如果脚本输出不够，手动补查：

```bash
ss -ltnp | grep -E ':(22|<ssh-port>)\b'
sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin|allowusers|pubkeyauthentication)'
systemctl status fail2ban --no-pager
fail2ban-client status
fail2ban-client status sshd
```

## 4. 再跑 NQ

先确认依赖在：

```bash
which curl
which tar
which bash
```

再跑：

```bash
bash <(curl -sL https://run.NodeQuality.com)
```

如果 `nq` 报：

- `curl: command not found`
- `tar: command not found`
- `BenchOs: No such file or directory`

先回到“先补基础工具”这一步，不要直接硬跑。

## 没传 public key 时

如果没有传 `--public-key` 或 `--key-file`，脚本会尝试复用 `/root/.ssh/authorized_keys`。

如果 root 下面也没有可用 key，脚本会直接中止，不会继续关闭密码登录。

## 脚本改动的配置

SSH 配置会写到：

```text
/etc/ssh/sshd_config.d/99-login-hardening.conf
```

内容大概是：

```text
Port <your-port>
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
AllowUsers root
```

Fail2ban 配置会写到：

```text
/etc/fail2ban/jail.d/sshd.local
```

内容大概是：

```text
[sshd]
enabled = true
port = <your-port>
maxretry = 5
findtime = 10m
bantime = 1h
backend = systemd
```

`backend` 会按系统自动选择，带 `systemd` 的机器通常会写成 `systemd`，其他环境会回落到 `auto`。
