# VPS SSH Login Hardening

标准流程：

1. 先补基础工具，确保能下载脚本、能跑后续检查
2. 再执行一键脚本做 SSH 加固
3. 按验收清单确认 SSH 状态
4. 最后在落地机上跑大站延迟检测

脚本本身只做这几件事：

- 给已有 SSH 用户安装 SSH key，默认是 `root`
- 关闭 SSH 密码登录
- root 只允许密钥登录
- SSH 端口改到你指定的值
- 修复 Debian/Ubuntu 上常见的 SSH 登录 locale 警告
- 默认配置双栈域名优先 IPv4，不关闭 IPv6
- 默认开启 Linux TCP `BBR + fq`
- 支持 `general` / `transit` / `exit` / `web` 四种用途档位
- 线路机和落地机可按地区、带宽与机器内存自动选择 TCP buffer
- 支持 `install` / `check` / `rollback` 无人值守管理 BBRv3 标准版内核
- 普通一键初始化默认也会安装 BBRv3 标准版内核，但不会自动重启
- 支持锁定 BBRv3 内核版本，适合多台 VPS 分批升级
- 默认只写入最小 TCP/sysctl 基线：`net.core.default_qdisc=fq` 和 `net.ipv4.tcp_congestion_control=bbr`
- 每次应用网络配置前自动备份，可用 `network-rollback` 单独回退网络而不动 SSH 和内核
- 可选安装并启用 `bpftune`，让 Linux 通过 BPF 做长期自动调优
- 可选配置 `tc` 出口整形，适合已测出链路上限的机器
- 写入 `/etc/sysctl.d/90-vps-bbr-fq.conf`
- 自动禁用旧版 `/etc/sysctl.d/99-vps-tcp-tune.conf`，避免残留的大 buffer/backlog 参数继续生效
- 创建 `vps-fq-restore.service`，重启后自动恢复默认路由网卡的 `fq` 队列
- 可选安装并配置 `fail2ban` 保护 SSH 端口
- 处理 `ssh.socket` 仍监听 22 的问题

脚本不会创建用户，也不会配置 sudo。

## 1. 先补基础工具

有些新机器会缺：

- `curl`
- `wget`
- `ca-certificates`
- `tar`
- `bash`
- `ping` / `iputils-ping`
- 如果要用 `tc` 整形，还需要 `iproute2`
- 如果系统缺 locale，脚本会自动安装并生成 `en_US.UTF-8`

这类基础工具没装好时，直接跑脚本或做延迟检测很容易报错。

### Debian / Ubuntu

```bash
apt update
apt install -y curl wget ca-certificates tar xz-utils gzip coreutils util-linux bash iputils-ping iproute2
```

### Rocky / Alma / CentOS / Oracle Linux

```bash
dnf install -y curl wget tar xz gzip coreutils util-linux bash iputils iproute
```

如果没有 `dnf`：

```bash
yum install -y curl wget tar xz gzip coreutils util-linux bash iputils iproute
```

### Alpine

```bash
apk add curl wget tar xz gzip coreutils util-linux bash iputils iproute2
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

Debian / Ubuntu 新机器可以直接按下面这套跑，已包含 SSH 安全加固、网络优化、locale 修复、IPv4 优先策略和 BBRv3 标准版内核安装：

```bash
apt update
apt install -y curl wget ca-certificates tar xz-utils gzip coreutils util-linux bash iputils-ping iproute2 || true

curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh -o /root/vps-firstboot.sh || \
wget -O /root/vps-firstboot.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh

bash /root/vps-firstboot.sh \
  --port 22928 \
  --public-key 'ssh-ed25519 AAAA... your-key-comment' \
  -y
```

脚本不会自动重启。跑完确认新 SSH 端口能登录后，再安排重启切到 BBRv3 内核：

```bash
reboot
```

重启后检查：

```bash
bash /root/vps-firstboot.sh check
```

如果这次只想做 SSH/基础网络初始化，不安装 BBRv3 内核，加：

```bash
  --no-bbrv3-kernel \
```

默认会自动选择 `--region auto --bandwidth auto`：

- 地区：用 VPS 公网 IP 国家码判断，亚太归为 `asia`，其他区域归为 `overseas`
- 带宽：优先读取默认路由网卡的 reported speed，例如 `100`、`625`、`1000`、`10000`
- 如果地区识别失败，默认按 `asia`
- 如果带宽识别失败，亚洲默认按 `500M`，海外默认按 `1000M`
- 有些 VPS 虚拟网卡会统一上报 `10000M`，不一定等于商家套餐限速；脚本会显示 `tcp_profile_source`，发现不准时手动传 `--bandwidth`
- 默认会写入 `/etc/gai.conf` 的地址选择策略，让双栈域名优先走 IPv4；这对 3x-ui / 代理节点生成时优先选到 IPv6 的机器更友好，但不会禁用 IPv6

如果想手动指定，仍然可以覆盖：

```bash
bash /root/vps-firstboot.sh \
  --port 22928 \
  --role transit \
  --bandwidth 625 \
  --region asia \
  --public-key 'ssh-ed25519 AAAA... your-key-comment' \
  -y
```

`--role` 决定机器用途，地区和带宽决定是否需要 TCP buffer 以及 buffer 档位：

| 用途 | 参数 | 默认策略 |
| --- | --- | --- |
| 普通初始化 | `--role general` | 只写 BBR + FQ，保留系统自动 buffer |
| 线路机/中转机 | `--role transit` | 自动启用内存受限的智能 buffer，并设置 4MiB 输出节奏、MTU 探测和关闭空闲慢启动 |
| 落地鸡/代理出口 | `--role exit` | 使用线路机策略，另外扩大本地临时端口范围 |
| 建站鸡 | `--role web` | 保留系统 buffer，只增加保守的监听队列、SYN 队列、MTU 探测和空闲连接优化 |

脚本不会尝试根据进程自动猜机器用途。新装空机器没有足够信息可靠区分线路机、落地鸡和建站鸡，因此默认使用最安全的 `general`，用途由一键命令显式指定。

线路机和落地机默认启用智能 buffer，档位参考 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3#bbr-v3-智能带宽优化) 的智能带宽策略：

| 套餐带宽 | 亚太 | 欧美 |
| --- | ---: | ---: |
| `<500M` | 8MiB | 16MiB |
| `500-999M` | 12MiB | 48MiB |
| `1000-1999M` | 16MiB | 64MiB |
| `2000-4999M` | 24MiB | 64MiB |
| `5000-9999M` | 28MiB | 64MiB |
| `>=10000M` | 32MiB | 64MiB |

机器内存不足时还会限制上限：小于 512MiB 最多 16MiB，512MiB 到 1GiB 最多 32MiB，1GiB 以上最多 64MiB。可以用 `--no-smart-tune` 禁用自动 buffer，或用 `--enable-smart-tune` 在其他用途上显式启用。

常用完整命令：

```bash
# 亚太线路机，例如香港/日本 625M
bash /root/vps-firstboot.sh --port 22928 --role transit --region asia --bandwidth 625 --public-key 'ssh-ed25519 AAAA... your-key-comment' -y

# 欧美落地鸡，1G
bash /root/vps-firstboot.sh --port 22928 --role exit --region overseas --bandwidth 1000 --public-key 'ssh-ed25519 AAAA... your-key-comment' -y

# 建站鸡，地区和带宽可继续自动识别
bash /root/vps-firstboot.sh --port 22928 --role web --region auto --bandwidth auto --public-key 'ssh-ed25519 AAAA... your-key-comment' -y
```

公网 IP 归属地与实际机房不一致时必须手动指定物理线路。例如澳洲 IP 实际部署在香港，应使用 `--region asia`。网卡上报的 `10000M` 也可能只是虚拟端口速度，套餐只有 100M/500M 时应手动填写真实套餐带宽。

通用写法是先确认你本地有 SSH 公钥：

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
# 通用机器：自动选择地区和带宽，只保留 BBR + FQ
sudo bash vps-firstboot.sh --network-only --role general

# 亚洲线路机：港 / 日 / 韩 / 新加坡
sudo bash vps-firstboot.sh --network-only --role transit --bandwidth 500 --region asia
sudo bash vps-firstboot.sh --network-only --role transit --bandwidth 1000 --region asia

# 美国 / 欧洲落地鸡
sudo bash vps-firstboot.sh --network-only --role exit --bandwidth 1000 --region overseas

# 建站鸡
sudo bash vps-firstboot.sh --network-only --role web --bandwidth auto --region auto

# 只预览配置，不应用
bash vps-firstboot.sh --dry-run
```

脚本默认的 `general` 用途会开启系统级 Linux TCP `BBR + fq`，只写入两条最小 TCP/sysctl 基线：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

旧版脚本写过的 `/etc/sysctl.d/99-vps-tcp-tune.conf` 会被自动改名为 `.disabled`，避免 `rmem_max`、`wmem_max`、`tcp_rmem`、`tcp_wmem`、`netdev_max_backlog` 这类激进参数继续参与 `sysctl --system`。

脚本也会默认写入 `/etc/gai.conf` 的 IPv4 优先策略：

```text
precedence ::1/128 50
precedence ::/0 40
precedence 2002::/16 30
precedence ::/96 20
precedence ::ffff:0:0/96 100
```

这表示当一个域名同时有 A 和 AAAA 记录时，系统地址选择会优先 IPv4-mapped 地址。它不会关闭 IPv6；如果某台机器明确想保留系统默认双栈选择，可以加：

```bash
sudo bash vps-firstboot.sh --network-only --no-prefer-ipv4 -y
```

如果你已经知道瓶颈带宽和 RTT，可以按 BDP 写入 `tcp_rmem` / `tcp_wmem` 的最大值。公式是：

```text
BDP bytes = bottleneck_mbps * 1000000 * rtt_ms / 8000
```

例如本地瓶颈约 600Mbps、到 VPS RTT 约 170ms，先预览：

```bash
bash vps-firstboot.sh \
  --network-only \
  --enable-bdp-tune \
  --bdp-bandwidth 600 \
  --bdp-rtt 170 \
  --dry-run
```

确认输出里的 BDP buffer 合理后再应用：

```bash
sudo bash vps-firstboot.sh \
  --network-only \
  --enable-bdp-tune \
  --bdp-bandwidth 600 \
  --bdp-rtt 170 \
  -y
```

脚本会写入 `/etc/sysctl.d/90-vps-bbr-fq.conf`，大致类似：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 12750000
net.core.wmem_max = 12750000
net.ipv4.tcp_rmem = 4096 87380 12750000
net.ipv4.tcp_wmem = 4096 16384 12750000
```

如果晚高峰 `iperf3` 测出来 0 重传或低重传，可以用 `--bdp-extra-mib 1`、`--bdp-extra-mib 2` 逐步加一点余量；如果重传高或速度抖动，就去掉余量或降低 `--bdp-bandwidth`。不要一上来写 64MiB、128MiB、512MiB 这种大 buffer。

手动 BDP 的优先级高于智能带宽档位。也就是说，线路机或落地机同时传入 `--bdp-bandwidth` 和 `--bdp-rtt` 时，脚本使用真实 BDP 结果，不再写智能档位的 buffer；用途对应的 MTU 探测、输出节奏等保守参数仍然保留。

每次正式应用前，脚本会把它管理的 sysctl、`/etc/gai.conf`、FQ 恢复服务和 `tc` 整形文件备份到：

```text
/root/vps-firstboot-backups/<时间>-network
```

如果新参数效果不理想，可以只回退网络配置，不动 SSH 端口、SSH key 和内核：

```bash
bash /root/vps-firstboot.sh network-rollback -y
```

该命令恢复最近一次网络备份。它会覆盖这些受管路径在备份后发生的修改，因此业务机器仍建议先使用 `--dry-run`，并从一台测试机开始。若运行态队列没有完全恢复，重启一次即可按回退后的持久配置重新加载。

测试时在 VPS 上临时启动 `iperf3` 服务端，并从你的瓶颈网络客户端测试下行单线程：

```bash
# VPS 侧，测试时临时运行
iperf3 -s

# 客户端侧
iperf3 -c SERVER_IP -R -t 30
```

## BBRv3 内核管理

脚本支持无人值守安装 BBRv3 标准版内核，并默认启用 `BBR + fq`。普通初始化流程已经默认包含这一步；也可以单独使用 `install` 子命令给已初始化的老机器补装/升级内核。安装阶段不会自动重启，原系统内核也不会被删除，方便在面板或 GRUB 里回退。

上游来源是 `byJoey/Actions-bbr-v3` 的 GitHub Releases。上游主脚本仍以交互菜单为主；这里不模拟菜单按键，而是直接用 Releases API 选择标准版 `.deb` 内核包安装。

支持范围：

- Debian 12 / Debian 13
- Ubuntu 24.04+
- `x86_64` / `aarch64`
- 默认安装标准 BBRv3，不安装 `-max` 激进版

先在一台测试机上跑：

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh -o /root/vps-firstboot.sh || \
wget -O /root/vps-firstboot.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh

bash /root/vps-firstboot.sh install -y
```

安装后手动重启：

```bash
reboot
```

重启回来检查：

```bash
bash /root/vps-firstboot.sh check
```

如果要锁定某个已测试稳定的版本：

```bash
bash /root/vps-firstboot.sh install --bbrv3-version x86_64-7.1.2 --lock-bbrv3-version -y
```

之后不显式传 `--bbrv3-version` 时，会优先使用 `/etc/vps-firstboot/bbrv3-version.lock` 里的版本，避免十几台机器突然装到未经测试的新版本。

如果需要回滚：

```bash
bash /root/vps-firstboot.sh rollback -y
```

回滚会恢复最近一次 sysctl 备份，删除本脚本写入的 BBR/fq 配置，并尽量移除非当前运行中的 BBRv3 内核包。脚本不会删除当前正在运行的内核；如果当前就在 BBRv3 内核里，需要先通过面板/GRUB 启动回原内核，再跑 rollback。

## 批量升级

十几台 VPS 不需要逐台登录，可以用本仓库的批量脚本从本地 Mac 执行。准备一个 hosts 文件：

```text
hk1 root@1.2.3.4 22928
jp1 root@2001:db8::10 22928
root@example.com
```

推荐流程：

```bash
# 1. 先审计所有机器
bash vps-fleet-bbrv3.sh hosts.txt audit

# 2. 先挑一台测试机单独安装，稳定后再批量
bash vps-fleet-bbrv3.sh test-hosts.txt install

# 3. 批量安装，但不重启
bash vps-fleet-bbrv3.sh hosts.txt install

# 4. 每批 2 台滚动重启，SSH 恢复并 verify 后继续
bash vps-fleet-bbrv3.sh hosts.txt rolling-reboot --batch-size 2

# 5. 最终复查
bash vps-fleet-bbrv3.sh hosts.txt verify
```

如果有关键业务机器，建议把它们单独放在最后一个 hosts 文件里，每批 1 台滚动。

如果某台机器不想动网络队列和 TCP 拥塞控制，可以加：

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

脚本不会写 128MiB、256MiB 这类无内存保护的大 buffer/backlog 模板，也不关闭 IPv6。如果不想配置 BBR/FQ 和用途调优，只保留 SSH 加固，可以使用 `general` 并同时关闭 BBR/FQ 和智能 buffer：

```bash
sudo bash vps-firstboot.sh \
  --user <user> \
  --port <ssh-port> \
  --role general \
  --no-bbr-fq \
  --no-smart-tune \
  --public-key 'ssh-ed25519 AAAA... your-key-comment'
```

如果 `/etc/sysctl.conf` 或 `/etc/sysctl.d/99-sysctl.conf` 里也残留旧 TCP 参数，脚本只会提示，不会自动删除。建议先备份，再人工看输出：

```bash
bak=/root/sysctl-bak-$(date +%F-%H%M)
mkdir -p "$bak"
cp -a /etc/sysctl.conf /etc/sysctl.d "$bak"/
echo "$bak"

grep -RnsE 'default_qdisc|tcp_congestion_control|rmem_max|wmem_max|tcp_rmem|tcp_wmem|netdev_max_backlog|somaxconn|tcp_fastopen|tcp_mtu_probing|slow_start_after_idle' /etc/sysctl.conf /etc/sysctl.d
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
- `tcp_profile`
- `tcp_profile_source`
- `tcp_profile_country`
- `tcp_profile_iface`
- `bdp_tune`
- `bbr_available`
- `default_qdisc`
- `tcp_congestion_control`
- `rmem_max`
- `wmem_max`
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
- [ ] `/etc/gai.conf` 里有 `precedence ::ffff:0:0/96 100`
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
grep -nE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf
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

## 4. 落地机大站延迟检测

先确认依赖在：

```bash
which curl
which wget
which bash
which ping
```

再跑：

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh -o /tmp/vps-speedtest.sh || \
wget -O /tmp/vps-speedtest.sh https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-speedtest.sh

bash /tmp/vps-speedtest.sh sites
```

默认会从当前机器依次 Ping Google、YouTube、GitHub、Apple、Microsoft、Cloudflare、OpenAI、Telegram、Netflix、TikTok、X、AWS、Steam、NodeSeek 等常用大站，输出平均延迟和丢包率。

想多打几次包，或只测指定网站：

```bash
bash /tmp/vps-speedtest.sh sites --count 6 --timeout 5
bash /tmp/vps-speedtest.sh sites github.com chatgpt.com www.youtube.com
```

如果检测报：

- `curl: command not found`
- `wget: command not found`
- `ping: command not found`

先回到“先补基础工具”这一步，不要直接硬跑。

## 没传 public key 时

如果没有传 `--public-key` 或 `--key-file`，脚本会尝试复用 `/root/.ssh/authorized_keys`。

如果 root 下面也没有可用 key，脚本会直接中止，不会继续关闭密码登录。

如果传了 `--public-key` 或 `--key-file`，脚本会把新 key 追加到目标用户的 `authorized_keys`，不会清空原有 key。重复运行同一把 key 时不会重复追加。

如果目标用户就是 `root`，且没有额外传 key，脚本会直接复用现有 `/root/.ssh/authorized_keys`，不会再把同一个文件复制给自己。

## 脚本改动的配置

SSH 配置默认会写到：

```text
/etc/ssh/sshd_config.d/00-login-hardening.conf
```

内容大概是：

```text
Port <your-port>
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin without-password
PermitEmptyPasswords no
AllowUsers root
UseDNS no
AcceptEnv LANG
```

脚本会先备份 `/etc/ssh/sshd_config` 到同目录的时间戳文件。为了保证 drop-in 配置真实生效，它会注释主配置里全局范围内和登录加固冲突的 SSH 指令，例如 `Port`、`PasswordAuthentication`、`PermitRootLogin`、`AllowUsers` 等；`Match` 块内的内容不会被批量改写。旧版脚本生成的 `/etc/ssh/sshd_config.d/99-login-hardening.conf` 会被清理，避免同一组托管配置重复出现。

如果服务器上的 OpenSSH 太旧，不支持 `Include` 指令，脚本会自动改用内联模式，把同一组配置写入 `/etc/ssh/sshd_config` 顶部的 `# BEGIN managed by vps-firstboot` 配置块中。重复运行脚本时会更新这段托管配置，并移除旧版脚本可能留下的 `/etc/ssh/sshd_config.d/*.conf` 引用，避免出现 `Bad configuration option: Include`。

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

TCP 最小基线配置会写到：

```text
/etc/sysctl.d/90-vps-bbr-fq.conf
```

默认内容大概是：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
```

旧版脚本生成的这些文件会被禁用或清理，避免 sysctl 顺序互相覆盖：

```text
/etc/sysctl.d/99-vps-tcp-tune.conf
/etc/sysctl.d/99-joeyblog.conf
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
