# VPS Firstboot：安全初始化与 BBR/TCP 系统化调优

这套脚本分成两个可以独立执行的部分，同时保留原来的一键总入口：

- 第一部分 `security`：SSH 密钥、端口和登录加固、locale、可选 fail2ban。
- 第二部分 `network`：系统内核自带的 BBR + FQ、按用途和目标调 TCP、单线程吞吐、可选 BBRv3 内核和 tc/bpftune。
- 兼容入口 `all`：先安全初始化，再做网络调优。

安全部分不会修改 sysctl、qdisc 或内核；网络部分不会修改 SSH、密钥、端口或 locale。

## 文件与入口

| 文件 | 用途 |
| --- | --- |
| `vps-security.sh` | 第一部分独立一键入口 |
| `vps-network-tune.sh` | 第二部分独立一键入口 |
| `vps-firstboot.sh` | 完整实现；支持 `security`、`network`、`all` 和管理命令 |
| `vps-speedtest.sh` | 单线程、多线程对比和站点延迟验证 |
| `vps-fleet-bbrv3.sh` | 多 VPS 审计、安装和滚动重启 |

## 安装脚本

```bash
curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-firstboot.sh \
  -o /root/vps-firstboot.sh

curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-security.sh \
  -o /root/vps-security.sh

curl -fsSL https://raw.githubusercontent.com/byethan/vps-firstboot/main/vps-network-tune.sh \
  -o /root/vps-network-tune.sh
```

建议先下载再执行，便于检查脚本内容和固定版本。正式批量部署时，最好把 URL 中的 `main` 换成已经验收过的 commit。

## 第一部分：VPS 安全与基础初始化

推荐把公钥保存为 VPS 上权限为 `0600` 的临时文件，再传给脚本：

```bash
bash /root/vps-security.sh \
  --port <SSH_PORT> \
  --key-file /root/admin-key.pub \
  --enable-fail2ban \
  -y
```

也可以从标准输入读取一行公钥，避免公钥出现在 shell 历史和进程参数里：

```bash
bash /root/vps-security.sh \
  --port <SSH_PORT> \
  --public-key-stdin \
  -y
```

命令会等待你粘贴一行公钥。脚本日志只显示“已提供”，不会回显正文。

第一部分会：

- 给已有用户安装公钥，默认用户是 `root`；不会创建新用户。
- 修改 SSH 端口，关闭密码和空密码登录。
- root 保持密钥登录，不会完全禁用 root。
- 写入 `AllowUsers`、关闭 `UseDNS`，只接受 `LANG` 环境变量。
- 修复 Debian/Ubuntu 常见的 locale 登录警告。
- 可选安装 fail2ban。
- 修改前校验 `sshd` 配置；失败时不会带着无效配置继续重启。

先预览：

```bash
bash /root/vps-security.sh \
  --port <SSH_PORT> \
  --key-file /root/admin-key.pub \
  --dry-run
```

执行后不要立刻关闭当前 SSH 会话。另开终端确认新端口和密钥可以登录，再结束旧会话。

## 第二部分：BBR、TCP 与单线程吞吐调优

### 用途 role

| role | 默认行为 |
| --- | --- |
| `general` | BBR + FQ，保留系统自动 buffer；最稳妥的默认值 |
| `transit` | 智能 buffer、MTU 探测、关闭空闲后的慢启动 |
| `exit` | transit 策略，再扩大本地临时端口范围 |
| `web` | 系统自动 buffer，只设置较保守的监听/SYN 队列和 MTU 探测 |

`transit` 指有本机 TCP 连接终止的中转/代理服务。纯三层转发的数据包不经过本机 TCP 拥塞控制，BBR 和 socket buffer 不会直接加速纯路由转发。

### 调优目标 objective

| objective | 适合场景 | buffer 策略 |
| --- | --- | --- |
| `latency` | 低延迟优先 | 系统自动 buffer，不主动放大 |
| `balanced` | 日常通用 | 按 role 决定；transit/exit 默认智能档位 |
| `single-stream` | 跨地区单线程下载/上传 | `2 × BDP`，需要目标带宽和 RTT |
| `throughput` | 吞吐优先、允许更大内存占用 | `3 × BDP`，需要目标带宽和 RTT |
| `custom` | 已经压测并知道准确值 | 使用明确的 `--buffer-mib` |

计算方式：

```text
BDP bytes = target_mbps × 1,000,000 × rtt_ms / 8,000
TCP max buffer = BDP bytes × factor + extra_mib × 1,048,576
```

单线程目标默认 factor 为 2，吞吐目标默认 factor 为 3；可用 `--bdp-factor 1..4` 覆盖。脚本保留当前系统 `tcp_rmem/tcp_wmem` 的 min/default，只替换 max，不再硬编码所有机器都相同的中间值。

### 常用命令

通用机，只启用系统内核自带的 BBR + FQ，不安装第三方内核：

```bash
bash /root/vps-network-tune.sh \
  --role general \
  --objective balanced \
  -y
```

亚太线路机，按角色、地区、带宽和内存选择智能 buffer：

```bash
bash /root/vps-network-tune.sh \
  --role transit \
  --objective balanced \
  --region asia \
  --bandwidth <PACKAGE_Mbps> \
  -y
```

针对一条已经测得 RTT 的跨地区单线程链路：

```bash
bash /root/vps-network-tune.sh \
  --role transit \
  --objective single-stream \
  --target-mbps <TARGET_Mbps> \
  --rtt-ms <MEASURED_RTT_MS> \
  --dry-run
```

确认预览后把 `--dry-run` 改为 `-y`。目标带宽应填真实瓶颈或希望达到的单线程速度，不是虚拟网卡上报的 10G 端口速度。

吞吐优先：

```bash
bash /root/vps-network-tune.sh \
  --role exit \
  --objective throughput \
  --target-mbps <TARGET_Mbps> \
  --rtt-ms <MEASURED_RTT_MS> \
  -y
```

已经压测出准确 buffer 时，可以手动指定；它的优先级高于 BDP 和智能档位：

```bash
bash /root/vps-network-tune.sh \
  --role general \
  --buffer-mib <BUFFER_MiB> \
  --dry-run
```

### 内存安全上限

脚本同时限制智能、BDP 和自定义 buffer：

| VPS 内存 | 默认单方向最大 buffer |
| --- | ---: |
| `< 512MiB` | 16MiB |
| `512MiB–1GiB` | 32MiB |
| `>= 1GiB` | 64MiB |

BDP 或手动值超过上限时，脚本默认中止并说明原因，不会静默套用大 buffer。只有已经评估并压测过内存占用时，才显式加入：

```bash
--allow-unsafe-buffer
```

无论是否放开 RAM 安全上限，单方向 max 都不会超过 512MiB。

### 自动识别与隐私

只有 `transit/exit + balanced + smart tune` 真正需要自动地区时，脚本才会访问公网国家码服务。`general`、`web`、显式 BDP 和自定义 buffer 不再为了显示 profile 而发起国家码请求。

自动带宽优先读取默认路由网卡 reported speed。虚拟网卡常上报 10G，但这不代表套餐带宽；生产机建议显式传入 `--bandwidth`。

### 可选 tc 与 bpftune

已知出口物理上限时可以用 tc 主动整形，例如把 100M 链路压在略低于上限的位置：

```bash
bash /root/vps-network-tune.sh \
  --role general \
  --tc-iface <IFACE> \
  --tc-rate <RATE_mbit> \
  --tc-mtu <MTU> \
  -y
```

网卡、MTU 和 rate 必须来自实际测量，不要照抄示例。可选 `--enable-bpftune` 会编译并启用 BPF 自动调优服务，要求 systemd、kernel BTF 和较新的 BPF 支持；小内存或旧内核机器不建议默认启用。

## 完整兼容入口

仍可一次运行两部分：

```bash
bash /root/vps-firstboot.sh all \
  --port <SSH_PORT> \
  --key-file /root/admin-key.pub \
  --role general \
  -y
```

旧的无子命令写法仍兼容。只传网络参数且不传 SSH 端口时，会自动进入 network 域；新部署建议显式使用 `security`、`network` 或两个独立脚本，避免意图不清。

## BBRv3 内核管理

默认不安装。`network` 和 `all` 直接启用 Debian 官方内核自带的 BBR（v1）+ FQ。只有加 `--enable-bbrv3-kernel` 或运行 `install` 才会安装 BBRv3 内核。

这个内核来自第三方 GitHub Releases，版本号通常高于 Debian 内核，GRUB 会优先启动它，所以 Debian 的内核安全更新装上后也不会生效，要自己跟进它的更新。

支持 Debian 12/13、Ubuntu 24.04+ 的 `x86_64` 和 `aarch64`：

```bash
# 安装标准版；不自动重启
bash /root/vps-firstboot.sh install -y

# 查看当前内核、BBR、qdisc、版本锁和已记录包
bash /root/vps-firstboot.sh check

# 先从 GRUB/面板启动回原内核，再回滚本脚本记录的非运行中 BBRv3 包
bash /root/vps-firstboot.sh rollback -y
```

安装安全措施：

- Release 必须来自配置的 GitHub 仓库和选定 tag。
- 每个 `.deb` 先校验 GitHub API 提供的文件大小和 SHA-256 digest。
- 再校验 Debian 包名和架构，之后才调用 `dpkg`。
- 安装包名写入 `/var/lib/vps-firstboot/bbrv3/<tag>/packages.tsv`。
- rollback 只考虑 manifest 中准确记录的包，不再用 `bbr|7.*` 模糊匹配系统内核。
- 当前正在运行的内核永远不会被删除。
- 不自动重启；应在维护窗口手工重启和验证。

可以锁定已经验收过的 tag：

```bash
bash /root/vps-firstboot.sh install \
  --bbrv3-version <TESTED_RELEASE_TAG> \
  --lock-bbrv3-version \
  -y
```

## 网络回滚

每次正式应用网络配置前，会备份脚本管理的网络文件和相关 service 状态：

```text
/root/vps-firstboot-backups/<timestamp>-network
```

回滚：

```bash
bash /root/vps-firstboot.sh network-rollback -y
```

它只恢复本脚本管理的 sysctl 文件、`/etc/gai.conf`、FQ/tc 文件及原 service 状态，不恢复整个 `/etc/sysctl.d`，不会顺带覆盖无关的安全、VM 或业务 sysctl；也不会修改 SSH 和内核。

## 单线程验证

VPS 端临时启动服务：

```bash
bash vps-speedtest.sh server --port 5201
```

在真实瓶颈客户端测试单线程：

```bash
bash vps-speedtest.sh single <VPS_HOST> --port 5201 -t 30
```

同时比较单线程和 4 流：

```bash
bash vps-speedtest.sh compare <VPS_HOST> --port 5201 -P 4 -t 30
```

默认只打印上传/下载 Mbps、流数、重传和 RTT 摘要，目标与路由隐藏。需要完整 iperf/ping/mtr 排障信息时显式加入 `--show-sensitive`。建议白天和晚高峰各测多次；不要因为一次测速结果就永久放大 buffer。

## 批量 BBRv3 升级

hosts 文件支持：

```text
node-a root@<HOST_A> <SSH_PORT>
node-b root@<HOST_B> <SSH_PORT>
```

```bash
bash vps-fleet-bbrv3.sh hosts.txt audit
bash vps-fleet-bbrv3.sh test-hosts.txt install
bash vps-fleet-bbrv3.sh hosts.txt install
bash vps-fleet-bbrv3.sh hosts.txt rolling-reboot --batch-size 2
bash vps-fleet-bbrv3.sh hosts.txt verify
```

批量脚本默认只显示节点别名，不显示 SSH 目标和端口；排障时可加 `--show-sensitive`。

## 隐私与敏感信息

- 推荐 `--key-file` 或 `--public-key-stdin`；`--public-key` 兼容但可能进入 shell 历史和进程列表。
- 公钥正文永不写入脚本日志和 dry-run 输出。
- GitHub Token 通过 curl 标准输入配置传递，不放进 curl 命令行参数。
- 自动识别的国家码和网卡名默认只显示“已检测（隐藏）”。
- 测速与批量脚本默认隐藏目标；`--show-sensitive` 必须显式开启。
- README 和测试只使用占位符，不包含真实公钥、IP、域名或令牌。

## 主要受管配置

```text
/etc/ssh/sshd_config.d/00-login-hardening.conf
/etc/default/locale
/etc/fail2ban/jail.d/sshd.local
/etc/sysctl.d/90-vps-bbr-fq.conf
/etc/gai.conf
/etc/default/vps-fq-restore
/usr/local/sbin/vps-fq-restore
/etc/systemd/system/vps-fq-restore.service
/etc/default/vps-tc-shape
/usr/local/sbin/vps-tc-shape
/etc/systemd/system/vps-tc-shape.service
```

脚本发现 `/etc/sysctl.conf` 或 `/etc/sysctl.d/99-sysctl.conf` 仍有冲突网络参数时只报警，不会删除用户配置。FQ 恢复服务只替换简单的 `pfifo/pfifo_fast/bfifo/fq_codel` 根队列；会保留 `mq`、`multiq`、`htb`、`cake`、`noqueue` 和未知/自定义 qdisc 布局。

## 最低验收

安全部分：

- 新端口可用密钥登录。
- `passwordauthentication no`。
- root 为 key-only。
- 当前旧 SSH 会话在第二个会话验证前保持打开。

网络部分：

- 重启后 `uname -r` 是预期内核。
- `sysctl net.ipv4.tcp_congestion_control` 返回 `bbr`。
- `sysctl net.core.default_qdisc` 返回 `fq`。
- `tc qdisc show` 没有破坏原有多队列、整形或自定义层级。
- P=1 的 iperf3 在不显著增加重传和延迟的前提下达到目标。
- 效果不理想时使用 `network-rollback`，不要继续盲目叠加大 buffer。
