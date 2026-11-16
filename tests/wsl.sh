#!/bin/bash
# Kibi for Windows, without Windows: copies target/kibi-windows-x86_64 (what
# `cargo xtask windows` makes) into an x86-64 Ubuntu container standing in
# for the WSL2 distro, runs its install.sh as a Windows user would, then
# drives the engine from a second container with only the docker CLI,
# standing in for Windows. The daemon serves only its unix socket (on
# Windows, kibi-win.exe reaches it through `kibi bridge`), so the second
# container shares the socket's directory. On Apple Silicon use aarch64:
# Rosetta runs the x86-64 build but has no clone3, which every container
# start needs (WSL2's kernel has it). What this cannot cover: WSL2's own
# kernel, and kibi-win.exe's relay. Usage: tests/wsl.sh [x86_64|aarch64]
set -u
D=${D:-docker}
ARCH=${1:-x86_64}
case $ARCH in x86_64) PLATFORM=linux/amd64 ;; aarch64) PLATFORM=linux/arm64 ;; *) echo "usage: $0 [x86_64|aarch64]"; exit 2 ;; esac
DIR=$(cd "$(dirname "$0")/.." && pwd)/target/kibi-windows-$ARCH
[ -x "$DIR/kibi" ] || { echo "build first: cargo xtask windows (--arch arm64 for aarch64)"; exit 1; }
SOCK=/var/lib/kibi-daemon/.kibi/run
$D rm -f kibi-wsl kibi-wsl-cli >/dev/null 2>&1
$D volume rm kibi-wsl-run kibi-wsl-lib kibi-wsl-store >/dev/null 2>&1
# WSL's disk is ext4; this container's own root is overlayfs, which can't be
# an overlay's upper layer, so Kibi's state goes on volumes, as in
# linux-host.sh.
$D run -d --name kibi-wsl --platform $PLATFORM --privileged --tmpfs /run -v kibi-wsl-run:$SOCK \
  -v kibi-wsl-lib:/var/lib/kibi -v kibi-wsl-store:/var/lib/kibi-daemon/.local/share/kibi ubuntu:24.04 sleep infinity >/dev/null
$D exec kibi-wsl mkdir -p /tmp/kibi-windows
$D cp "$DIR/kibi" kibi-wsl:/tmp/kibi-windows/kibi >/dev/null
$D cp "$DIR/kibi-init" kibi-wsl:/tmp/kibi-windows/kibi-init >/dev/null
$D cp "$DIR/install.sh" kibi-wsl:/tmp/kibi-windows/install.sh >/dev/null
$D exec kibi-wsl sh -c 'cd /tmp/kibi-windows && sh ./install.sh'
$D run -d --name kibi-wsl-cli --network container:kibi-wsl -v kibi-wsl-run:/kibi alpine sh -c 'apk add -q docker-cli curl >/dev/null 2>&1; sleep infinity' >/dev/null
for _ in $(seq 90); do $D exec kibi-wsl-cli docker -H unix:///kibi/docker.sock version >/dev/null 2>&1 && break; sleep 1; done
PASS=0; FAIL=0
t() {
  local name=$1 want=$2; shift 2
  local got; got=$($D exec kibi-wsl-cli sh -c "export DOCKER_HOST=unix:///kibi/docker.sock; $*" 2>&1 | tr -d '\r')
  if [[ "$got" == *"$want"* ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf '  FAIL %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$(echo "$got" | head -3)"; fi
}
# No systemd here, so install.sh must have added the WSL boot command.
if $D exec kibi-wsl grep -q '/usr/local/bin/kibi daemon' /etc/wsl.conf; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL boot-entry: no kibi line in /etc/wsl.conf"; fi
t arch "$ARCH" "docker version --format '{{.Server.Arch}}' | sed 's/amd64/x86_64/; s/arm64/aarch64/'"
t hello "Hello from Docker!" "docker run --rm hello-world"
t run "3." "docker run --rm alpine cat /etc/alpine-release"
t internet "Example Domain" "docker run --rm alpine wget -qO- -T 10 http://example.com"
t port "Welcome to nginx" "docker run -d --name web -p 18082:80 nginx:alpine >/dev/null; for i in \$(seq 40); do curl -s localhost:18082 && break; sleep 0.5; done"
t exec "nginx version" "docker exec web nginx -v"
t port-inspect '{"80/tcp":[{"HostIp":"","HostPort":"18082"}]}' "docker inspect -f '{{json .HostConfig.PortBindings}}' web"
# What the registry serves now, for update checkers (#257).
t distribution '"mediaType":"application/vnd.oci.image.index.v1+json"' "curl -s --unix-socket /kibi/docker.sock http://d/v1.47/distribution/library/alpine:3.21/json"
t distribution-missing "404" "curl -s -o /dev/null -w '%{http_code}' --unix-socket /kibi/docker.sock http://d/v1.47/distribution/library/no-such-image-kibi-test/json"
# A copy into a created container, then its start, mounts the same upper
# dir twice in a row: kernels with overlayfs index on (Arch) refused the
# second with EBUSY (#227). A renamed directory must survive a commit.
t cp-then-start "failed 0" "f=0; for i in 1 2 3 4 5; do id=\$(docker create alpine sleep 30); docker cp /etc/hostname \$id:/f >/dev/null 2>&1 || f=\$((f+1)); docker start \$id >/dev/null 2>&1 || f=\$((f+1)); docker rm -f \$id >/dev/null; done; echo failed \$f"
t commit-renamed-dir "kept" "docker rm -f kibi-rename >/dev/null 2>&1; docker run --name kibi-rename alpine mv /etc/apk /etc/apk2; docker commit kibi-rename kibi-rename-test >/dev/null; docker rm -f kibi-rename >/dev/null; docker run --rm kibi-rename-test sh -c 'test -f /etc/apk2/repositories && echo kept'; docker rmi kibi-rename-test >/dev/null"
# A start that fails once its network is up leaves no name behind (#325).
t failed-start-no-dns "none" "docker network create kibi-dnsfail >/dev/null 2>&1; docker rm -f kibi-dnsbad >/dev/null 2>&1; docker run -d --name kibi-dnsbad --network kibi-dnsfail --sysctl net.ipv4.kibi_no_such_key=1 alpine sleep 60 >/dev/null 2>&1; docker run --rm --network kibi-dnsfail alpine sh -c 'nslookup kibi-dnsbad 2>&1 | grep -qE \"^Address: [0-9.]+\$\" && echo answered || echo none'; docker rm -f kibi-dnsbad >/dev/null 2>&1; docker network rm kibi-dnsfail >/dev/null"
t network-dns "PONG" "docker network create wn >/dev/null 2>&1; docker run -d --name db --network wn redis:7-alpine >/dev/null; sleep 2; docker run --rm --network wn redis:7-alpine redis-cli -h db ping"
t volume "kept" "docker run --rm -v wv:/d alpine sh -c 'echo kept > /d/f' && docker run --rm -v wv:/d alpine cat /d/f"
t seccomp "Seccomp:	2" "docker run --rm alpine grep Seccomp: /proc/self/status"
t cleanup "web" "docker rm -f web db"
# The agent (kibi-init under the daemon) dies with nobody asking (#50):
# `always` and `unless-stopped` come back by themselves; no policy, or a
# `docker stop`, stays down.
t crash-setup "ok" "for p in always unless-stopped no; do docker run -d --name cr-\$p --restart \$p alpine sleep 1d >/dev/null; done; docker run -d --name cr-user --restart always alpine sleep 1d >/dev/null; docker stop -t 0 cr-user >/dev/null && echo ok"
if $D exec kibi-wsl sh -c 'kill -9 $(pgrep -x -P "$(pgrep -xo kibi)" kibi-init)'; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL crash-kill: no agent to kill"; fi
t crash-recovers "cr-always=true cr-unless-stopped=true cr-no=false cr-user=false" "sleep 4; for c in cr-always cr-unless-stopped cr-no cr-user; do printf '%s=%s ' \$c \$(docker inspect -f '{{.State.Running}}' \$c); done"
t crash-cleanup "cr-always" "docker rm -f cr-always cr-unless-stopped cr-no cr-user"
$D rm -f kibi-wsl kibi-wsl-cli >/dev/null
$D volume rm kibi-wsl-run kibi-wsl-lib kibi-wsl-store >/dev/null 2>&1
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
