#!/usr/bin/env bash
# Run a VM like run-vphone.sh does, but inside a bubblewrap (bwrap) sandbox, so a guest that
# escapes QEMU (or reims-vgpu) does not get the user's account:
#
#   tools/vphone-sandbox.sh VM_DIR [qemu args...]     # the same arguments as run-vphone.sh
#   tools/vphone-sandbox.sh VM_DIR -- CMD [ARGS...]   # run CMD in the same sandbox (checks)
#
# setup/start-vm.sh and setup/create-vm.sh start VMs through this script; VPHONE_SANDBOX=0 makes
# them use run-vphone.sh directly.
#
# The network (VPHONE_SANDBOX_NET):
#   internet (default)  the sandbox gets its own network namespace with an outbound link from
#                       slirp4netns --disable-host-loopback. The guest reaches the internet and
#                       whatever the host reaches (LAN, VPN/tailnet, the host's non-loopback
#                       addresses), but not the host's 127.0.0.1 and not abstract Unix sockets
#                       (the X server's, D-Bus's...).
#   none                no outbound link: the guest reaches nothing but the forwarded ports.
# VPHONE_SANDBOX_FORWARD (default 8081, Metro; space- or comma-separated; empty for none): host
# loopback ports the guest reaches at 10.0.2.2:PORT, through a Unix socket per port (socat on
# both sides). Nothing else on the host's loopback is reachable.
#
# Inside the sandbox:
#   - $HOME is an empty folder ($VPHONE_SANDBOX_HOME, default ~/.local/state/vphone-sandbox):
#     no ~/.ssh, tokens or keys. Window screenshots land in its Pictures/vphone/;
#   - /run and /tmp are private: no Docker socket, D-Bus, ssh-agent or other host sockets;
#   - the environment is cleared, then only run-vphone.sh's own settings are passed on;
#   - the checkout is read-only; only VM_DIR is writable.
# What stays: the GPU device nodes (and so the GPU kernel driver), /dev/vhost-vsock, and with
# WINDOW=1 the display. On Wayland only the Wayland socket is shared. On X11 the X server is
# shared, and any X11 client can read keystrokes and type into other windows: prefer WINDOW=0
# or a Wayland session where that matters.
#
# The vsock device is not tied to a network namespace (Linux 6.12), so the host tools
# (tools/vphoned.sh, tools/install-ipa.py) still reach vphoned from outside the sandbox.
# VM_DIR keeps its path inside, so start-vm.sh still finds the VM's QEMU by its Disk.img path.
# A QMP or other Unix socket that host tools use must be inside VM_DIR: the rest of the
# sandbox's file system is not visible from the host.
#
# This script stays as the sandbox's parent: it ends the helpers (slirp4netns, socat) when the
# VM ends, and passes SIGINT/SIGTERM/SIGHUP on to QEMU as SIGTERM. If it is killed (SIGKILL),
# the helpers end with it but the VM keeps running, without network: a killed QEMU can leave
# the guest's disk damaged. Shut the guest down (start-vm.sh --stop) or close its window.
#
# Needs bubblewrap; with forwards socat; with VPHONE_SANDBOX_NET=internet also slirp4netns and
# unprivileged user namespaces (Ubuntu's AppArmor can restrict them).
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE=${VPHONE_SANDBOX_HOME:-$HOME/.local/state/vphone-sandbox}
NET=${VPHONE_SANDBOX_NET:-internet}
FORWARD=${VPHONE_SANDBOX_FORWARD-8081}
SLIRP_CIDR=10.0.3.0/24        # the sandbox's own link; its DNS forwarder is .3
VM=${1:?usage: vphone-sandbox.sh VM_DIR [qemu args...] | VM_DIR -- CMD [ARGS...]}
shift
case $VM in /*) ;; *) VM=$PWD/$VM ;; esac
die() { echo "vphone-sandbox.sh: $*" >&2; exit 1; }
[ -d "$VM" ] || die "no VM directory at $VM"
command -v bwrap >/dev/null || die "bwrap is missing (install bubblewrap), or set VPHONE_SANDBOX=0"
# Both need the host's network namespace or /tmp, which the sandbox does not share.
[ -z "${GDB:-}" ] || die "GDB= needs the host network for its stub: use VPHONE_SANDBOX=0"
[ "${VSOCK:-vhost}" = vhost ] || die "VSOCK=$VSOCK puts its socket in the sandbox's private /tmp: use VSOCK=vhost or VPHONE_SANDBOX=0"
case $NET in
  none) ;;
  internet)
    for tool in unshare slirp4netns setpriv ip; do
      command -v "$tool" >/dev/null ||
        die "VPHONE_SANDBOX_NET=internet needs $tool (install slirp4netns/util-linux/iproute2), or set VPHONE_SANDBOX_NET=none"
    done ;;
  *) die "VPHONE_SANDBOX_NET must be internet or none, not '$NET'" ;;
esac
read -ra ports <<< "${FORWARD//,/ }"
for p in "${ports[@]}"; do
  [[ $p =~ ^[0-9]{1,5}$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] ||
    die "VPHONE_SANDBOX_FORWARD: '$p' is not a port number"
done
if [ "${#ports[@]}" -gt 0 ]; then
  command -v socat >/dev/null || die "VPHONE_SANDBOX_FORWARD needs socat (install it), or set VPHONE_SANDBOX_FORWARD="
  command -v setpriv >/dev/null || die "VPHONE_SANDBOX_FORWARD needs setpriv (util-linux)"
fi
mkdir -p "$STATE"

# Private files for this run: the forward sockets and the sandbox's resolv.conf.
RUN=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/vphone-sandbox.XXXXXX")
helpers=()
cleanup() {
  if [ "${#helpers[@]}" -gt 0 ]; then kill "${helpers[@]}" 2>/dev/null || true; fi
  rm -rf -- "$RUN"
}
trap cleanup EXIT

args=(--unshare-all)
# internet: keep the namespace made below for slirp4netns (bwrap cannot share its own with it).
[ "$NET" = none ] || args+=(--share-net)
args+=(
  --new-session --clearenv
  --ro-bind /usr /usr --ro-bind /etc /etc
  --symlink usr/bin /bin --symlink usr/sbin /sbin
  --symlink usr/lib /lib --symlink usr/lib64 /lib64
  --proc /proc --ro-bind /sys /sys
  --dev /dev --tmpfs /dev/shm
  --tmpfs /tmp --tmpfs /run
  --ro-bind "$RUN" /run/vphone-sandbox
  --bind "$STATE" "$HOME"
  --ro-bind "$REPO" "$REPO"
  --bind "$VM" "$VM"
  --setenv HOME "$HOME" --setenv PATH /usr/bin:/usr/sbin
  --setenv XDG_RUNTIME_DIR /tmp --setenv TERM "${TERM:-xterm}"
  --chdir "$HOME"
)

# DNS: the host's resolver may sit on the host's loopback (systemd-resolved's 127.0.0.53),
# which the sandbox cannot reach; slirp4netns forwards DNS on its own link instead.
if [ "$NET" = internet ]; then
  printf 'nameserver %s.3\n' "${SLIRP_CIDR%.*}" > "$RUN/resolv.conf"
  resolv=$(readlink -f /etc/resolv.conf)
  case $resolv in
    /run/*|/tmp/*) args+=(--ro-bind "$RUN/resolv.conf" "$resolv") ;;   # a link into /run: bind its target
    *) if [ -e "$resolv" ]; then args+=(--ro-bind "$RUN/resolv.conf" "$resolv"); fi ;;
  esac
fi

# The GPU (NVIDIA's nodes, or DRM render nodes and udmabuf for other vendors) and vsock.
for dev in /dev/nvidia[0-9]* /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm /dev/dri \
           /dev/udmabuf /dev/vhost-vsock; do
  [ -e "$dev" ] && args+=(--dev-bind "$dev" "$dev")
done

# The display, only when run-vphone.sh opens a window.
if [ "${WINDOW:-0}" = 1 ]; then
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case $WAYLAND_DISPLAY in /*) wl=$WAYLAND_DISPLAY ;; *) wl=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY ;; esac
    [ -S "$wl" ] || die "no Wayland socket at $wl"
    args+=(--ro-bind "$wl" /tmp/wayland-0 --setenv WAYLAND_DISPLAY wayland-0)
  elif [ -n "${DISPLAY:-}" ]; then
    n=${DISPLAY#*:}; n=${n%%.*}
    x11=/tmp/.X11-unix/X$n
    [ -S "$x11" ] || die "no local X11 socket at $x11 (DISPLAY=$DISPLAY)"
    args+=(--ro-bind "$x11" "$x11" --setenv DISPLAY "$DISPLAY")
    xauth=${XAUTHORITY:-$HOME/.Xauthority}
    if [ -r "$xauth" ]; then args+=(--ro-bind "$xauth" /tmp/.Xauthority --setenv XAUTHORITY /tmp/.Xauthority); fi
  else
    die "WINDOW=1 but neither WAYLAND_DISPLAY nor DISPLAY is set"
  fi
fi

# run-vphone.sh's own settings; nothing else from the caller's environment.
while IFS= read -r name; do
  case $name in
    GFX|WINDOW|TOOLBAR|CID|MEM|SMP|GFX_PPI|DFLAGS|TRACE|QEMU|QEMU_*|VPHONE_*|REIMS_VGPU_*|M2V_*|LP_*|VK_*)
      args+=(--setenv "$name" "${!name}") ;;
  esac
done < <(compgen -e)

# What runs in the sandbox: run-vphone.sh (or the given command), behind the in-sandbox ends of
# the forwards. QEMU's user-mode network sends the guest's 10.0.2.2 to the sandbox's 127.0.0.1.
if [ "${1:-}" = -- ]; then shift; cmd=("$@"); else cmd=("$REPO/run-vphone.sh" "$VM" "$@"); fi
if [ "${#ports[@]}" -gt 0 ]; then
  # The listeners end with the process that started them, which `exec` turns into QEMU:
  # otherwise they would keep bwrap's pid 1, and so the sandbox, alive after QEMU.
  # shellcheck disable=SC2016  # expanded by the sandbox's shell
  cmd=(bash -c 'for p in $1; do
      setpriv --pdeathsig TERM -- socat "TCP-LISTEN:$p,bind=127.0.0.1,fork,reuseaddr" \
        "UNIX-CONNECT:/run/vphone-sandbox/fwd-$p.sock" &
    done
    shift; exec "$@"' vphone-sandbox-forward "${ports[*]}" "${cmd[@]}")
  # The host ends: each socket -> the host's 127.0.0.1:PORT. They die with this script.
  for p in "${ports[@]}"; do
    setpriv --pdeathsig TERM -- socat "UNIX-LISTEN:$RUN/fwd-$p.sock,fork,umask=077" "TCP:127.0.0.1:$p" &
    helpers+=("$!")
  done
fi

if [ "$NET" = internet ]; then
  # A user + network namespace that slirp4netns can join; bwrap starts inside it once the link
  # is up (a missing link stops here, so the VM never runs on a half-made network).
  # shellcheck disable=SC2016  # expanded by the namespace's shell
  unshare --user --map-current-user --net -- bash -c '
    for _ in $(seq 100); do ip route show default 2>/dev/null | grep -q . && break; sleep 0.1; done
    ip route show default 2>/dev/null | grep -q . ||
      { echo "vphone-sandbox.sh: the slirp4netns link did not come up" >&2; exit 1; }
    exec bwrap "$@"' vphone-sandbox-net "${args[@]}" "${cmd[@]}" <&0 &
  sandbox=$!
  for _ in $(seq 100); do
    [ "$(readlink "/proc/$sandbox/ns/net" 2>/dev/null)" != "$(readlink /proc/$$/ns/net)" ] && break
    sleep 0.05
  done
  setpriv --pdeathsig TERM -- slirp4netns --configure --mtu=65520 --cidr="$SLIRP_CIDR" \
    --disable-host-loopback --userns-path="/proc/$sandbox/ns/user" "$sandbox" tap0 >/dev/null &
  helpers+=("$!")
else
  bwrap "${args[@]}" "${cmd[@]}" <&0 &
  sandbox=$!
fi

# SIGINT/SIGTERM/SIGHUP: stop QEMU (bwrap's pid 1 in the sandbox runs it) with SIGTERM, as a
# Ctrl+C on run-vphone.sh does, then wait for the sandbox to end.
stop_sandbox() {
  local init
  if init=$(pgrep -P "$sandbox" | head -1) && [ -n "$init" ]; then
    pkill -TERM -P "$init" 2>/dev/null || true
  else
    kill -TERM "$sandbox" 2>/dev/null || true
  fi
}
trap stop_sandbox INT TERM HUP
status=0
while :; do
  wait "$sandbox" && status=0 || status=$?
  kill -0 "$sandbox" 2>/dev/null || break
done
exit "$status"
