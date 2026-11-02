#!/usr/bin/env bash
# Runs the real setup flows with system paths moved into a temp directory and
# Linux tools replaced by stubs. Nothing here touches the host.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/vps-firstboot.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
REAL_PATH="$PATH"
CHECKS=0

ssh-keygen -q -t ed25519 -N '' -C sandbox-key -f "$TEST_TMP/key"
NEW_KEY="$(cat "$TEST_TMP/key.pub")"
OLD_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLDOLD provider-key'

fail() {
  printf 'FAIL [%s]: %s\n' "${SCENARIO:-setup}" "$*" >&2
  if [[ -n "${OUT:-}" && -f "$OUT" ]]; then
    printf -- '--- last output ---\n' >&2
    sed -n '1,200p' "$OUT" >&2
  fi
  exit 1
}

ok() { CHECKS=$(( CHECKS + 1 )); }

assert_has() {
  grep -Fq -- "$2" "$1" || fail "$1 is missing: $2"
  ok
}

assert_lacks() {
  if grep -Fq -- "$2" "$1" 2>/dev/null; then
    fail "$1 unexpectedly has: $2"
  fi
  ok
}

assert_exists() {
  [[ -e "$1" ]] || fail "missing file: $1"
  ok
}

assert_absent() {
  [[ ! -e "$1" ]] || fail "unexpected file: $1"
  ok
}

assert_listening() {
  local got
  got="$(sort -n "$BOX/state/listening" | xargs)"
  [[ "$got" == "$1" ]] || fail "listening on [$got], wanted [$1]"
  ok
}

# The config must not leave any other uncommented Port line behind.
assert_only_port() {
  local got
  got="$(awk 'tolower($1) == "port" {print $2}' "$1" | xargs)"
  [[ "$got" == "$2" ]] || fail "$1 has ports [$got], wanted [$2]"
  ok
}

write_stub() {
  cat >"$BOX/bin/$1"
  chmod +x "$BOX/bin/$1"
}

# Creates a Debian 13 machine whose sshd listens on the given port.
new_box() {
  SCENARIO="$1"
  local port="${2:-22}"
  BOX="$TEST_TMP/box-$RANDOM-$RANDOM"
  OUT="$BOX/out"
  mkdir -p "$BOX"/{bin,state,root/.ssh,boot,var/run,sys/module/tcp_bbr} \
    "$BOX"/etc/{ssh/sshd_config.d,apt/sources.list.d,apt/apt.conf.d,default,sysctl.d,systemd/system} \
    "$BOX"/usr/local/sbin

  {
    printf 'Include /etc/ssh/sshd_config.d/*.conf\n' | sed "s#/etc/#$BOX/etc/#"
    printf 'Port %s\nPasswordAuthentication yes\nPermitRootLogin yes\n' "$port"
  } >"$BOX/etc/ssh/sshd_config"
  printf '%s\n' "$port" >"$BOX/state/listening"
  printf 'ID=debian\nVERSION_CODENAME=trixie\nPRETTY_NAME="Debian GNU/Linux 13"\n' >"$BOX/etc/os-release"
  printf '6.12.113+deb13-amd64\n' >"$BOX/state/uname"
  touch "$BOX/boot/vmlinuz-6.12.113+deb13-amd64"
  : >"$BOX/state/calls"
  printf 'installed linux-image-6.12.113+deb13-amd64 Debian Kernel Team <debian-kernel@lists.debian.org>\n' >"$BOX/state/kdb"
  printf 'net.ipv4.tcp_available_congestion_control=cubic reno bbr\nnet.ipv4.tcp_congestion_control=cubic\nnet.ipv4.tcp_rmem=4096 131072 6291456\nnet.ipv4.tcp_wmem=4096 16384 4194304\n' >"$BOX/state/sysctl"
  printf 'P 500\n  n=trixie,c=main\n' >"$BOX/state/apt-policy"

  # The temp path itself can contain /var/, so substitute it in a last pass.
  sed -e 's#/etc/#@BOX@/etc/#g' -e 's#/root/#@BOX@/root/#g' -e 's#/boot/#@BOX@/boot/#g' \
    -e 's#/var/#@BOX@/var/#g' -e 's#/sys/#@BOX@/sys/#g' -e 's#/usr/local/#@BOX@/usr/local/#g' \
    -e "s#@BOX@#$BOX#g" "$SCRIPT" >"$BOX/vps-firstboot.sh"

  write_stub id <<'EOF'
#!/bin/bash
case "$1" in
  -u) echo 0 ;;
  -gn) echo root ;;
  *) exit 0 ;;
esac
EOF
  write_stub getent <<EOF
#!/bin/bash
echo "root:x:0:0:root:$BOX/root:/bin/bash"
EOF
  write_stub chown <<'EOF'
#!/bin/bash
exit 0
EOF
  write_stub install <<'EOF'
#!/bin/bash
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF
  write_stub sshd <<EOF
#!/bin/bash
case "\$1" in
  -t)
    if [[ "\${2:-}" == "-f" ]]; then
      if [[ -e "$BOX/state/no-include" ]]; then
        echo "\$3: line 1: Bad configuration option: Include" >&2
        exit 1
      fi
      exit 0
    fi
    [[ ! -e "$BOX/state/sshd-t-fails" ]]
    ;;
  -T)
    cat "$BOX/etc/ssh/sshd_config" "$BOX"/etc/ssh/sshd_config.d/*.conf 2>/dev/null |
      awk 'tolower(\$1) == "port" {print "port " \$2; seen = 1}
           tolower(\$1) == "passwordauthentication" && !pw {print "passwordauthentication " \$2; pw = 1}
           tolower(\$1) == "permitrootlogin" && !root {print "permitrootlogin " \$2; root = 1}
           END {if (!seen) print "port 22"}'
    ;;
esac
EOF
  write_stub ss <<EOF
#!/bin/bash
if [[ "\$1" == "-ltnpH" ]]; then
  port="\${2##*:}"
  if [[ -e "$BOX/state/foreign-\$port" ]]; then
    echo "LISTEN 0 128 0.0.0.0:\$port 0.0.0.0:* users:((\"nginx\",pid=9,fd=6))"
  elif grep -qx "\$port" "$BOX/state/listening"; then
    echo "LISTEN 0 128 0.0.0.0:\$port 0.0.0.0:* users:((\"sshd\",pid=8,fd=3))"
  fi
  exit 0
fi
while read -r port; do
  echo "LISTEN 0 128 0.0.0.0:\$port 0.0.0.0:*"
done <"$BOX/state/listening"
EOF
  write_stub systemctl <<EOF
#!/bin/bash
echo "systemctl \$*" >>"$BOX/state/calls"
case "\$1" in
  cat)
    [[ -e "$BOX/state/has-ssh-socket" ]]
    exit \$?
    ;;
  restart)
    case "\$2" in
      sshd.service|ssh.service)
        ports="\$(sshd -T | awk '\$1 == "port" {print \$2}')"
        if [[ -e "$BOX/state/restart-fails-with" ]] && grep -qx "\$(cat "$BOX/state/restart-fails-with")" <<<"\$ports"; then
          exit 1
        fi
        if [[ -e "$BOX/state/cannot-bind" ]]; then
          ports="\$(grep -vx "\$(cat "$BOX/state/cannot-bind")" <<<"\$ports" || true)"
        fi
        printf '%s\n' "\$ports" >"$BOX/state/listening"
        ;;
    esac
    ;;
esac
exit 0
EOF
  write_stub service <<'EOF'
#!/bin/bash
exit 1
EOF
  write_stub ufw <<EOF
#!/bin/bash
echo "ufw \$*" >>"$BOX/state/calls"
if [[ "\$1" == "status" ]]; then
  [[ -e "$BOX/state/ufw-active" ]] && echo "Status: active" || echo "Status: inactive"
fi
EOF
  write_stub firewall-cmd <<'EOF'
#!/bin/bash
exit 1
EOF
  write_stub nft <<EOF
#!/bin/bash
[[ -e "$BOX/state/nft-rules" ]] && cat "$BOX/state/nft-rules"
exit 0
EOF
  write_stub iptables <<'EOF'
#!/bin/bash
exit 1
EOF
  write_stub apt-get <<EOF
#!/bin/bash
echo "apt-get frontend=\${DEBIAN_FRONTEND:-} \$*" >>"$BOX/state/calls"
if [[ " \$* " == *" update "* && -e "$BOX/state/apt-update-locked-times" ]]; then
  left="\$(cat "$BOX/state/apt-update-locked-times")"
  if (( left > 0 )); then
    echo \$(( left - 1 )) >"$BOX/state/apt-update-locked-times"
    echo "E: Could not get lock /var/lib/apt/lists/lock" >&2
    exit 100
  fi
fi
if [[ -e "$BOX/state/apt-fails-on" ]] && [[ " \$* " == *" \$(cat "$BOX/state/apt-fails-on") "* ]]; then
  exit 100
fi
exit 0
EOF
  write_stub apt-cache <<EOF
#!/bin/bash
cat "$BOX/state/apt-policy"
if [[ -e "$BOX/etc/apt/sources.list.d/debian-security.sources" ]]; then
  echo "  n=trixie-security,c=main"
fi
EOF
  write_stub dpkg <<EOF
#!/bin/bash
if [[ "\$1" == "--print-architecture" ]]; then
  echo amd64
  exit 0
fi
echo "dpkg \$*" >>"$BOX/state/calls"
if [[ -e "$BOX/state/dpkg-broken" ]]; then
  echo "dpkg: error processing package foo (--configure):" >&2
  exit 1
fi
if [[ -e "$BOX/state/dpkg-locked-times" ]]; then
  left="\$(cat "$BOX/state/dpkg-locked-times")"
  if (( left > 0 )); then
    echo \$(( left - 1 )) >"$BOX/state/dpkg-locked-times"
    echo "dpkg: error: dpkg frontend lock was locked by another process with pid 6600" >&2
    exit 2
  fi
fi
EOF
  write_stub dpkg-query <<EOF
#!/bin/bash
fmt="\$2"
pkg="\$3"
fmt="\${fmt#-f=}"
case "\$fmt" in
  '\${Maintainer}')
    awk -v p="\$pkg" '\$2 == p {sub(/^[^ ]+ [^ ]+ /, ""); print; found = 1} END {exit !found}' "$BOX/state/kdb"
    ;;
  '\${db:Status-Status}')
    awk -v p="\$pkg" '\$2 == p {printf "%s", \$1; found = 1} END {exit !found}' "$BOX/state/kdb"
    ;;
  *)
    cat "$BOX/state/kdb"
    ;;
esac
EOF
  write_stub uname <<EOF
#!/bin/bash
if [[ "\${1:-}" == "-r" ]]; then
  cat "$BOX/state/uname"
else
  exec /usr/bin/uname "\$@"
fi
EOF
  write_stub timeout <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
  write_stub cloud-init <<EOF
#!/bin/bash
echo "cloud-init \$*" >>"$BOX/state/calls"
EOF
  write_stub sysctl <<EOF
#!/bin/bash
store="$BOX/state/sysctl"
case "\$1" in
  -n)
    line="\$(grep -m1 "^\$2=" "\$store" || true)"
    if [[ -n "\$line" ]]; then
      echo "\${line#*=}"
    elif [[ "\$2" == net.* ]]; then
      echo ""
    else
      exit 1
    fi
    ;;
  -w)
    key="\${2%%=*}"
    grep -v "^\$key=" "\$store" >"\$store.tmp" || true
    echo "\$2" >>"\$store.tmp"
    mv "\$store.tmp" "\$store"
    ;;
esac
exit 0
EOF
  write_stub modprobe <<EOF
#!/bin/bash
echo "modprobe \$*" >>"$BOX/state/calls"
EOF
  write_stub ip <<'EOF'
#!/bin/bash
case "$1" in
  route) echo "default via 192.0.2.1 dev eth0 proto static" ;;
esac
exit 0
EOF
  write_stub tc <<'EOF'
#!/bin/bash
[[ "$1" == "qdisc" && "$2" == "show" ]] && echo "qdisc fq 8001: root refcnt 2"
exit 0
EOF
  for tool in locale-gen update-locale sleep fail2ban-client; do
    write_stub "$tool" <<'EOF'
#!/bin/bash
exit 0
EOF
  done
}

run() {
  local connection="${CONNECTION:-}"
  local status=0
  env -i HOME="$BOX/root" PATH="$BOX/bin:$REAL_PATH" SSH_CONNECTION="$connection" \
    bash "$BOX/vps-firstboot.sh" "$@" >"$OUT" 2>&1 </dev/null || status=$?
  STATUS="$status"
}

expect_ok() {
  run "$@"
  [[ "$STATUS" == "0" ]] || fail "wanted success, got exit $STATUS from: $*"
  ok
}

expect_die() {
  run "$@"
  [[ "$STATUS" != "0" ]] || fail "wanted failure, got success from: $*"
  ok
}

SECURITY=(security --port 20022 --key-file "$TEST_TMP/key.pub" --yes)
INCLUDE_REL="etc/ssh/sshd_config.d/00-login-hardening.conf"

# --------------------------------------------------------------- full first run
new_box first-run
printf '%s' "$OLD_KEY" >"$BOX/root/.ssh/authorized_keys"
expect_ok all --port 20022 --key-file "$TEST_TMP/key.pub" --enable-fail2ban --role web \
  --objective single-stream --target-mbps 800 --rtt-ms 75 --bdp-factor 2 --yes

# The provider's last key had no newline: both keys must keep their own line.
[[ "$(sed -n '1p' "$BOX/root/.ssh/authorized_keys")" == "$OLD_KEY" ]] || fail "old key line was changed"
[[ "$(sed -n '2p' "$BOX/root/.ssh/authorized_keys")" == "$NEW_KEY" ]] || fail "new key is not on its own line"
[[ "$(wc -l <"$BOX/root/.ssh/authorized_keys" | tr -d ' ')" == "2" ]] || fail "authorized_keys should have 2 lines"
ok

assert_has "$BOX/$INCLUDE_REL" "Port 20022"
assert_has "$BOX/$INCLUDE_REL" "PasswordAuthentication no"
assert_has "$BOX/etc/ssh/sshd_config" "# managed by vps-firstboot: Port 22"
assert_only_port "$BOX/$INCLUDE_REL" 20022
assert_listening "20022"
assert_has "$OUT" "ssh_listen_target: yes"
assert_has "$OUT" "ssh_ports: 20022"
assert_has "$OUT" "SSH now listens only on port 20022"
assert_has "$OUT" "ssh -p 20022 root@SERVER_IP"
assert_lacks "$OUT" "confirm-ssh"
assert_has "$OUT" "passwordauthentication: no"
assert_has "$OUT" "system_update: ok"
assert_has "$OUT" "kernel_source: official"
assert_has "$OUT" "third_party_kernels: none"
assert_has "$OUT" "qdiscs_on_default_1: fq"
assert_exists "$BOX/usr/local/sbin/vps-firstboot"

# Updates run in order, without prompts, and only through apt.
assert_has "$BOX/state/calls" "cloud-init status --wait"
assert_has "$BOX/state/calls" "dpkg --force-confdef --force-confold --configure -a"
assert_has "$BOX/state/calls" "frontend=noninteractive -y -o DPkg::Lock::Timeout=300"
assert_has "$BOX/state/calls" "full-upgrade"
assert_has "$BOX/state/calls" "install linux-image-amd64"
assert_has "$BOX/state/calls" "install unattended-upgrades"
assert_has "$BOX/state/calls" "install fail2ban"
assert_has "$BOX/etc/apt/apt.conf.d/20auto-upgrades" 'APT::Periodic::Unattended-Upgrade "1";'
assert_has "$BOX/etc/apt/sources.list.d/debian-security.sources" "Suites: trixie-security"

# Network tuning stays on the distribution kernel.
SYSCTL_FILE="$BOX/etc/sysctl.d/90-vps-bbr-fq.conf"
assert_has "$SYSCTL_FILE" "net.ipv4.tcp_congestion_control = bbr"
assert_has "$SYSCTL_FILE" "net.core.default_qdisc = fq"
assert_has "$SYSCTL_FILE" "net.core.rmem_max = 15000000"
assert_has "$SYSCTL_FILE" "net.ipv4.tcp_slow_start_after_idle = 0"
assert_has "$BOX/etc/modules-load.d/bbr.conf" "tcp_bbr"
assert_has "$BOX/state/sysctl" "net.ipv4.tcp_congestion_control=bbr"
assert_has "$OUT" "tcp_congestion_control: bbr"
assert_lacks "$BOX/state/calls" "bbrv3"
assert_lacks "$OUT" "BBRv3"

# ------------------------------------------------------- moving the SSH port
SCENARIO="rerun-on-same-port"
expect_ok "${SECURITY[@]}" --no-system-update
assert_listening "20022"
assert_only_port "$BOX/$INCLUDE_REL" 20022
[[ "$(grep -c "$(cut -d' ' -f2 "$TEST_TMP/key.pub")" "$BOX/root/.ssh/authorized_keys")" == "1" ]] || fail "key was added twice"
ok

new_box move-from-another-port 2222
expect_ok "${SECURITY[@]}" --no-system-update
assert_listening "20022"
assert_only_port "$BOX/$INCLUDE_REL" 20022
assert_has "$BOX/etc/ssh/sshd_config" "# managed by vps-firstboot: Port 2222"

new_box already-on-target 20022
expect_ok "${SECURITY[@]}" --no-system-update
assert_listening "20022"

# -------------------------------------------------------- nothing gets locked
new_box port-taken
touch "$BOX/state/foreign-20022"
cp "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before"
expect_die "${SECURITY[@]}"
assert_has "$OUT" "already used by another service"
assert_absent "$BOX/root/.ssh/authorized_keys"
assert_absent "$BOX/$INCLUDE_REL"
cmp -s "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before" || fail "sshd_config changed"
ok

new_box bad-key
# A paste cut short still looks like a key, so only ssh-keygen can reject it.
printf '%s\n' "${NEW_KEY:0:40}" >"$BOX/state/bad.pub"
expect_die security --port 20022 --key-file "$BOX/state/bad.pub" --yes
assert_has "$OUT" "the supplied public key is not valid"
assert_absent "$BOX/root/.ssh/authorized_keys"
assert_absent "$BOX/$INCLUDE_REL"

new_box sshd-rejects-config
touch "$BOX/state/sshd-t-fails"
cp "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before"
expect_die "${SECURITY[@]}"
assert_has "$OUT" "sshd rejected the new configuration"
assert_absent "$BOX/$INCLUDE_REL"
cmp -s "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before" || fail "sshd_config was not restored"
ok
assert_listening "22"

new_box restart-fails
printf '20022\n' >"$BOX/state/restart-fails-with"
cp "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before"
expect_die "${SECURITY[@]}"
assert_has "$OUT" "previous SSH configuration was restored"
assert_absent "$BOX/$INCLUDE_REL"
cmp -s "$BOX/etc/ssh/sshd_config" "$BOX/state/config.before" || fail "sshd_config was not restored"
ok
assert_listening "22"

new_box new-port-does-not-bind
printf '20022\n' >"$BOX/state/cannot-bind"
expect_die "${SECURITY[@]}"
assert_has "$OUT" "SSH did not come back on port 20022"
assert_absent "$BOX/$INCLUDE_REL"
assert_listening "22"

new_box no-include-support
touch "$BOX/state/no-include"
expect_ok "${SECURITY[@]}" --no-system-update
assert_absent "$BOX/$INCLUDE_REL"
assert_only_port "$BOX/etc/ssh/sshd_config" 20022
assert_listening "20022"

# ------------------------------------------------------------------ firewalls
new_box ufw-active
touch "$BOX/state/ufw-active"
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$BOX/state/calls" "ufw allow 20022/tcp"
assert_lacks "$OUT" "drops incoming traffic"

new_box default-drop
printf 'table inet filter {\n\tchain input {\n\t\ttype filter hook input priority filter; policy drop;\n\t}\n}\n' >"$BOX/state/nft-rules"
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$OUT" "drops incoming traffic by default"

new_box open-firewall
expect_ok "${SECURITY[@]}" --no-system-update
assert_lacks "$OUT" "drops incoming traffic"
assert_lacks "$BOX/state/calls" "ufw allow"

# --------------------------------------------------------------- socket units
new_box ubuntu-socket
touch "$BOX/state/has-ssh-socket"
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$BOX/state/calls" "systemctl disable --now ssh.socket"
assert_has "$BOX/state/calls" "systemctl enable ssh.service"

new_box no-socket
expect_ok "${SECURITY[@]}" --no-system-update
assert_lacks "$BOX/state/calls" "ssh.socket disable"
assert_lacks "$BOX/state/calls" "systemctl enable ssh.service"

# ------------------------------------------------------------- system updates
new_box update-fails-but-setup-finishes
printf 'full-upgrade\n' >"$BOX/state/apt-fails-on"
expect_ok all --port 20022 --key-file "$TEST_TMP/key.pub" --role general --yes
assert_has "$OUT" "system_update: failed"
assert_has "$OUT" "System update failed"
assert_listening "20022"
assert_exists "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf"
assert_lacks "$BOX/state/calls" "install unattended-upgrades"

# apt-daily can hold the dpkg lock at any moment, and dpkg itself never waits.
new_box dpkg-lock-clears
printf '3\n' >"$BOX/state/dpkg-locked-times"
expect_ok "${SECURITY[@]}"
assert_has "$OUT" "system_update: ok"
assert_has "$OUT" "waiting for another package manager"
assert_has "$BOX/state/calls" "full-upgrade"
assert_exists "$BOX/etc/apt/apt.conf.d/20auto-upgrades"
[[ "$(grep -c 'dpkg --force-confdef' "$BOX/state/calls")" == "4" ]] || fail "dpkg should run 4 times"
ok

new_box dpkg-lock-never-clears
printf '1000\n' >"$BOX/state/dpkg-locked-times"
expect_ok "${SECURITY[@]}"
assert_has "$OUT" "system_update: failed"
assert_has "$OUT" "locked by another process"
assert_has "$OUT" "vps-firstboot security --port 20022 --yes"
assert_lacks "$BOX/state/calls" "full-upgrade"
[[ "$(grep -c 'dpkg --force-confdef' "$BOX/state/calls")" == "30" ]] || fail "dpkg should stop after 30 tries"
ok

new_box dpkg-fails-for-another-reason
touch "$BOX/state/dpkg-broken"
expect_ok "${SECURITY[@]}"
assert_has "$OUT" "system_update: failed"
assert_has "$OUT" "error processing package foo"
[[ "$(grep -c 'dpkg --force-confdef' "$BOX/state/calls")" == "1" ]] || fail "dpkg should not retry a real failure"
ok

new_box apt-lists-lock-clears
printf '4\n' >"$BOX/state/apt-update-locked-times"
expect_ok "${SECURITY[@]}"
assert_has "$OUT" "system_update: ok"

new_box update-skipped
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$OUT" "system_update: disabled"
assert_lacks "$BOX/state/calls" "full-upgrade"
assert_absent "$BOX/etc/apt/apt.conf.d/20auto-upgrades"

new_box security-source-present
printf '  n=trixie-security,c=main\n' >"$BOX/state/apt-policy"
expect_ok "${SECURITY[@]}"
assert_absent "$BOX/etc/apt/sources.list.d/debian-security.sources"

new_box metapackage-present
printf 'installed linux-image-amd64 Debian Kernel Team <debian-kernel@lists.debian.org>\n' >>"$BOX/state/kdb"
expect_ok "${SECURITY[@]}"
assert_lacks "$BOX/state/calls" "install linux-image-amd64"

new_box cloud-kernel
printf '6.12.113+deb13-cloud-amd64\n' >"$BOX/state/uname"
expect_ok "${SECURITY[@]}"
assert_has "$BOX/state/calls" "install linux-image-cloud-amd64"

new_box ubuntu-skips-debian-steps
printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' >"$BOX/etc/os-release"
expect_ok "${SECURITY[@]}"
assert_absent "$BOX/etc/apt/sources.list.d/debian-security.sources"
assert_lacks "$BOX/state/calls" "install linux-image"
assert_has "$BOX/state/calls" "install unattended-upgrades"

new_box fail2ban-failure-does-not-stop-setup
printf 'fail2ban\n' >"$BOX/state/apt-fails-on"
expect_ok "${SECURITY[@]}" --enable-fail2ban --no-system-update
assert_has "$OUT" "fail2ban setup failed"
assert_has "$OUT" "SSH now listens only on port 20022"

# --------------------------------------------------------- kernels and reboot
new_box third-party-kernel
printf '7.3.1-joeyblog-bbrv3\n' >"$BOX/state/uname"
touch "$BOX/boot/vmlinuz-7.3.1-joeyblog-bbrv3"
printf 'installed linux-image-7.3.1-joeyblog-bbrv3 joey <joey@example.com>\n' >>"$BOX/state/kdb"
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$OUT" "kernel_source: third-party"
assert_has "$OUT" "third_party_kernels: linux-image-7.3.1-joeyblog-bbrv3"
assert_has "$OUT" "Third-party kernels are installed"

new_box newer-kernel-needs-reboot
touch "$BOX/boot/vmlinuz-6.12.200+deb13-amd64"
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$OUT" "reboot_required: yes"
assert_has "$OUT" "A newer kernel or library was installed"

new_box running-newest-kernel
expect_ok "${SECURITY[@]}" --no-system-update
assert_has "$OUT" "reboot_required: no"
assert_lacks "$OUT" "A newer kernel or library was installed"

# ---------------------------------------------------------------------- check
new_box check-v1
expect_ok check
assert_has "$OUT" "kernel_source: official"
assert_has "$OUT" "tcp_bbr_version: 1"
assert_has "$OUT" "ssh_ports: 22"
assert_has "$OUT" "automatic_updates: no"
assert_has "$OUT" "qdiscs_on_eth0: fq"
assert_listening "22"
assert_absent "$BOX/$INCLUDE_REL"

new_box check-v3
expect_ok "${SECURITY[@]}" --no-system-update
printf '3\n' >"$BOX/sys/module/tcp_bbr/version"
expect_ok check
assert_has "$OUT" "tcp_bbr_version: 3"
assert_has "$OUT" "ssh_ports: 20022"

# ------------------------------------------------------------ network rollback
new_box network-rollback
expect_ok network --role general --yes
assert_exists "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf"
assert_exists "$BOX/etc/modules-load.d/bbr.conf"
assert_has "$OUT" "vps-firstboot network-rollback -y"
expect_ok network-rollback --yes
assert_absent "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf"
assert_absent "$BOX/etc/modules-load.d/bbr.conf"
assert_lacks "$BOX/state/calls" "ssh.service"

# ---------------------------------------------------------- exit role reserved
new_box exit-role-reserves-ssh-port
printf 'net.ipv4.ip_local_reserved_ports=6000\n' >>"$BOX/state/sysctl"
expect_ok all --port 20022 --key-file "$TEST_TMP/key.pub" --role exit --region overseas --bandwidth 1000 --no-system-update --yes
assert_has "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf" "net.ipv4.ip_local_reserved_ports = 6000,20022"
assert_has "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf" "net.ipv4.ip_local_port_range = 10240 65535"

new_box exit-role-network-only 20022
expect_ok network --role exit --region overseas --bandwidth 1000 --yes
assert_has "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf" "net.ipv4.ip_local_reserved_ports = 20022"

new_box exit-role-low-port
expect_ok network --role exit --region overseas --bandwidth 1000 --yes
assert_lacks "$BOX/etc/sysctl.d/90-vps-bbr-fq.conf" "ip_local_reserved_ports"

# ---------------------------- moving an existing machine there and back
run_installed() {
  local status=0
  env -i HOME="$BOX/root" PATH="$BOX/bin:$BOX/usr/local/sbin:$REAL_PATH" SSH_CONNECTION="${CONNECTION:-}" \
    vps-firstboot "$@" >"$OUT" 2>&1 </dev/null || status=$?
  STATUS="$status"
}

installed_ok() {
  run_installed "$@"
  [[ "$STATUS" == "0" ]] || fail "wanted success, got exit $STATUS from: $*"
  ok
}

new_box round-trip-from-installed-copy 20022
printf '%s\n' "$NEW_KEY" >"$BOX/root/.ssh/authorized_keys"
cp "$BOX/root/.ssh/authorized_keys" "$BOX/state/keys.before"
expect_ok security --port 20022 --no-system-update --yes
assert_listening "20022"

installed_ok security --port 20023 --no-system-update --yes
assert_listening "20023"
assert_lacks "$BOX/state/calls" "full-upgrade"

installed_ok security --port 20022 --no-system-update --yes
assert_listening "20022"
installed_ok check
assert_has "$OUT" "ssh_ports: 20022"
cmp -s "$BOX/root/.ssh/authorized_keys" "$BOX/state/keys.before" || fail "authorized_keys changed"
ok

printf 'vps-firstboot sandbox tests passed (%s checks)\n' "$CHECKS"
