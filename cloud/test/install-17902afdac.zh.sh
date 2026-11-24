#!/bin/sh
# Installs the still.fail station on this machine and joins it to a workspace in still.fail cloud:
#   curl -fsSL $STILLFAIL_ORIGIN/install.sh | sh -s -- <token> [<lock>] [rig:<person>]
# <lock>: the workspace lock's hash the station pins (a locked workspace's command gives it).
# rig:<person>: the machine joins as a rig (a station that only runs tasks), its person's own lock's hash pinned (a rig's command gives it).
# STILLFAIL_CHANNEL=beta gets the test channel's release (stable: the usual one); this copy defaults to stable.
# The token comes from 「添加 station」 in still.fail. Running it again updates it and keeps its data (~/.stillfail).
set -eu
origin="${STILLFAIL_ORIGIN:?}"
token="${1:-}"
lock="${2:-}"
rig="${3:-}"
case "$lock" in rig:*) rig="$lock" lock="" ;; esac
# The product its cloud is (client/i18n/brand.ts): another product's station has a data directory, a command and a
# service of its own beside still.fail's on the same machine (monoid's: ~/.monoid, `monoid`, build.monoid.station).
product=stillfail reverse=fail.still
case "$origin" in
  *://monoid.build|*://monoid.build:*|*://*.monoid.build|*://*.monoid.build:*|*://monoid.zone|*://monoid.zone:*|*://*.monoid.zone|*://*.monoid.zone:*) product=monoid reverse=build.monoid ;;
esac
# The data: $STILLFAIL_DATA, else ~/.stillfail.
data="${STILLFAIL_DATA:-$HOME/.$product}"
cur="$data"
# Where the update is, for the station to show on its pages: download, handoff, drain,
# restart. Only for a station that is there to read it.
step() { [ -d "$cur/run" ] && printf '%s
' "$1" > "$cur/run/update.step" 2>/dev/null || true; }
# A station already in a workspace is only updated: no token, and it stays the same station.
if [ -z "$token" ] && [ ! -f "$cur/mesh/cloud.json" ]; then
  echo "用法：curl -fsSL $origin/install.sh | sh -s -- <token>（token 在 still.fail 的「添加 station」中生成）" >&2
  echo "已加入 workspace 的 station 更新时无需 token：stillfail update" >&2
  exit 2
fi
os=$(uname -s)
case "$os-$(uname -m)" in
  Darwin-arm64) platform=darwin-arm64 ;;
  Linux-x86_64) platform=linux-x64 ;;
  Linux-aarch64|Linux-arm64) platform=linux-arm64 ;;
  *) echo "目前仅支持 macOS（Apple 芯片）、Linux（x64、arm64）和 Windows（x64），此机器为 $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
# Windows' Linux (WSL): its PATH carries Windows' own directories (/mnt/c/…), whose programs are not the agents'; its
# systemd is off unless /etc/wsl.conf turns it on; and it runs only while Windows keeps it up (keep_wsl).
wsl=""
[ "$os" = Linux ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && wsl=yes
app="$data/app"
label="$reverse.station"
plist="$HOME/Library/LaunchAgents/$label.plist"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
unit="$product-station.service"
# Whether this Linux has a systemd for the user to run services in (not a container's, not another init).
user_systemd() { command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
# Every directory the install writes in is checked before anything is downloaded or joined: one a sudo made root's
# (~/.config after a `sudo` command made it, mkdir's "Permission denied" at the service once the machine had joined,
# 2026-11-17) stops it here with the command that gives it back. Not run as root instead: the station is the user's,
# its service a user service, and the agents run as the user.
unwritable=""
writable() {
  w_dir=$1
  while [ ! -e "$w_dir" ]; do w_dir=$(dirname "$w_dir"); done
  [ -d "$w_dir" ] && [ -w "$w_dir" ] || unwritable="$w_dir"
}
writable "$data"
writable "$HOME/.local/bin"
if [ "$os" = Darwin ]; then writable "$(dirname "$plist")"; elif user_systemd; then writable "$unit_dir"; fi
if [ -n "$unwritable" ]; then
  owner=$(ls -ld "$unwritable" | awk '{print $3}')
  me=$(id -un)
  echo "无法写入 ${unwritable}：它属于 ${owner}（多半是之前某条 sudo 命令创建的）。station 以 ${me} 身份运行、装在 ${me} 的目录里，不能用 sudo 或 root 安装：先执行 sudo chown -R ${me} ${unwritable} && chmod u+rwx ${unwritable}，再重新运行安装命令" >&2
  exit 1
fi
# WSL keeps a distribution up only while something of Windows' holds it (a terminal, a wsl.exe): with none, its
# services stop with it, and it does not start with Windows. So a wsl.exe that holds it, hidden, started at each
# Windows sign-in from the user's Startup folder ($keeper, a script for wscript) and now. Through WSL's interop
# (cmd.exe, wscript.exe on its PATH): none from a station's own update (no terminal of Windows' there; done before).
keeper_sleep=3153600000
keep_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] && command -v wslpath >/dev/null 2>&1 && command -v cmd.exe >/dev/null 2>&1 || return 1
  appdata=$(cd / && cmd.exe /c "echo %APPDATA%" 2>/dev/null | tr -d '\r')
  case "$appdata" in ?:\\*) ;; *) return 1 ;; esac
  startup="$(wslpath -u "$appdata")/Microsoft/Windows/Start Menu/Programs/Startup"
  [ -d "$startup" ] || return 1
  keeper="$startup/$product-station-$WSL_DISTRO_NAME.vbs"
  keeper_win=$(wslpath -w "$keeper")
  printf 'CreateObject("WScript.Shell").Run "wsl.exe -d ""%s"" --exec sleep %s", 0, False\r\n' "$WSL_DISTRO_NAME" "$keeper_sleep" > "$keeper" || return 1
  pgrep -fx "sleep $keeper_sleep" >/dev/null 2>&1 || (cd / && cmd.exe /c wscript.exe "$keeper_win" >/dev/null 2>&1) || return 1
}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

channel="${STILLFAIL_CHANNEL:-stable}"
# (Said once: not again by the release's own installer, handed the download below.)
case "$channel" in
  beta) release="beta/stillfail-station-$platform.tar.gz"; [ -n "${STILLFAIL_INSTALLER_HANDED:-}" ] || echo "下载 still.fail station（测试版）…" ;;
  *) channel=stable; release="stillfail-station-$platform.tar.gz"; [ -n "${STILLFAIL_INSTALLER_HANDED:-}" ] || echo "下载 still.fail station…" ;;
esac
step download
# Downloads $1 to $2 (curl given the rest before them: how it shows its progress), tried again after each of
# STILLFAIL_DOWNLOAD_PAUSES (seconds; a test's 0 0 0) where it failed on the way: no connection, one broken (macOS's
# LibreSSL curl's exit 35, SSL_ERROR_SYSCALL, main 0a099ace's station-update 43880021498, 2026-11-16, which curl's own
# --retry does not take), a deadline, a gateway's 502, 503 or 504. A refusal (404, 403, 500) is the same when asked again.
download() {
  dl_url=$1 dl_out=$2
  shift 2
  for dl_pause in ${STILLFAIL_DOWNLOAD_PAUSES-1 2 4} last; do
    if dl_code=$(curl "$@" -w '%{http_code}' "$dl_url" -o "$dl_out"); then return 0; else dl_status=$?; fi
    rm -f "$dl_out"
    case "$dl_status:$dl_code" in
      22:502|22:503|22:504|5:*|6:*|7:*|16:*|18:*|28:*|35:*|52:*|55:*|56:*|92:*) ;;
      *) return "$dl_status" ;;
    esac
    [ "$dl_pause" != last ] || return "$dl_status"
    echo "下载中断，${dl_pause} 秒后重试…" >&2
    sleep "$dl_pause"
  done
}
sha256_of() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | cut -d' ' -f1; }
# Handed a release already downloaded (by the installer of the release before, below, or by the station, which made it
# from a delta: station/src/updates/release.ts): taken, its directory removed.
case "${STILLFAIL_ARCHIVE:-}" in
  */stillfail-handed.*/stillfail.tar.gz)
    mv "$STILLFAIL_ARCHIVE" "$tmp/stillfail.tar.gz"
    rm -rf "$(dirname "$STILLFAIL_ARCHIVE")" ;;
  *) download "$origin/releases/$release" "$tmp/stillfail.tar.gz" -fL --progress-bar ;;
esac
# A station updating itself says what the release must hash to, as its signed words say (station/src/updates/signed.ts):
# anything else is not installed.
if [ -n "${STILLFAIL_RELEASE_SHA256:-}" ] && [ "$(sha256_of "$tmp/stillfail.tar.gz")" != "$STILLFAIL_RELEASE_SHA256" ]; then
  echo "下载的 station 与签名不符，未安装：下载内容可能已被替换" >&2
  exit 1
fi
# Gzipped or not (tar finds out as it reads): what a station made from a delta is the tar itself, under the same name,
# and STILLFAIL_RELEASE_SHA256 then that tar's. Only an installer from this one on is handed one: the station that made
# it runs the installer it carries, which hands it on to the new release's own, with the same hash.
tar -xf "$tmp/stillfail.tar.gz" -C "$tmp"
# The release checked so is installed by its own installer (bin/install.<lang>.sh in it, scripts/installers.ts): what
# it does from here (its service, its handover) is the new release's, as the cloud's newest installer did it before.
lang="${STILLFAIL_INSTALL_LANG:-zh}"
if [ -n "${STILLFAIL_RELEASE_SHA256:-}" ] && [ -z "${STILLFAIL_INSTALLER_HANDED:-}" ] && [ -f "$tmp/stillfail/bin/install.$lang.sh" ]; then
  keep=$(mktemp -d "${TMPDIR:-/tmp}/stillfail-handed.XXXXXX")
  mv "$tmp/stillfail.tar.gz" "$keep/stillfail.tar.gz"
  cp "$tmp/stillfail/bin/install.$lang.sh" "$keep/install.sh"
  rm -rf "$tmp"
  trap - EXIT
  STILLFAIL_ARCHIVE="$keep/stillfail.tar.gz" STILLFAIL_INSTALLER_HANDED=1 exec sh "$keep/install.sh" "$@"
fi
# Which channel the release came from, for the station.
printf '%s
' "$channel" > "$tmp/stillfail/CHANNEL"

# The Node it runs on (NODE_VERSION: its version) is not in the release: kept apart in node/v<version> beside the data, once per
# version, and linked at <app>/node, where the launcher finds it (and a launcher of an older release handing over to
# this one: it looks there too). The machine's own Node does when it is that very version (another one is not what the
# station was tested on); else it is downloaded and checked. A release from before (Node in it, no NODE_VERSION) needs none.
node_dir=""
if [ -f "$tmp/stillfail/NODE_VERSION" ]; then
  node_version=$(cat "$tmp/stillfail/NODE_VERSION")
  node_dir="$cur/node/v$node_version"
  if [ ! -x "$node_dir/bin/node" ]; then
    # This install's own (the station's update and one asked for can run at once), not one of the v* the next one prunes.
    part="$cur/node/.part-v$node_version.$$"
    rm -rf "$part"
    mkdir -p "$part/bin"
    own=$(command -v node 2>/dev/null || true)
    # With the signed hash of the Node binary (STILLFAIL_NODE_SHA256), the machine's own only when it is that very one.
    if [ -n "$own" ] && [ "$("$own" -v 2>/dev/null)" = "v$node_version" ] && { [ -z "${STILLFAIL_NODE_SHA256:-}" ] || [ "$(sha256_of "$own")" = "$STILLFAIL_NODE_SHA256" ]; }; then
      cp "$own" "$part/bin/node"
    elif [ -n "${STILLFAIL_NODE_SHA256:-}" ]; then
      node_file="node-v$node_version-$platform.tar.gz"
      echo "下载 station 运行所需的 Node ${node_version}（每个版本只下载一次）…"
      if ! download "$origin/releases/node/$node_file" "$tmp/$node_file" -fL --progress-bar; then
        echo "无法从 ${origin} 下载 Node ${node_version}；网络恢复后重新运行安装命令" >&2
        exit 1
      fi
      tar -xzf "$tmp/$node_file" -C "$part"
      if [ "$(sha256_of "$part/bin/node")" != "$STILLFAIL_NODE_SHA256" ]; then
        rm -rf "$part"
        echo "下载的 Node ${node_version} 校验失败，未安装；重新运行安装命令" >&2
        exit 1
      fi
    else
      node_file="node-v$node_version-$platform.tar.gz"
      echo "下载 station 运行所需的 Node ${node_version}（每个版本只下载一次）…"
      if ! download "$origin/releases/node/$node_file" "$tmp/$node_file" -fL --progress-bar || ! download "$origin/releases/node/$node_file.sha256" "$tmp/$node_file.sha256" -fsSL; then
        echo "无法从 ${origin} 下载 Node ${node_version}；网络恢复后重新运行安装命令" >&2
        exit 1
      fi
      want=$(cut -d' ' -f1 < "$tmp/$node_file.sha256")
      got=$(sha256_of "$tmp/$node_file")
      if [ -z "$want" ] || [ "$want" != "$got" ]; then
        echo "下载的 Node ${node_version} 校验失败，未安装；重新运行安装命令" >&2
        exit 1
      fi
      tar -xzf "$tmp/$node_file" -C "$part"
    fi
    "$part/bin/node" -v >/dev/null 2>&1 || { rm -rf "$part"; echo "Node ${node_version} 无法在此机器上运行，未安装" >&2; exit 1; }
    # Another install may have put the same one there meanwhile: the first one stays.
    if [ -x "$node_dir/bin/node" ]; then rm -rf "$part"; else rm -rf "$node_dir" && mv "$part" "$node_dir"; fi
  fi
  ln -s "$node_dir" "$tmp/stillfail/node"
fi
# The Nodes no release here runs on any more, once it runs on this one (a running old one keeps its binary open).
prune_node() {
  [ -n "$node_dir" ] || return 0
  for d in "$(dirname "$node_dir")"/v*; do
    [ "$d" = "$node_dir" ] || rm -rf "$d"
  done
}

# The agents it starts are found on this PATH (Claude Code, Codex, and what they run). Each directory once: run from
# the station (whose PATH is this), it would otherwise grow with every update.
# In WSL, none of Windows' (a Windows npm's `claude` there would run Windows' Node).
agent_path=$(printf '%s' "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH:/usr/bin:/bin" | tr ':' '
' | awk -v wsl="$wsl" 'NF && !(wsl && index($0, "/mnt/") == 1) && !seen[$0]++' | paste -sd: -)
# The service's definition, as this release has it: written below, and compared with the one running now.
if [ "$os" = Darwin ]; then
  service_file="$plist"
  # Paths and PATH are XML text: an ampersand or angle bracket in either must survive launchd's parser.
  xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
  cat > "$tmp/service" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key><array><string>$(xml "$app/bin/stillfail")</string><string>start</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>$(xml "$agent_path")</string><key>STILLFAIL_DATA</key><string>$(xml "$data")</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$(xml "$data/stillfail.log")</string>
    <key>StandardErrorPath</key><string>$(xml "$data/stillfail.log")</string>
</dict>
</plist>
PLIST
elif user_systemd; then
  service_file="$unit_dir/$unit"
  # KillMode=process: stopping the service stops the station, not the jobs it runs (the next one takes them up).
  cat > "$tmp/service" <<UNIT
[Unit]
Description=still.fail station
After=network-online.target

[Service]
ExecStart=$app/bin/stillfail start
Environment=PATH=$agent_path
Environment=STILLFAIL_DATA=$data
Restart=always
RestartSec=5
KillMode=process
StandardOutput=append:$data/stillfail.log
StandardError=append:$data/stillfail.log

[Install]
WantedBy=default.target
UNIT
else
  service_file=""
fi

# What the running station says of itself (run/station.json): its pid, when it started, what it can do.
station_json="$cur/run/station.json"
said() { sed -n "s/.*\"$1\": *\([0-9]*\).*/\1/p" "$station_json" 2>/dev/null | head -1; }
pid=""
if [ -z "$token" ] && [ -f "$station_json" ]; then
  pid=$(said pid)
  # Still that station (a pid is reused once its process is gone): signals go to nothing else.
  case "$(ps -p "${pid:-0}" -o command= 2>/dev/null)" in
    *stillfail-station*) ;;
    *) pid="" ;;
  esac
fi
# The service's definition, less its PATH: what makes a service "changed".
without_path() { sed -e 's#<key>PATH</key><string>[^<]*</string>##' -e '/^Environment=PATH=/d' "$1"; }
same_service() { [ -z "$service_file" ] || { [ -f "$service_file" ] && [ "$(without_path "$tmp/service")" = "$(without_path "$service_file")" ]; }; }
# Whether this runs inside the station: the station among the processes it comes from (an agent's turn, a job).
inside_station() {
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    [ "$p" = "$pid" ] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# One install at a time: two at once (the station updating itself as CI's `stillfail update` ran, both to a release
# that could not start, 2026-11-04) each put aside the app the other had just put in, and the one whose handover failed
# put back the release that could not start. The next waits for the one before (its handover is over within 180 s),
# then finds what it left; one whose holder is gone is taken over, as is one held past 300 s.
lock_dir="$cur/run/install.lock"
mkdir -p "$cur/run"
waited=0
until mkdir "$lock_dir" 2>/dev/null; do
  holder=$(cat "$lock_dir/pid" 2>/dev/null || true)
  if { [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; } || [ "$waited" -ge 300 ]; then rm -rf "$lock_dir"; continue; fi
  sleep 1
  waited=$((waited + 1))
done
echo $$ > "$lock_dir/pid"
trap 'rm -rf "$tmp" "$lock_dir"' EXIT

# Already on this release, and running as its service would: nothing to do.
if [ -n "$pid" ] && [ -f "$app/VERSION" ] && cmp -s "$tmp/stillfail/VERSION" "$app/VERSION" && same_service; then
  cp "$tmp/stillfail/CHANNEL" "$app/CHANNEL" 2>/dev/null || true
  echo "still.fail station 已是最新版本（$(cut -c1-7 "$app/VERSION")），无需更新"
  exit 0
fi

swapped=""
swap_app() {
  mkdir -p "$data"
  rm -rf "$app.old"
  [ -d "$app" ] && mv "$app" "$app.old"
  mv "$tmp/stillfail" "$app"
  swapped=yes
}

# Handed over without stopping: the new release goes where the old one was, and the running station execs it. Only a
# launcher that becomes the release's own as it hands over (`renew`, station/native/launcher/src/run.rs) is handed
# over to: one from before would run on, never changed, until the machine's next start; it is restarted once instead.
handed=""
if [ -n "$pid" ] && [ -n "$(said handoff)" ] && [ -n "$(said renew)" ] && same_service; then
  started=$(said startedAt)
  swap_app
  rm -f "$data/run/handoff-failed"
  step handoff
  echo "将运行中的 station 交接给新版本（agent 不中断）…"
  kill -USR2 "$pid"
  # The new one's 60 s to be ready and 90 s to take over (launcher/src/lifecycle.rs Times), and some.
  for _ in $(seq 1 180); do
    sleep 1
    if [ "$(said startedAt)" != "$started" ]; then
      [ "$(said pid)" = "$pid" ] && handed=yes
      break
    fi
    [ -f "$data/run/handoff-failed" ] && break
  done
  if [ -n "$handed" ]; then
    rm -rf "$app.old"
    prune_node
  elif [ -f "$data/run/handoff-failed" ] && kill -0 "$pid" 2>/dev/null && [ "$(said startedAt)" = "$started" ]; then
    # The new release did not come up or take over, and the station is the launcher it was: the release before goes
    # back, for the Node serving on it (one that did not get ready) or the one the launcher starts after a while (one
    # that did not take over, its old one gone; Times::rollback).
    rm -rf "$app.failed"
    mv "$app" "$app.failed" && { mv "$app.old" "$app" || mv "$app.failed" "$app"; }
    rm -rf "$app.failed"
    echo "无法交接（$(cat "$data/run/handoff-failed")）：新版本未启用，station 继续使用原版本运行" >&2
    exit 1
  elif [ -f "$data/run/handoff-failed" ]; then
    echo "无法交接（$(cat "$data/run/handoff-failed")），改为重启 station" >&2
  elif [ "$(said startedAt)" != "$started" ]; then
    # It went down mid-way and its service started the new release: done, the usual way.
    handed=restarted
    rm -rf "$app.old"
  else
    echo "station 未响应交接，改为重启" >&2
  fi
fi

# Stopped and started again (when not handed over), and said how it went.
restart_and_finish() {
if [ -z "$handed" ] && [ -n "$pid" ] && [ -n "$(said drain)" ] && [ -z "${STILLFAIL_NO_DRAIN:-}" ]; then
  # Restarted: once no turn runs, so none is cut off (at most 10 minutes; it takes no new ones meanwhile).
  rm -f "$cur/run/drained"
  step drain
  kill -USR1 "$pid"
  echo "等待 agent 当前轮次结束后重启（最多 10 分钟；新消息会排队，重启后处理）…"
  for _ in $(seq 1 630); do
    { [ -f "$cur/run/drained" ] || ! kill -0 "$pid" 2>/dev/null; } && break
    sleep 1
  done
fi

if [ -z "$handed" ]; then
step restart
# One running at a time: the old one stops before the new one takes its place.
if [ "$os" = Darwin ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  # bootout returns before the service is gone; bootstrapping it again before then fails.
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 1; done
else
  if user_systemd; then
    systemctl --user stop "$unit" 2>/dev/null || true
  fi
  if [ -f "$cur/stillfail.pid" ]; then kill "$(cat "$cur/stillfail.pid")" 2>/dev/null || true; fi
  rm -f "$cur/stillfail.pid"
  # In still.fail's container: the station is its entrypoint's, which starts the new release once this install lets
  # go of its lock. Ended here, and waited for: the release is not swapped under a station still running on it.
  if [ -n "${STILLFAIL_CONTAINER:-}" ] && [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  fi
fi
[ -n "$swapped" ] || swap_app
rm -rf "$app.old"
prune_node
fi
mkdir -p "$HOME/.local/bin"
ln -sf "$app/bin/stillfail" "$HOME/.local/bin/$product"
# Installed again after stillfail uninstall (or the app's 卸载本机 Station): no longer said so.
rm -f "$data/uninstalled"

if [ -n "$token" ]; then
  echo "加入 workspace…"
  "$app/bin/stillfail" station enroll "$origin" "$token" --stay ${lock:+--lock "$lock"} ${rig:+--rig "${rig#rig:}"}
fi

if [ -n "$handed" ]; then
  :
elif [ "$os" = Darwin ]; then
  mkdir -p "$(dirname "$plist")"
  cp "$tmp/service" "$plist"
  started=""
  # (stopped from the app, the service is disabled: enabled, or bootstrap would load it and never start it)
  launchctl enable "gui/$(id -u)/$label" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null && { started=yes; break; }
    sleep 2
  done
  [ -n "$started" ] || { echo "launchd 无法启动 still.fail station（launchctl bootstrap gui/$(id -u) ${plist}）" >&2; exit 1; }
else
  if user_systemd; then
    mkdir -p "$unit_dir"
    cp "$tmp/service" "$unit_dir/$unit"
    systemctl --user daemon-reload
    systemctl --user enable "$unit" >/dev/null 2>&1
    systemctl --user restart "$unit"
    # Also with no one logged in (a server): the user's services start with the machine.
    loginctl enable-linger "$(id -un)" 2>/dev/null || lingering="no"
  elif [ -n "${STILLFAIL_CONTAINER:-}" ]; then
    # (the container's entrypoint starts it, and again whenever it ends)
    in_container="yes"
  else
    nohup env PATH="$agent_path" STILLFAIL_DATA="$data" "$app/bin/stillfail" start >> "$data/stillfail.log" 2>&1 &
    echo $! > "$data/stillfail.pid"
    no_service="yes"
  fi
fi

echo
if [ "$handed" = yes ]; then
  echo "still.fail station 已更新，运行中的 agent 未中断"
else
  echo "still.fail station 已安装并在后台运行，几秒后将出现在 workspace 中"
fi
echo "  程序：${app}（stillfail 命令位于 ~/.local/bin，旧名称 ember 仍可使用）"
echo "  数据和日志：$data"
echo "  状态：stillfail status（所在 workspace、是否在线、未在工作的原因）"
[ "$os" = Linux ] && [ -z "${no_service:-}" ] && [ -z "${in_container:-}" ] && echo "  服务：systemctl --user status $unit"
[ -n "${lingering:-}" ] && echo "  如需在无人登录时保持运行，执行：sudo loginctl enable-linger $(id -un)"
if [ -n "${in_container:-}" ]; then
  echo "  此机器是 still.fail 的容器：station 由容器的入口程序运行，退出后自动重新启动；容器设了重启策略（docker run --restart unless-stopped）就会随机器启动"
elif [ -n "$wsl" ] && [ -n "${no_service:-}" ]; then
  echo "  当前为 Windows 上的 WSL，且未启用 systemd：station 当前在后台运行，但会随 WSL 停止而停止。如需保持运行：在 /etc/wsl.conf 中添加 [boot] 和 systemd=true 两行（需 sudo 编辑），在 Windows 的 PowerShell 中执行 wsl --shutdown，然后打开 WSL 重新运行此安装命令。"
elif [ -n "${no_service:-}" ]; then
  echo "  此机器没有 systemd 用户服务：station 当前在后台运行，但重启后不会自动启动，届时需执行 stillfail start"
elif [ -n "$wsl" ]; then
  # Said when it is set up, or could not be on a machine joining a workspace (an update leaves it as it was).
  if keep_wsl; then echo "  登录 Windows 时将在后台启动 WSL（${WSL_DISTRO_NAME}）并保持运行，station 随之保持在线（通过启动文件夹中的 stillfail-station-${WSL_DISTRO_NAME}.vbs，删除该文件即可停止自动启动）"
  elif [ -n "$token" ]; then echo "  当前为 Windows 上的 WSL：没有打开的 WSL 窗口时，Windows 会停止 WSL，station 也随之停止。如需保持运行，让 Windows 在登录时执行：wsl.exe -d ${WSL_DISTRO_NAME:-<distro>} --exec sleep infinity"; fi
fi
# The agents as the station will find them (its PATH).
missing=""
(PATH="$agent_path"; command -v claude) >/dev/null 2>&1 || missing="$missing Claude Code"
(PATH="$agent_path"; command -v codex) >/dev/null 2>&1 || missing="$missing Codex"
if [ -n "$missing" ]; then
  echo
  echo "此机器尚未安装：${missing}。station 用它们运行 agent，安装任意一个即可开始使用："
  echo "  Claude Code：curl -fsSL https://claude.ai/install.sh | bash"
  echo "  Codex：      npm install -g @openai/codex（需要 Node）"
  echo "安装后，在 still.fail 的「设置 → Profile」中登录账号。"
fi
}

if [ -z "$handed" ] && [ -n "$pid" ] && inside_station; then
  # Apart from the caller (a process group of its own, output to a file): it restarts once the caller's turn is over.
  mkdir -p "$cur/run"
  echo "此次更新由 station 内部发起（agent 轮次或 job），将在后台等待运行中的轮次（包括当前轮次）结束后重启 station"
  echo "  进度：$data/run/update.log"
  trap - EXIT
  set -m
  # (the lock held on by what goes on, its pid in it)
  ( trap '' HUP; restart_and_finish; rm -rf "$tmp" "$lock_dir" ) > "$cur/run/update.log" 2>&1 < /dev/null &
  echo $! > "$lock_dir/pid"
  exit 0
fi
restart_and_finish
