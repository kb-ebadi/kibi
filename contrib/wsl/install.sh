#!/bin/sh
# Kibi on Windows: run inside a WSL2 distro, as root, from the directory that
# holds the Linux build (cargo xtask windows; x86-64, or arm64 with --arch arm64):
#   wsl -d Ubuntu -u root sh ./install.sh
# Containers run on WSL2's Linux kernel. The daemon serves its unix socket
# only; kibi-win.exe carries the Windows docker CLI's connections to it over
# `kibi bridge` (see ../windows/kibi.ps1). It is not served on TCP: WSL's
# localhost relay drops half-closes, which `docker run` needs.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -m 755 "$here/kibi" "$here/kibi-init" /usr/local/bin/
if [ -d /run/systemd/system ]; then
  cat > /etc/systemd/system/kibi.service <<UNIT
[Unit]
Description=Kibi container engine
After=network-online.target
[Service]
ExecStart=/usr/local/bin/kibi daemon
Environment=HOME=/var/lib/kibi-daemon
Delegate=yes
KillMode=mixed
Restart=on-failure
UMask=0027
[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable kibi
  systemctl restart kibi
else
  # No systemd in this distro: start Kibi when WSL boots it.
  if ! grep -q 'kibi daemon' /etc/wsl.conf 2>/dev/null; then
    printf '\n[boot]\ncommand = HOME=/var/lib/kibi-daemon nohup /usr/local/bin/kibi daemon >/var/log/kibi.log 2>&1 &\n' >> /etc/wsl.conf
  fi
  pkill -f '/usr/local/bin/kibi daemon' 2>/dev/null || true
  HOME=/var/lib/kibi-daemon nohup /usr/local/bin/kibi daemon >/var/log/kibi.log 2>&1 &
fi
echo "Kibi runs in WSL on /var/lib/kibi-daemon/.kibi/run/docker.sock"
