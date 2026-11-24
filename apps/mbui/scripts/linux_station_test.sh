#!/bin/bash
# This machine's station as the Linux app says it (src/host/linux_station.c, through scripts/linux_station_test.c), in a
# home of the run's own: one started by hand said so, with its release, its data and its workspace, and stopped from
# here; the installer's systemd service said as what runs it, and a machine that only runs tasks taken out of its
# workspace said so; that service stopped for good (disabled), started again (enabled), and the station taken away
# (卸载本机 Station: its service, its launcher, its link and its release gone, its data kept and said so); another
# product's app started with another station's STILLFAIL_DATA telling its installer and service its own. systemctl is
# a stand-in of the run's, saying what it was asked: nothing of this machine's own. On Linux, with GTK 4's development
# files and MoonBit (MOON_HOME) for its runtime.
set -eu
D="$(cd "$(dirname "$0")" && pwd)"
A="$D/.."
O="$A/out/linux-station"
MOON_HOME=${MOON_HOME:-$HOME/.moon}
rm -rf "$O" && mkdir -p "$O"
cc -Wall -Werror -Wno-unused-function -I "$A/../../libs/ui/src/host" -I "$MOON_HOME/include" "$D/linux_station_test.c" "$MOON_HOME/lib/runtime/runtime.c" \
  $(pkg-config --cflags --libs gtk4) -lpthread -lm -o "$O/linux_station_test"

# a home of the run's own: a station's data (~/.stillfail) whose run/station.json names a process of the run's, alive
# until it is stopped (a stand-in for the station), and whose mesh/cloud.json names its workspace
S="$O/home"
mkdir -p "$S/.stillfail/run" "$S/.stillfail/mesh" "$S/.stillfail/app"
printf '{"workspace":"ws1","workspace_name":"星火","station":"st1","name":"Studio","removed_at":null}' \
  > "$S/.stillfail/mesh/cloud.json"
tail -f /dev/null & ST=$!
printf '{"pid":%d,"version":"0.1.4321"}' $ST > "$S/.stillfail/run/station.json"
out=$(HOME=$S XDG_CONFIG_HOME=$S/.config "$O/linux_station_test" stop) || { kill $ST 2> /dev/null; exit 1; }
read=$(printf '%s\n' "$out" | grep -a "STATIONCHECK read"); after=$(printf '%s\n' "$out" | grep -a "STATIONCHECK after")
echo "$read"; echo "$after"
for want in '"runner":"other"' '"version":"0.1.4321"' '"installed":true' "\"data\":\"$S/.stillfail\"" \
  '"workspace":{"id":"ws1","name":"星火","station":"st1","stationName":"Studio","removed":false}'; do
  case "$read" in *"$want"*) ;; *) kill $ST 2> /dev/null; echo "station (linux): not said: $want"; exit 1 ;; esac
done
case "$after" in *'"runner":"none"'*) ;; *) kill $ST 2> /dev/null; echo "station (linux): not stopped"; exit 1 ;; esac
wait $ST 2> /dev/null || true
if kill -0 $ST 2> /dev/null; then kill $ST; echo "station (linux): said stopped, still running"; exit 1; fi

# the installer's service there (its unit, where systemd looks for a user's): what runs it
mkdir -p "$S/.config/systemd/user" && : > "$S/.config/systemd/user/stillfail-station.service"
# (its data now a rig's, taken out of its workspace: both said)
printf '{"workspace":"ws1","station":"st1","removed_at":1700000000,"rig":{"owner":"u1"}}' > "$S/.stillfail/mesh/cloud.json"
tail -f /dev/null & ST=$!
printf '{"pid":%d,"version":"0.1.4321"}' $ST > "$S/.stillfail/run/station.json"
read=$(HOME=$S XDG_CONFIG_HOME=$S/.config "$O/linux_station_test" read | grep -a "STATIONCHECK read") || true
kill $ST
echo "$read"
case "$read" in *'"runner":"service"'*'"service":{"kind":"systemd","name":"stillfail-station.service"}'*) ;;
  *) echo "station (linux): its service not said"; exit 1 ;; esac
case "$read" in *'"workspace":{"id":"ws1","station":"st1","removed":true,"rig":true}'*) ;;
  *) echo "station (linux): a rig taken out of its workspace not said"; exit 1 ;; esac

# its service stopped from here for good, started again, then taken away; systemctl the run's, saying what it is asked
mkdir -p "$O/bin"
printf '#!/bin/sh\necho "systemctl $*" >> "%s/said"\n' "$S" > "$O/bin/systemctl" && chmod +x "$O/bin/systemctl"
run() { HOME=$S XDG_CONFIG_HOME=$S/.config PATH="$O/bin:$PATH" "$O/linux_station_test" "$1" | grep -a "STATIONCHECK after"; }
said() { cat "$S/said" 2> /dev/null; }
after=$(run stop); echo "$after"
case "$(said)" in *"systemctl --user disable --now stillfail-station.service"*) ;; *) echo "station (linux): stopped, not disabled: $(said)"; exit 1 ;; esac
: > "$S/.stillfail/uninstalled"
after=$(run start); echo "$after"
case "$(said)" in *"systemctl --user enable --now stillfail-station.service"*) ;; *) echo "station (linux): started, not enabled: $(said)"; exit 1 ;; esac
[ ! -e "$S/.stillfail/uninstalled" ] || { echo "station (linux): started, still said taken away"; exit 1; }
after=$(run restart); echo "$after"
case "$(said)" in *"systemctl --user enable stillfail-station.service"*"systemctl --user restart stillfail-station.service"*) ;;
  *) echo "station (linux): restarted, not enabled first: $(said)"; exit 1 ;; esac

# taken away: a launcher's stand-in running this data (its pid as the station says it), the installer's link to the
# release, its Node, its run, beside its data
sh -c 'trap "kill \$!; exit" TERM; tail -f /dev/null & wait' stillfail-station run --data "$S/.stillfail" & ST=$!
printf '{"pid":%d,"version":"0.1.4321"}' $ST > "$S/.stillfail/run/station.json"
mkdir -p "$S/.stillfail/app/bin" "$S/.stillfail/node/v24" "$S/.stillfail/app.old" "$S/.local/bin"
: > "$S/.stillfail/app/bin/stillfail" && ln -sf "$S/.stillfail/app/bin/stillfail" "$S/.local/bin/stillfail"
: > "$S/said"
after=$(run uninstall) || { kill $ST 2> /dev/null; exit 1; }
echo "$after"
for want in '"runner":"none"' '"uninstalled":true'; do
  case "$after" in *"$want"*) ;; *) kill $ST 2> /dev/null; echo "station (linux): taken away, not said: $want"; exit 1 ;; esac
done
case "$after" in *'"service"'*|*'"installed"'*|*'"failed"'*) kill $ST 2> /dev/null; echo "station (linux): taken away, said otherwise"; exit 1 ;; esac
case "$(said)" in *"systemctl --user disable --now stillfail-station.service"*"systemctl --user daemon-reload"*) ;;
  *) kill $ST 2> /dev/null; echo "station (linux): its service not taken away: $(said)"; exit 1 ;; esac
# (ended: gone, or this script's child not reaped yet)
case "$(ps -o stat= -p $ST 2> /dev/null)" in ""|Z*) wait $ST 2> /dev/null || true ;; *) kill $ST; echo "station (linux): taken away, its launcher still running"; exit 1 ;; esac
for gone in .config/systemd/user/stillfail-station.service .local/bin/stillfail .stillfail/app .stillfail/app.old .stillfail/node .stillfail/run; do
  [ ! -e "$S/$gone" ] && [ ! -L "$S/$gone" ] || { echo "station (linux): taken away, $gone still there"; exit 1; }
done
[ -f "$S/.stillfail/mesh/cloud.json" ] || { echo "station (linux): taken away, its data with it"; exit 1; }

# taken away where only its unit is left (its data removed by hand), in WSL: done, the unit and Windows' keeper of it
# gone, nothing said taken away where there is no data to say it in (cmd.exe and wslpath the run's, a drive C: in $O/c)
rm -rf "$S/.stillfail" && mkdir -p "$S/.config/systemd/user" && : > "$S/.config/systemd/user/stillfail-station.service"
K="$O/c/Roaming/Microsoft/Windows/Start Menu/Programs/Startup"
mkdir -p "$K" && : > "$K/stillfail-station-Ubuntu.vbs" && : > "$K/stillfail-station-Debian.vbs"
printf '#!/bin/sh\nprintf "C:\\\\Users\\\\kim\\\\AppData\\\\Roaming\\r\\n"\n' > "$O/bin/cmd.exe"
printf '#!/bin/sh\necho "%s/c/Roaming"\n' "$O" > "$O/bin/wslpath"
chmod +x "$O/bin/cmd.exe" "$O/bin/wslpath"
: > "$S/said"
after=$(WSL_DISTRO_NAME=Ubuntu run uninstall); echo "$after"
case "$after" in "STATIONCHECK after ") ;; *) echo "station (linux): with no data, taken away said otherwise: $after"; exit 1 ;; esac
[ ! -e "$S/.config/systemd/user/stillfail-station.service" ] || { echo "station (linux): with no data, its unit left"; exit 1; }
[ ! -e "$S/.stillfail" ] || { echo "station (linux): with no data, its data made anew"; exit 1; }
[ ! -e "$K/stillfail-station-Ubuntu.vbs" ] && [ -e "$K/stillfail-station-Debian.vbs" ] || { echo "station (linux): WSL's keeper of this distribution not the one taken away"; exit 1; }

# another product's app (monoid's: MBUI_STATION_ID) started with a STILLFAIL_DATA naming another station's data (a
# shell's, still.fail's station's agents'): its installer and its service's commands told its own data, never that one
# (curl the run's, giving an installer that says what it was told)
M="$O/monoid"
mkdir -p "$M/.monoid/app" "$M/.monoid/mesh" "$M/.config/systemd/user" && : > "$M/.config/systemd/user/monoid-station.service"
printf '{"workspace":"ws1","station":"st1","removed_at":null}' > "$M/.monoid/mesh/cloud.json"
printf '#!/bin/sh\necho "systemctl $* STILLFAIL_DATA=$STILLFAIL_DATA" >> "%s/said"\n' "$M" > "$O/bin/systemctl"
printf '#!/bin/sh\necho %s\n' "'echo \"install.sh STILLFAIL_DATA=\$STILLFAIL_DATA\" >> \"$M/said\"'" > "$O/bin/curl"
chmod +x "$O/bin/systemctl" "$O/bin/curl"
mrun() { HOME=$M XDG_CONFIG_HOME=$M/.config MBUI_STATION_ID=monoid STILLFAIL_DATA=$S/.stillfail PATH="$O/bin:$PATH" "$O/linux_station_test" "$1" | grep -a "STATIONCHECK after"; }
msaid() { cat "$M/said" 2> /dev/null; }
after=$(mrun 'update {"origin":"https://app.monoid.build"}'); echo "$after"
after=$(mrun restart); echo "$after"
case "$(msaid)" in *"install.sh STILLFAIL_DATA=$M/.monoid"*"systemctl --user restart monoid-station.service STILLFAIL_DATA=$M/.monoid"*) ;;
  *) echo "station (linux): monoid's app, not told its own data: $(msaid)"; exit 1 ;; esac
case "$(msaid)" in *"$S/.stillfail"*|*stillfail-station*) echo "station (linux): monoid's app, told another's: $(msaid)"; exit 1 ;; esac
echo "station (linux): one started by hand said and stopped; the service's said as running it, stopped for good, started and restarted enabled; taken away, its data kept; taken away with only its unit left, WSL's keeper with it; another product's app tells its installer and service its own data"
