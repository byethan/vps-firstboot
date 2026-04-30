# VPS SSH Login Hardening

只做这几件事：

- 给已有 SSH 用户安装 SSH key，默认是 `root`
- 关闭 SSH 密码登录
- root 只允许密钥登录
- SSH 端口改到你指定的值
- 安装并配置 `fail2ban` 保护 SSH 端口
- 处理 `ssh.socket` 仍监听 22 的问题

脚本不会创建用户，也不会配置 sudo。

## 使用

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

- SSH 实际监听状态
- `sshd -T` 关键配置
- `fail2ban` 服务状态
- `fail2ban` 的 `sshd` jail 状态

确认能登录后，再关闭 root 会话。

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
