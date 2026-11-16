# Kibi on a Linux host as an RPM: `kibi` (engine + docker CLI, Compose,
# buildx) or `kibi-lite` (engine only), chosen by packaging/linux/build.sh
# through kibi_name and with_cli. Static (musl) binaries: no runtime
# dependencies, no debuginfo. With with_window, `kibi` also carries the
# window (kibi built against GTK 3 and WebKitGTK 4.1), which needs those.
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_mangle_shebangs %{nil}

Name:           %{kibi_name}
Version:        %{kibi_version}
Release:        1%{?dist}
Summary:        Tiny, fast container runtime (Docker API)%{!?with_cli:, engine only}
License:        Apache-2.0
URL:            https://runkibi.kambiz.site
Source0:        kibi
Source1:        kibi-init
Source2:        kibi.service
Source3:        LICENSE
Source4:        NOTICE
Source18:       dev.kibi.host-access.policy
%if 0%{?with_cli}
Source5:        docker
Source6:        docker-compose
Source7:        docker-buildx
Source8:        docker-wrapper
Conflicts:      kibi-lite
%if 0%{?with_window}
Source9:        kibi-window
Source10:       kibi.desktop
Source11:       kibi-app-icon.svg
Source12:       kibi-app-icon-16.png
Source13:       kibi-app-icon-32.png
Source14:       kibi-app-icon-64.png
Source15:       kibi-app-icon-128.png
Source16:       kibi-app-icon-256.png
Source17:       kibi-app-icon-512.png
Source19:       dev.kibi.Kibi.metainfo.xml
Requires:       gtk3
Requires:       webkit2gtk4.1
# The window's setup checklist asks for the password through pkexec.
Recommends:     polkit
%endif
%else
Conflicts:      kibi
%endif
BuildArch:      %{kibi_arch}
# Static binaries: nothing to find by scanning them.
AutoReq:        no
Requires(pre):  shadow-utils
%if 0%{?with_cli}
Requires(post): %{_sbindir}/update-alternatives
Requires(preun): %{_sbindir}/update-alternatives
Requires(posttrans): %{_sbindir}/update-alternatives
%endif

%description
Kibi runs containers on this machine's kernel and speaks the Docker API on
/run/kibi/docker.sock for users in the kibi group (and at
/var/run/docker.sock while no Docker engine has it). No VM, no daemon other
than kibi itself. Members of the kibi group can run containers as root on
this machine; treat it like the docker group.
%if 0%{?with_cli}
This package brings the docker CLI, Compose and buildx with it, as Kibi.app
does on the Mac: `docker run` works right after installing. A docker CLI from
another package keeps precedence on PATH.
%if 0%{?with_window}
Kibi's window is in the app menu, or: kibi ui
%endif
%else
Engine only: point any docker CLI at it with
  docker context create kibi --docker host=unix:///run/kibi/docker.sock
%endif

%prep

%build

%install
install -D -m 755 %{SOURCE0} %{buildroot}%{_bindir}/kibi
install -D -m 755 %{SOURCE1} %{buildroot}%{_bindir}/kibi-init
install -D -m 644 %{SOURCE2} %{buildroot}%{_unitdir}/kibi.service
install -D -m 644 %{SOURCE3} %{buildroot}%{_licensedir}/%{name}/LICENSE
install -D -m 644 %{SOURCE4} %{buildroot}%{_licensedir}/%{name}/NOTICE
install -D -m 644 %{SOURCE18} %{buildroot}%{_datadir}/polkit-1/actions/dev.kibi.host-access.policy
%if 0%{?with_cli}
install -D -m 755 %{SOURCE5} %{buildroot}/usr/libexec/kibi/bin/docker
install -D -m 755 %{SOURCE8} %{buildroot}/usr/libexec/kibi/docker
install -D -m 755 %{SOURCE6} %{buildroot}/usr/libexec/kibi/cli-plugins/docker-compose
install -D -m 755 %{SOURCE7} %{buildroot}/usr/libexec/kibi/cli-plugins/docker-buildx
%endif
%if 0%{?with_window}
install -D -m 755 %{SOURCE9} %{buildroot}/usr/lib/kibi/kibi-window
install -D -m 644 %{SOURCE10} %{buildroot}%{_datadir}/applications/kibi.desktop
install -D -m 644 %{SOURCE19} %{buildroot}%{_datadir}/metainfo/dev.kibi.Kibi.metainfo.xml
install -D -m 644 %{SOURCE11} %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/kibi.svg
for s in 16 32 64 128 256 512; do
  install -D -m 644 %{_sourcedir}/kibi-app-icon-$s.png %{buildroot}%{_datadir}/icons/hicolor/${s}x${s}/apps/kibi.png
done
%endif

%pre
getent group kibi >/dev/null || groupadd --system kibi
exit 0

%post
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || :
  # Not started or enabled: it starts when someone sets Kibi up (the window's
  # Allow access, or `kibi host-access`). An upgrade ($1 >= 2) restarts a
  # running engine on the new binary, as the Mac and Windows apps do after
  # an update; its containers stop, and those with a restart policy start again.
  if [ "$1" -ge 2 ] && systemctl is-active -q kibi.service; then
    echo "Kibi is upgraded: restarting the engine on the new version."
    systemctl try-restart kibi.service || echo "  The engine didn't restart: sudo systemctl restart kibi"
  fi
fi
# A `kibi` before /usr/bin on PATH runs instead of this package's.
for d in /usr/local/sbin /usr/local/bin; do
  if [ -e "$d/kibi" ] && [ "$(readlink -f "$d/kibi")" != /usr/bin/kibi ]; then
    echo "Warning: $d/kibi comes before /usr/bin/kibi on PATH, so it runs instead of this Kibi."
    echo "  If it's an older Kibi, remove it:  sudo rm $d/kibi"
  fi
done
%if 0%{?with_cli}
# Only a /usr/bin/docker that is absent or already an alternatives link; a
# real file, or a symlink another package or the administrator put there, is
# left alone: Kibi's CLI must not take over someone else's docker.
free=1
if [ -e /usr/bin/docker ] || [ -L /usr/bin/docker ]; then
  case "$(readlink /usr/bin/docker 2>/dev/null)" in /etc/alternatives/*) ;; *) free=0 ;; esac
fi
if [ "$free" = 1 ]; then
  %{_sbindir}/update-alternatives --install /usr/bin/docker docker /usr/libexec/kibi/docker 10 || :
  echo "Kibi is installed with its own docker CLI (docker, docker compose, docker buildx)."
else
  echo "Kibi is installed; /usr/bin/docker belongs to something else and stays. Kibi's CLI: /usr/libexec/kibi/docker"
fi
%else
echo "Kibi is installed (engine only). Point a docker CLI at it:"
echo "  docker context create kibi --docker host=unix:///run/kibi/docker.sock && docker context use kibi"
%endif
echo "To use it without sudo:  sudo kibi host-access \$USER   (or open Kibi, which sets it up)"
echo "Members of the kibi group can run containers as root on this machine; treat it like the docker group."
echo "While no Docker engine has /var/run/docker.sock, it leads to Kibi too (for Testcontainers, docker-py and other tools that ignore docker contexts)."
exit 0

%preun
if [ "$1" -eq 0 ]; then
  if [ -d /run/systemd/system ]; then
    systemctl disable --now kibi.service >/dev/null 2>&1 || :
  fi
  # Everything else it runs: a window or kibi command still open.
  for sig in TERM KILL; do
    pkill -$sig -f '^/usr/lib/kibi/kibi-window( |$)' >/dev/null 2>&1 || :
    pkill -$sig -f '^(/usr)?/bin/kibi( |$)' >/dev/null 2>&1 || :
    [ "$sig" = KILL ] || sleep 1
  done
%if 0%{?with_cli}
  %{_sbindir}/update-alternatives --remove docker /usr/libexec/kibi/docker || :
  for p in docker-compose docker-buildx; do
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/kibi/cli-plugins/$p || :
  done
%endif
fi
exit 0

%if 0%{?with_cli}
%posttrans
# Compose and buildx into /usr/lib/docker/cli-plugins where the slot is free
# and Docker's own copy isn't in another of the CLI's plugin folders; else
# Kibi's link goes and Docker's copy is used. In %posttrans because an
# upgrade from a Kibi that put real files there erases them only after %post;
# again whenever another package changes Docker's plugin folders.
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/kibi/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/kibi/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/kibi/cli-plugins/$p || :
  fi
done
exit 0

%filetriggerin -- /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/kibi/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/kibi/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/kibi/cli-plugins/$p || :
  fi
done
exit 0

%filetriggerpostun -- /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
mkdir -p /usr/lib/docker/cli-plugins
for p in docker-compose docker-buildx; do
  l=/usr/lib/docker/cli-plugins/$p
  theirs=
  for d in /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
    [ -e $d/$p ] && theirs=1
  done
  if [ -z "$theirs" ] && { [ ! -e $l ] && [ ! -L $l ] || readlink $l 2>/dev/null | grep -q '^/etc/alternatives/'; }; then
    %{_sbindir}/update-alternatives --install $l $p /usr/libexec/kibi/cli-plugins/$p 10 || :
  elif %{_sbindir}/update-alternatives --display $p 2>/dev/null | grep -q "^/usr/libexec/kibi/cli-plugins/$p "; then
    %{_sbindir}/update-alternatives --remove $p /usr/libexec/kibi/cli-plugins/$p || :
  fi
done
exit 0
%endif

%postun
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload >/dev/null 2>&1 || :
fi
if [ "$1" -eq 0 ]; then
  echo "Kibi is removed; its images, containers and volumes stay in /var/lib/kibi"
fi
exit 0

%files
%license %{_licensedir}/%{name}/LICENSE
%license %{_licensedir}/%{name}/NOTICE
%{_bindir}/kibi
%{_bindir}/kibi-init
%{_unitdir}/kibi.service
%{_datadir}/polkit-1/actions/dev.kibi.host-access.policy
%if 0%{?with_cli}
%dir /usr/libexec/kibi
%dir /usr/libexec/kibi/bin
/usr/libexec/kibi/bin/docker
/usr/libexec/kibi/docker
%dir /usr/libexec/kibi/cli-plugins
/usr/libexec/kibi/cli-plugins/docker-compose
/usr/libexec/kibi/cli-plugins/docker-buildx
%endif
%if 0%{?with_window}
%dir /usr/lib/kibi
/usr/lib/kibi/kibi-window
%{_datadir}/applications/kibi.desktop
%{_datadir}/icons/hicolor/*/apps/kibi.*
%{_datadir}/metainfo/dev.kibi.Kibi.metainfo.xml
%endif

%changelog
* Sun Oct 25 2026 Kibi <kibi@canestack.com> - %{kibi_version}-1
- Packaged from the static Linux build
