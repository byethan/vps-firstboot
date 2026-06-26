# VPS SSH Login Hardening

标准流程：

1. 先补基础工具，确保能下载脚本、能跑后续检查
2. 再执行一键脚本做 SSH 加固
3. 按验收清单确认 SSH 状态
4. 最后再跑 `nq`

脚本本身只做这几件事：

- 给已有 SSH 用户安装 SSH key，默认是 `root`
- 关闭 SSH 密码登录
- root 只允许密钥登录
- SSH 端口改到你指定的值
- 修复 Debian/Ubuntu 上常见的 SSH 登录 locale 警告
- 默认开启 Linux TCP `BBR + fq`
- 默认按地区和带宽应用 VPS TCP/sysctl 优化
- 可选安装并启用 `bpftune`，让 Linux 通过 BPF 做长期自动调优
- 可选配置 `tc` 出口整形，适合已测出链路上限的机器
- 写入 `/etc/sysctl.d/99-vps-tcp-tune.conf`
- 创建 `vps-fq-restore.service`，重启后自动恢复默认路由网卡的 `fq` 队列
- 可选安装并配置 `fail2ban` 保护 SSH 端口
- 处理 `ssh.socket` 仍监听 22 的问题

脚本不会创建用户，也不会配置 sudo。

## 1. 先补基础工具

有些新机器会缺：

- `curl`
- `wget`
- `tar`
- `bash`
- 如果要用 `tc` 整形，还需要 `iproute2`
- 如果系统缺 locale，脚本会自动安装并生成 `en_US.UTF-8`

这类基础工具没装好时，直接跑脚本或跑 `nq` 很容易报错。

### Debian / Ubuntu

```bash
apt update
apt install -y curl wget tar xz-utils gzip coreutils util-linux bash iproute2
```

### Rocky / Alma / CentOS / Oracle Linux

```bash
dnf install -y curl wget tar xz gzip coreutils util-linux bash iproute
```

如果没有 `dnf`：

```bash
yum install -y curl wget tar xz gzip coreutils util-linux bash iproute
```

### Alpine

```bash
apk add curl wget tar xz gzip coreutils util-linux bash iproute2
```

### 其他冷门系统

先看系统类型：

```bash
cat /etc/os-release
uname -a
```

然后再按系统选对应包管理器。不要在没确认系统类型前直接套 Debian 命令。

## 2. 跑一键脚本

### 最新版一键执行

Debian / Ubuntu 新机器可以直接按下面这套跑，已包含 SSH 安全加固和网络优化：

```bash
apt update
apt install -y curl wget tar xz-utils gzip coreutils util-linux bash iproute2 || true

curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh -o /root/vps-firstboot.sh || \
wget -O /root/vps-firstboot.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh

bash /root/vps-firstboot.sh \
  --port 22928 \
  --bandwidth 1000 \
  --region asia \
  --public-key 'ssh-ed25519 AAAA... your-key-comment' \
  -y
```

如果这台是亚洲 500M，把这两行改成：

```bash
  --bandwidth 500 \
  --region asia \
```

如果是欧美 1000M，把这两行改成：

```bash
  --bandwidth 1000 \
  --region overseas \
```

通用写法是先确认你本地有 SSH 公钥：

```bash
cat ~/.ssh/id_ed25519.pub
```

把脚本传到 VPS 后运行：

```bash
sudo bash vps-firstboot.sh \
  --port <ssh-port> \
  --bandwidth 500 \
  --region asia \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果你当前就是 `root`，通常直接跑：

```bash
bash /root/vps-firstboot.sh \
  --port <ssh-port> \
  --bandwidth 500 \
  --region asia \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果想换用户或端口：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --bandwidth 1000 \
  --region overseas \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果想安装 `fail2ban`：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --bandwidth 1000 \
  --region asia \
  --enable-fail2ban \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

网络优化可以单独跑，也可以和 SSH 加固一起跑。线路建议：

```bash
# 亚洲线路：港 / 日 / 韩 / 新加坡
sudo bash vps-firstboot.sh --bandwidth 500 --region asia
sudo bash vps-firstboot.sh --bandwidth 1000 --region asia

# 美国 / 欧洲线路
sudo bash vps-firstboot.sh --bandwidth 1000 --region overseas

# 只预览配置，不应用
bash vps-firstboot.sh --bandwidth 1000 --region asia --dry-run
```

脚本默认会开启系统级 Linux TCP `BBR + fq`，并写入一组按 `--region` 和 `--bandwidth` 选择的 TCP 参数。如果某台机器不想动网络队列和 TCP 拥塞控制，可以加：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --bandwidth 500 \
  --region asia \
  --no-bbr-fq \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

说明：系统级 `net.ipv4.tcp_congestion_control=bbr` 主要作用在 TCP。QUIC 是 UDP，QUIC 代理自身是否使用 BBR 取决于程序内部实现；但 `net.core.default_qdisc=fq` 仍然适合作为 VPS 的通用队列/pacing 基线。

如果想让系统后续根据实际负载自动调优，可以显式启用 `bpftune`：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --bandwidth 1000 \
  --region asia \
  --enable-bpftune \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

`bpftune` 是 BPF daemon，不是单文件 sysctl 模板。脚本会安装编译依赖、克隆 `https://github.com/byethan/bpftune.git`、编译安装并启用 `bpftune.service`。它要求系统有 `systemd`、较新的 BPF 支持和 kernel BTF，通常需要 `/sys/kernel/btf/vmlinux` 存在。老内核、精简内核、小内存机器不建议默认启用。

如果只想单独启用动态调优，不做 SSH 加固：

```bash
sudo bash vps-firstboot.sh --network-only --enable-bpftune -y
```

可选覆盖源码位置：

```bash
sudo BPFTUNE_REF=main BPFTUNE_SRC_DIR=/usr/local/src/bpftune \
  bash vps-firstboot.sh --network-only --enable-bpftune -y
```

TCP/sysctl 优化包含：

- `net.core.rmem_max` / `net.core.wmem_max`
- `net.ipv4.tcp_rmem` / `net.ipv4.tcp_wmem`
- `net.ipv4.tcp_mtu_probing = 1`
- `net.ipv4.tcp_fastopen = 3`
- `net.ipv4.tcp_slow_start_after_idle = 0`
- `net.ipv4.tcp_syncookies = 1`
- `net.ipv4.tcp_tw_reuse = 1`
- `net.ipv4.tcp_keepalive_time = 600`
- `net.ipv4.tcp_keepalive_intvl = 60`
- `net.ipv4.tcp_keepalive_probes = 5`
- `net.ipv4.tcp_max_syn_backlog`
- `net.core.somaxconn`
- `net.core.netdev_max_backlog`
- `net.ipv4.ip_local_port_range = 10240 65535`

这些参数不包含关闭 IPv6 这类强环境假设。如果不想改 TCP/sysctl 参数，只保留 SSH 加固，可以加：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --no-vps-sysctl \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果你已经测过链路，想把出口速率主动压在上限以下，可以显式启用 `tc` 整形。比如 100M 口压到 97M，且链路 MTU 需要 1492：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --tc-iface ens17 \
  --tc-rate 97mbit \
  --tc-mtu 1492 \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

`tc` 整形会立即生效；带 `systemd` 的系统会额外写入 `vps-tc-shape.service`，重启后自动恢复。不要照抄 `ens17`、`1492`、`97mbit`，这些必须按实际网卡名、MTU 和带宽测试结果改。

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
- `usedns`
- `acceptenv`
- `system_locale`
- `locale_check_skip`
- `bbr_available`
- `default_qdisc`
- `tcp_congestion_control`
- `tcp_rmem`
- `tcp_wmem`
- `tcp_mtu_probing`
- `tcp_fastopen`
- `tcp_slow_start_after_idle`
- `tcp_tw_reuse`
- `tcp_keepalive`
- `tcp_max_syn_backlog`
- `ip_local_port_range`
- `somaxconn`
- `fq_restore_service`
- 如果启用了 `bpftune`，还会显示 `bpftune_binary`、`bpftune_service`
- 默认路由网卡的 `tc_qdisc_<iface>`
- 如果启用了 `tc` 整形，还会显示 `tc_shape`、`tc_qdisc_root`
- 如果启用了 `fail2ban`，还会显示 `fail2ban_service`、`fail2ban_jail_sshd`、`fail2ban_banned`

确认能登录后，再关闭 root 会话。

## 3. 验收清单

每台机器跑完后，至少确认下面这几项：

- [ ] 本地能用新端口重新登录
- [ ] SSH 实际监听的是目标端口
- [ ] `passwordauthentication no`
- [ ] `permitrootlogin prohibit-password`
- [ ] `allowusers root`
- [ ] `usedns no`
- [ ] `acceptenv LANG`
- [ ] `system_locale en_US.UTF-8`
- [ ] `default_qdisc fq`
- [ ] `tcp_congestion_control bbr`
- [ ] `tcp_mtu_probing 1`
- [ ] `tcp_fastopen 3`
- [ ] `tcp_slow_start_after_idle 0`
- [ ] `fq_restore_service enabled`
- [ ] 如果启用了 `bpftune`，确认 `bpftune_service enabled/active`

如果脚本输出不够，手动补查：

```bash
ss -ltnp | grep -E ':(22|<ssh-port>)\b'
sshd -T | grep -E '^(port|passwordauthentication|permitrootlogin|allowusers|pubkeyauthentication|usedns|acceptenv)'
cat /etc/default/locale
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
sysctl net.ipv4.tcp_mtu_probing net.ipv4.tcp_fastopen net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
systemctl is-enabled vps-fq-restore.service
systemctl is-enabled bpftune.service
systemctl is-active bpftune.service
tc qdisc show
tc qdisc show dev <iface>
```

如果启用了 `fail2ban`，再补查：

```bash
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

如果传了 `--public-key` 或 `--key-file`，脚本会把新 key 追加到目标用户的 `authorized_keys`，不会清空原有 key。重复运行同一把 key 时不会重复追加。

如果目标用户就是 `root`，且没有额外传 key，脚本会直接复用现有 `/root/.ssh/authorized_keys`，不会再把同一个文件复制给自己。

## 脚本改动的配置

SSH 配置会写到：

```text
/etc/ssh/sshd_config.d/00-login-hardening.conf
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
UseDNS no
AcceptEnv LANG
```

脚本会先备份 `/etc/ssh/sshd_config` 到同目录的时间戳文件。为了保证 drop-in 配置真实生效，它会注释主配置里全局范围内和登录加固冲突的 SSH 指令，例如 `Port`、`PasswordAuthentication`、`PermitRootLogin`、`AllowUsers` 等；`Match` 块内的内容不会被批量改写。旧版脚本生成的 `/etc/ssh/sshd_config.d/99-login-hardening.conf` 会被清理，避免同一组托管配置重复出现。

`AcceptEnv LANG` 会保留正常语言环境，但不再接受 macOS 常见的 `LC_CTYPE=UTF-8`，避免 Debian/Ubuntu 登录时出现 `invalid locale` 和 `setlocale` 警告。

locale 默认配置为：

```text
LANG=en_US.UTF-8
LC_CTYPE=en_US.UTF-8
```

如果 cloud-init 存在，脚本还会写入：

```text
/var/lib/cloud/instance/locale-check.skip
```

如果启用了 `fail2ban`，配置会写到：

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

TCP 优化配置会写到：

```text
/etc/sysctl.d/99-vps-tcp-tune.conf
```

亚洲 1000M profile 的内容大概是：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 16384
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 32768
net.ipv4.ip_local_port_range = 10240 65535
```

旧版脚本生成的这两个文件会被清理，避免 sysctl 顺序互相覆盖：

```text
/etc/sysctl.d/98-vps-baseline.conf
/etc/sysctl.d/99-bbr-fq.conf
```

`fq` 自动恢复会写入：

```text
/etc/default/vps-fq-restore
/usr/local/sbin/vps-fq-restore
/etc/systemd/system/vps-fq-restore.service
```

如果启用了 `tc` 整形，会写入：

```text
/etc/default/vps-tc-shape
/usr/local/sbin/vps-tc-shape
/etc/systemd/system/vps-tc-shape.service
```

如果启用了 `bpftune`，脚本会克隆源码到：

```text
/usr/local/src/bpftune
```

并通过仓库自带的 `make install` 安装 `bpftune`、共享库、tuner 插件和 systemd 服务。默认启用：

```text
bpftune.service
```

查看状态：

```bash
systemctl status bpftune --no-pager
bpftune -S
```

## 家里到 VPS 真实测速

想测“自己家里访问 VPS 到底快不快”，不要只在 VPS 上跑 Speedtest。更准确的方式是 VPS 做 `iperf3` 服务端，家里电脑做客户端。

### VPS 端

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh -o /root/vps-speedtest.sh || \
wget -O /root/vps-speedtest.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh

bash /root/vps-speedtest.sh server --port 5201
```

保持这个 SSH 窗口不要关。如果连不上，记得在云厂商安全组和系统防火墙里放行 TCP `5201`。

### 家里电脑

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh -o /tmp/vps-speedtest.sh || \
wget -O /tmp/vps-speedtest.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh

bash /tmp/vps-speedtest.sh client <VPS_IP> --port 5201 -P 4 -t 30
```

结果里第一段是家里到 VPS 的上传，带 `-R` 的第二段是 VPS 到家里的下载。建议白天测一次，晚高峰再测一次。
