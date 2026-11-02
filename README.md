# VPS Firstboot：安全初始化与 BBR/TCP 调优

新 VPS 粘贴一条命令就能完成初始化，不安装第三方内核。脚本分成两部分，也可以单独运行：

- 第一部分 `security`：SSH 密钥、端口和登录加固、系统更新和自动安全更新、locale、可选 fail2ban。
- 第二部分 `network`：系统内核自带的 BBR + FQ、按用途和目标调 TCP、可选 tc/bpftune。
- 入口 `all`：先运行第一部分，再运行第二部分。

第一部分不改 sysctl 和 qdisc，但系统更新可能安装新的官方内核。第二部分不改 SSH、密钥、端口、locale 和内核。

| 文件 | 用途 |
| --- | --- |
| `vps-firstboot.sh` | 完整实现；支持 `security`、`network`、`all` 和管理命令 |
| `vps-security.sh` | 只运行第一部分的入口 |
| `vps-network-tune.sh` | 只运行第二部分的入口 |
| `vps-speedtest.sh` | 单线程、多线程对比和站点延迟验证 |

## 一键初始化

用 root 登录新机器后粘贴下面的命令，先替换前五行里的占位符。命令里只用 ASCII，避免没有设置 locale 的服务器弄乱粘贴内容。

`commit` 和 `sum` 固定脚本版本，下载内容不符时命令会停止，不会运行：

```bash
bash <<'VPS'
set -Eeuo pipefail
port='<SSH_PORT>'
key='<SSH_PUBLIC_KEY>'
role='web'; target='<TARGET_Mbps>'; rtt='<RTT_MS>'; factor='2'
commit='<COMMIT>'
sum='<SHA256>'
main=/root/vps-firstboot.sh
if ! command -v curl >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 update </dev/null
  DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=300 install curl ca-certificates </dev/null
fi
curl -fsSL --retry 3 "https://raw.githubusercontent.com/byethan/vps-firstboot/$commit/vps-firstboot.sh" -o "$main" </dev/null
echo "$sum  $main" | sha256sum -c -
printf '%s\n' "$key" | bash "$main" all --port "$port" --public-key-stdin --enable-fail2ban \
  --role "$role" --objective single-stream --target-mbps "$target" --rtt-ms "$rtt" --bdp-factor "$factor" \
  --yes 2>&1 | tee -a /root/vps-firstboot-run.log
VPS
```

取当前版本的 `commit` 和 `sum`：

```bash
git rev-parse HEAD
shasum -a 256 vps-firstboot.sh
```

跑完后按输出提示操作：

1. 保持当前窗口不要关。
2. 在云厂商的安全组或防火墙里放行新端口。
3. 另开一个窗口，用新端口登录：`ssh -p <SSH_PORT> root@<SERVER_IP>`。
4. 在新窗口里关闭旧端口：`vps-firstboot confirm-ssh`。
5. 如果输出提示安装了新内核，执行 `reboot`。

## SSH 端口切换

脚本不会立刻关掉旧端口，新端口连不上时不会把你锁在外面：

- 运行后，sshd 同时监听旧端口和新端口。密码登录立刻关闭，两个端口都只接受密钥。
- `vps-firstboot confirm-ssh` 要从新端口的会话里运行，这样能确认新端口和密钥都可用。从旧端口的会话运行会被拒绝。
- 从控制台等非 SSH 环境运行时无法做这项检查，脚本会先询问确认。
- 如果忘了运行，旧端口会继续开着，但只接受密钥。
- `vps-firstboot check` 的 `ssh_temporary_ports` 会显示还有哪些旧端口没关。

修改 SSH 配置时：

- 目标端口被其他服务占用时直接退出，不改任何文件。
- 公钥写入前先校验，公钥无效时直接退出。
- `authorized_keys` 最后一行没有换行时，新公钥不会和它粘在一起。
- `sshd -t` 校验失败、重启失败或新端口没有监听时，自动恢复原配置。
- ufw 或 firewalld 启用时自动放行新端口。其他防火墙默认拒绝入站时只给出警告。

## 系统更新

第一部分会在 apt 系统上运行下面这些步骤，不会自动重启：

- 等待 cloud-init 结束，等待 apt 锁。
- Debian 12/13 缺少 security 源时补上。
- 运行 `full-upgrade`。
- Debian 没有内核元包时补上，否则 apt 不会安装新内核。
- 安装 `unattended-upgrades` 并开启自动安全更新。

更新失败不会中断后续步骤，输出里的 `system_update` 会显示 `failed`。不想更新就加 `--no-system-update`。

已上线的机器重新运行 `security` 或 `all` 也会执行更新，要注意维护窗口。

## 第二部分：BBR、TCP 与单线程吞吐调优

BBR 和 FQ 直接用发行版内核自带的版本，Debian 上是 BBR v1。脚本不安装第三方内核：第三方内核版本号通常更高，GRUB 会优先启动它，Debian 的内核安全更新就不会生效。机器上发现第三方内核时，脚本只给出警告，不会自动卸载。

### 用途 role

| role | 默认行为 |
| --- | --- |
| `general` | BBR + FQ，保留系统自动 buffer；最稳妥的默认值 |
| `transit` | 智能 buffer、MTU 探测、关闭空闲后的慢启动 |
| `exit` | transit 策略，再扩大本地临时端口范围并预留 SSH 端口 |
| `web` | 系统自动 buffer，只设置较保守的监听/SYN 队列和 MTU 探测 |

`transit` 指有本机 TCP 连接终止的中转/代理服务。纯三层转发的数据包不经过本机 TCP 拥塞控制，BBR 和 socket buffer 不会直接加速纯路由转发。

### 调优目标 objective

| objective | 适合场景 | buffer 策略 |
| --- | --- | --- |
| `latency` | 低延迟优先 | 系统自动 buffer，不主动放大 |
| `balanced` | 日常通用 | 按 role 决定；transit/exit 默认智能档位 |
| `single-stream` | 跨地区单线程下载/上传 | `2 × BDP`，需要目标带宽和 RTT；关闭空闲后的慢启动 |
| `throughput` | 吞吐优先、允许更大内存占用 | `3 × BDP`，需要目标带宽和 RTT；关闭空闲后的慢启动 |
| `custom` | 已经压测并知道准确值 | 使用明确的 `--buffer-mib` |

计算方式：

```text
BDP bytes = target_mbps × 1,000,000 × rtt_ms / 8,000
TCP max buffer = BDP bytes × factor + extra_mib × 1,048,576
```

单线程目标默认 factor 为 2，吞吐目标默认 factor 为 3；可用 `--bdp-factor 1..4` 覆盖。脚本保留当前系统 `tcp_rmem/tcp_wmem` 的 min/default，只替换 max。

### 常用命令

通用机，只启用 BBR + FQ：

```bash
bash /root/vps-firstboot.sh network --role general --objective balanced -y
```

亚太线路机，按角色、地区、带宽和内存选择智能 buffer：

```bash
bash /root/vps-firstboot.sh network \
  --role transit \
  --objective balanced \
  --region asia \
  --bandwidth <PACKAGE_Mbps> \
  -y
```

针对一条已经测得 RTT 的跨地区单线程链路，先预览：

```bash
bash /root/vps-firstboot.sh network \
  --role transit \
  --objective single-stream \
  --target-mbps <TARGET_Mbps> \
  --rtt-ms <MEASURED_RTT_MS> \
  --dry-run
```

确认预览后把 `--dry-run` 改为 `-y`。目标带宽应填真实瓶颈或希望达到的单线程速度，不是虚拟网卡上报的 10G 端口速度。

已经压测出准确 buffer 时可以手动指定，它的优先级高于 BDP 和智能档位：

```bash
bash /root/vps-firstboot.sh network --role general --buffer-mib <BUFFER_MiB> --dry-run
```

### 内存安全上限

脚本同时限制智能、BDP 和自定义 buffer：

| VPS 内存 | 默认单方向最大 buffer |
| --- | ---: |
| `< 512MiB` | 16MiB |
| `512MiB–1GiB` | 32MiB |
| `>= 1GiB` | 64MiB |

BDP 或手动值超过上限时，脚本默认中止并说明原因。只有已经评估并压测过内存占用时，才显式加入 `--allow-unsafe-buffer`。无论是否放开，单方向 max 都不会超过 512MiB。

### 自动识别与隐私

只有 `transit/exit + balanced + smart tune` 真正需要自动地区时，脚本才会访问公网国家码服务。其他组合不会发起国家码请求。

自动带宽优先读取默认路由网卡 reported speed。虚拟网卡常上报 10G，但这不代表套餐带宽；生产机建议显式传入 `--bandwidth`。

### 可选 tc 与 bpftune

已知出口物理上限时可以用 tc 主动整形：

```bash
bash /root/vps-firstboot.sh network \
  --role general \
  --tc-iface <IFACE> \
  --tc-rate <RATE_mbit> \
  --tc-mtu <MTU> \
  -y
```

网卡、MTU 和 rate 必须来自实际测量。可选 `--enable-bpftune` 会编译并启用 BPF 自动调优服务，要求 systemd、kernel BTF 和较新的 BPF 支持；小内存或旧内核机器不建议启用。

## 管理命令

脚本运行时会把自己安装到 `/usr/local/sbin/vps-firstboot`：

```bash
# 查看内核来源、BBR 版本、qdisc、SSH 端口、是否需要重启和自动更新状态
vps-firstboot check

# 从新端口的会话里关闭旧 SSH 端口
vps-firstboot confirm-ssh

# 恢复最近一次网络配置备份，不动 SSH 和内核
vps-firstboot network-rollback -y
```

每次应用网络配置前都会备份到 `/root/vps-firstboot-backups/<timestamp>-network`。回滚只恢复本脚本管理的 sysctl 文件、`/etc/gai.conf`、FQ/tc 文件及原 service 状态，不会覆盖无关的安全、VM 或业务 sysctl。

## 单线程验证

VPS 端临时启动服务：

```bash
bash vps-speedtest.sh server --port 5201
```

在真实瓶颈客户端测试：

```bash
bash vps-speedtest.sh single <VPS_HOST> --port 5201 -t 30
bash vps-speedtest.sh compare <VPS_HOST> --port 5201 -P 4 -t 30
```

默认只打印上传/下载 Mbps、流数、重传和 RTT 摘要，目标与路由隐藏。需要完整排障信息时显式加入 `--show-sensitive`。建议白天和晚高峰各测多次，不要因为一次测速结果就永久放大 buffer。

## 测试

```bash
bash tests/test-vps-firstboot-dry-run.sh
bash tests/test-vps-firstboot-sandbox.sh
```

`sandbox` 测试把系统路径换到临时目录，用模拟命令跑完整流程，不会碰本机。它不能代替在真实机器上验证 sshd、apt 和 GRUB 的实际行为。

## 隐私与敏感信息

- 推荐 `--key-file` 或 `--public-key-stdin`；`--public-key` 可能进入 shell 历史和进程列表。
- 公钥正文不写入脚本日志和 dry-run 输出。
- 自动识别的国家码和网卡名默认只显示“已检测（隐藏）”。
- 测速脚本默认隐藏目标；`--show-sensitive` 必须显式开启。
- README 和测试只使用占位符，不包含真实公钥、IP、域名或令牌。

## 主要受管配置

```text
/usr/local/sbin/vps-firstboot
/etc/ssh/sshd_config.d/00-login-hardening.conf
/etc/apt/sources.list.d/debian-security.sources
/etc/apt/apt.conf.d/20auto-upgrades
/etc/default/locale
/etc/fail2ban/jail.d/sshd.local
/etc/sysctl.d/90-vps-bbr-fq.conf
/etc/modules-load.d/bbr.conf
/etc/gai.conf
/etc/default/vps-fq-restore
/usr/local/sbin/vps-fq-restore
/etc/systemd/system/vps-fq-restore.service
/etc/default/vps-tc-shape
/usr/local/sbin/vps-tc-shape
/etc/systemd/system/vps-tc-shape.service
```

脚本发现 `/etc/sysctl.conf` 或 `/etc/sysctl.d/99-sysctl.conf` 仍有冲突网络参数时只报警，不会删除用户配置。FQ 恢复服务只替换简单的 `pfifo/pfifo_fast/bfifo/fq_codel` 根队列，会保留 `mq`、`multiq`、`htb`、`cake`、`noqueue` 和未知/自定义 qdisc 布局。

## 最低验收

安全部分：

- 新端口可用密钥登录。
- `confirm-ssh` 之后，`vps-firstboot check` 的 `ssh_temporary_ports` 显示 `none`。
- `passwordauthentication no`。
- root 为 key-only。

网络部分：

- `kernel_source` 为 `official`，`third_party_kernels` 为 `none`。
- 重启后 `tcp_congestion_control` 返回 `bbr`，`default_qdisc` 返回 `fq`。
- `tc qdisc show` 没有破坏原有多队列、整形或自定义层级。
- P=1 的 iperf3 在不显著增加重传和延迟的前提下达到目标。
- 效果不理想时使用 `network-rollback`，不要继续盲目叠加大 buffer。
