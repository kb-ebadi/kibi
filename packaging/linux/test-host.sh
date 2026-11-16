#!/bin/bash
# Installs each package on THIS machine (root, systemd): the .deb where
# there is dpkg (Debian, Ubuntu), else the .rpm (Fedora, RHEL), runs containers
# through the packaged engine, and removes the package again. Images,
# containers and volumes in /var/lib/kibi are kept (remove, never purge). For
# a test machine or VM: a kibi daemon already running here is stopped first
# (only with KIBI_TEST_KILL=1, since its containers end with it) and not
# started again.
#   sudo KIBI_TEST_KILL=1 packaging/linux/test-host.sh <outdir> [static docker CLI dir]
# Exit status is the number of failed checks.
set -u
out=$(cd "$1" && pwd) clidir=${2:-}
fail=0
ok() { echo "  [ok]   $1"; }
bad() { echo "  [FAIL] $1"; fail=$((fail + 1)); }
log=$(mktemp)
trap 'rm -f "$log"' EXIT
check() { if eval "$2" >"$log" 2>&1; then ok "$1"; else bad "$1"; sed 's/^/         /' "$log" | tail -4; fi; }
[ -d /run/systemd/system ] || { echo "no systemd here; use test.sh"; exit 1; }
if pgrep -x kibi >/dev/null; then
  if [ "${KIBI_TEST_KILL:-}" = 1 ]; then pkill -x kibi; sleep 1; else
    echo "a kibi daemon is running on this machine; this test stops it (and every container it runs) and does not start it again. Set KIBI_TEST_KILL=1 to go on." >&2
    exit 1
  fi
fi

if command -v dpkg >/dev/null; then fmt=deb; else fmt=rpm; fi
# The package file for kibi or kibi-lite (kibi-[0-9]* so kibi doesn't match kibi-lite).
pkgfile() { if [ "$fmt" = deb ]; then ls "$out"/${1}_*.deb 2>/dev/null; else ls "$out"/${1}-[0-9]*.rpm 2>/dev/null; fi; }

host_test() { # name full(0|1)
  local name=$1 full=$2 deb cli= slot_free=1 install remove
  deb=$(pkgfile "$name")
  # dnf, not rpm -i: it brings what the package requires (update-alternatives).
  if [ "$fmt" = deb ]; then install="dpkg -i '$deb'" remove="dpkg -r $name"; else install="dnf install -y -q '$deb'" remove="rpm -e $name"; fi
  # postinst offers Kibi's docker through update-alternatives only when
  # /usr/bin/docker is absent or already an alternatives link; one that
  # belongs to something else (Docker Desktop's symlink in WSL, a docker-ce
  # file) must be left alone, and Kibi's CLI is then /usr/libexec/kibi/docker.
  if [ -e /usr/bin/docker ] || [ -L /usr/bin/docker ]; then
    case "$(readlink /usr/bin/docker 2>/dev/null)" in /etc/alternatives/*) ;; *) slot_free=0 ;; esac
  fi
  # The unit links /var/run/docker.sock to Kibi only when nothing is there.
  local sock_free=1
  { [ -e /run/docker.sock ] || [ -L /run/docker.sock ]; } && sock_free=0
  echo
  echo "#### $name on $(. /etc/os-release; echo "$PRETTY_NAME")"
  check "${install%% *} install $(basename "$deb")" "$install"
  # Installing runs nothing: the engine starts when someone sets Kibi up.
  check "installed, engine not started or enabled" "! systemctl is-enabled -q kibi && ! systemctl is-active -q kibi && test ! -S /run/kibi/docker.sock"
  # The window's setup checklist: \`kibi host-access USER\` (through pkexec)
  # starts the engine and lets an account in at once, by name on the socket's
  # access list, without it signing in again. Checked as that user with no
  # groups at all, as a session started before the change would be.
  check "polkit action for the password prompt" "test -f /usr/share/polkit-1/actions/dev.kibi.host-access.policy"
  userdel kibi-acl-test >/dev/null 2>&1; useradd --system --no-create-home kibi-acl-test
  userdel kibi-acl-other >/dev/null 2>&1; useradd --system --no-create-home kibi-acl-other
  check "kibi host-access starts the engine and adds the account to the kibi group" "/usr/bin/kibi host-access kibi-acl-test && systemctl is-enabled -q kibi && systemctl is-active -q kibi && id -nG kibi-acl-test | grep -qw kibi"
  for _ in $(seq 30); do [ -S /run/kibi/docker.sock ] && break; sleep 1; done
  check "socket /run/kibi/docker.sock, group kibi, mode 660" "test -S /run/kibi/docker.sock && stat -c '%G %a' /run/kibi/docker.sock | grep -q '^kibi 660'"
  check "an account without host-access is refused" "! setpriv --reuid=kibi-acl-other --regid=kibi-acl-other --clear-groups curl -fs --unix-socket /run/kibi/docker.sock http://kibi/_ping"
  userdel kibi-acl-other >/dev/null 2>&1
  check "and it gets in now, without signing in again" "setpriv --reuid=kibi-acl-test --regid=kibi-acl-test --clear-groups curl -fs --unix-socket /run/kibi/docker.sock http://kibi/_ping | grep -q OK"
  check "still in after the engine restarts" "systemctl restart kibi && for i in \$(seq 30); do [ -S /run/kibi/docker.sock ] && break; sleep 1; done; setpriv --reuid=kibi-acl-test --regid=kibi-acl-test --clear-groups curl -fs --unix-socket /run/kibi/docker.sock http://kibi/_ping | grep -q OK"
  userdel kibi-acl-test >/dev/null 2>&1
  check "/run/kibi is root 755 (RuntimeDirectory; the socket itself is 660 root:kibi)" "stat -c '%U %a' /run/kibi | grep -q '^root 755'"
  check "/var/lib/kibi is 710, not world-readable" "test \"\$(stat -c %a /var/lib/kibi)\" = 710"
  check "/var/lib/kibi-daemon (StateDirectory) exists" "test -d /var/lib/kibi-daemon"
  if [ "$sock_free" = 1 ]; then
    check "/var/run/docker.sock links to Kibi's socket" "test \"\$(readlink /var/run/docker.sock)\" = /run/kibi/docker.sock"
  else
    check "/var/run/docker.sock ($(readlink /var/run/docker.sock 2>/dev/null || echo a socket)) left to its owner" "test \"\$(readlink /var/run/docker.sock 2>/dev/null)\" != /run/kibi/docker.sock"
  fi
  if [ "$full" = 1 ]; then
    if [ "$slot_free" = 1 ]; then
      check "/usr/bin/docker is Kibi's (update-alternatives)" "readlink -f /usr/bin/docker | grep -q /usr/libexec/kibi/docker"
      cli=docker
    else
      check "/usr/bin/docker ($(readlink /usr/bin/docker 2>/dev/null || echo a file)) left to its owner" "! readlink -f /usr/bin/docker | grep -q /usr/libexec/kibi/docker"
      cli=/usr/libexec/kibi/docker
    fi
    check "$cli version, no DOCKER_HOST needed" "for i in \$(seq 30); do $cli version >/dev/null 2>&1 && break; sleep 1; done; $cli version --format '{{.Server.Os}}' | grep -q linux"
    # The plugins as laid down; found through the CLI only when nothing else
    # shadows them (a docker in /usr/local/lib/docker/cli-plugins, Docker
    # Desktop's WSL integration for one, is searched first).
    check "compose and buildx plugins run (/usr/libexec/kibi/cli-plugins)" "/usr/libexec/kibi/cli-plugins/docker-compose version | grep -q v5 && /usr/libexec/kibi/cli-plugins/docker-buildx version | grep -q v0.38"
    [ "$slot_free" = 1 ] && check "docker compose and buildx found through the CLI" "$cli compose version | grep -q v5 && $cli buildx version | grep -q v0.38"
  elif [ -n "$clidir" ]; then
    cli="$clidir/docker -H unix:///run/kibi/docker.sock"
    check "docker version through the socket" "for i in \$(seq 30); do $cli version >/dev/null 2>&1 && break; sleep 1; done; $cli version --format '{{.Server.Os}}' | grep -q linux"
  fi
  if [ -n "$cli" ]; then
    check "docker run alpine" "$cli run --rm alpine cat /etc/alpine-release | grep -q '^3\.'"
    if [ "$fail" -gt 0 ]; then
      # Why a container doesn't start: the unit's cgroup tree and the engine's log.
      echo "         cgroup tree of kibi.service:"
      find /sys/fs/cgroup/system.slice/kibi.service -maxdepth 2 -type d 2>&1 | sed 's/^/           /'
      echo "         kibi-init's cgroup: $(cat /proc/$(pgrep -x kibi-init | head -1)/cgroup 2>&1)"
      journalctl -u kibi -n 25 --no-pager 2>&1 | cut -c1-220 | sed 's/^/           /'
    fi
    check "container has internet" "$cli run --rm alpine wget -qO- -T 20 http://example.com | grep -q 'Example Domain'"
    if [ "$sock_free" = 1 ] && [ -n "$clidir" ]; then
      check "docker through /var/run/docker.sock, no context" "$clidir/docker -H unix:///var/run/docker.sock version --format '{{.Server.Os}}' | grep -q linux"
    fi
    # Testcontainers' Ryuk: a container driving the engine through the socket it was given.
    # Kibi's socket, wherever it is: /var/run/docker.sock when Kibi linked it,
    # else /run/kibi/docker.sock (the other socket, Docker Desktop's in WSL
    # for one, is not Kibi). The server must say it's Kibi.
    local ksock=/var/run/docker.sock; [ "$sock_free" = 1 ] || ksock=/run/kibi/docker.sock
    check "container mounts Kibi's socket and reaches Kibi" "$cli run --rm -v $ksock:/var/run/docker.sock docker:cli docker version --format '{{.Server.Platform.Name}} {{.Server.Version}}' | grep -qi kibi"
    check "published port answers" "$cli rm -f kibi-pkg-web >/dev/null 2>&1; $cli run -d --name kibi-pkg-web -p 127.0.0.1:18083:80 nginx:alpine >/dev/null && for i in \$(seq 40); do curl -fs 127.0.0.1:18083 >/dev/null 2>&1 && break; sleep 0.5; done; curl -fs 127.0.0.1:18083 | grep -q 'Welcome to nginx'; r=\$?; $cli rm -f kibi-pkg-web >/dev/null 2>&1; [ \$r -eq 0 ]"
  else
    echo "  [skip] docker run (pass a static docker CLI dir as the 2nd argument)"
  fi
  check "$remove" "$remove"
  check "service stopped, binaries gone, data kept" "! systemctl is-active kibi && test ! -e /usr/bin/kibi && test -d /var/lib/kibi"
  [ "$sock_free" = 1 ] && check "/var/run/docker.sock link gone with the service" "test ! -L /var/run/docker.sock"
  [ "$full" = 1 ] && check "docker alternative withdrawn" "test ! -e /usr/bin/docker || ! readlink -f /usr/bin/docker | grep -q libexec/kibi"
}

host_test kibi-lite 0
[ -n "$(pkgfile kibi)" ] && host_test kibi 1
echo
echo "== $fail failed"
exit $fail
