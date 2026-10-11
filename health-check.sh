#!/bin/bash
# health-check.sh - Linux Server Health Monitor
# Checks CPU, RAM, swap, load, filesystems, inodes, uptime, failed SSH logins,
# services, websites and (optionally) MariaDB, then prints a report.
# Exit codes: 0 = HEALTHY, 1 = WARNING, 2 = CRITICAL

# ---------- Load settings ----------
BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # folder this script lives in
CONFIG="${HEALTH_CONFIG:-$BASE/health-monitor.conf}"   # config path (HEALTH_CONFIG can point to a test config)
if [ -f "$CONFIG" ]; then source "$CONFIG"; fi         # load limits, services, websites ...

# Safety defaults, used only if the config file is missing or lacks a setting
CPU_WARN=${CPU_WARN:-80}
RAM_WARN=${RAM_WARN:-80}
DISK_WARN=${DISK_WARN:-95}
INODE_WARN=${INODE_WARN:-80}
SWAP_WARN=${SWAP_WARN:-50}
LOAD_WARN_PER_CORE=${LOAD_WARN_PER_CORE:-2}
SSH_FAIL_WARN=${SSH_FAIL_WARN:-20}
SSH_FAIL_WINDOW=${SSH_FAIL_WINDOW:-1 hour ago}
WEB_TIMEOUT=${WEB_TIMEOUT:-5}
MARIADB_CHECK=${MARIADB_CHECK:-no}
MARIADB_SERVICE=${MARIADB_SERVICE:-mariadb}
MARIADB_PING=${MARIADB_PING:-yes}
HISTORY_FILE=${HISTORY_FILE:-$BASE/logs/history.csv}
HISTORY_MAX_LINES=${HISTORY_MAX_LINES:-2016}
if [ "${#SERVICES[@]}" -eq 0 ]; then SERVICES=("ssh" "nginx"); fi   # default services when none are configured

# ---------- State ----------
WARNINGS=()    # collects warning messages
CRITICALS=()   # collects critical messages

# ---------- Functions ----------

# CPU usage %: sample /proc/stat twice, 1 second apart
get_cpu_usage() {
  # fields after "cpu": user nice system idle iowait irq softirq steal
  read -r _ u1 n1 s1 i1 w1 q1 sq1 st1 _ < /proc/stat
  sleep 1
  read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat

  local idle1=$((i1 + w1))                                  # idle time at sample 1
  local idle2=$((i2 + w2))                                  # idle time at sample 2
  local total1=$((u1 + n1 + s1 + i1 + w1 + q1 + sq1 + st1)) # all time at sample 1
  local total2=$((u2 + n2 + s2 + i2 + w2 + q2 + sq2 + st2)) # all time at sample 2

  local dt=$((total2 - total1))                             # total time that passed
  local di=$((idle2 - idle1))                               # idle time that passed
  if [ "$dt" -eq 0 ]; then echo 0; return; fi               # avoid dividing by zero
  echo $(( (100 * (dt - di)) / dt ))                        # busy time as a percentage
}

# RAM usage %: (total - available) / total
get_ram_usage() {
  free -b | awk '/^Mem:/ {printf "%d", ($2 - $7) / $2 * 100}'
}

# Swap usage %: prints n/a when the server has no swap
get_swap_usage() {
  free -b | awk '/^Swap:/ { if ($2 == 0) print "n/a"; else printf "%d", $3 / $2 * 100 }'
}

# Disk usage % of the root filesystem (used for the CSV history)
get_disk_usage() {
  df / --output=pcent | tail -1 | tr -dc '0-9'
}

# Is a service running? Prints UP or DOWN
check_service() {
  if systemctl is-active --quiet "$1"; then
    echo "UP"
  else
    echo "DOWN"
  fi
}

# HTTP status code of a URL (000 means no answer)
check_website() {
  curl -s -o /dev/null -w '%{http_code}' --max-time "$WEB_TIMEOUT" "$1" 2>/dev/null
}

# Failed SSH logins in the configured window; prints n/a if the journal is not readable
get_ssh_failures() {
  # reading the journal needs root or membership of the adm / systemd-journal group
  if [ "$(id -u)" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qxE 'adm|systemd-journal'; then
    echo "n/a"
    return
  fi
  { journalctl -u ssh -u sshd --since "$SSH_FAIL_WINDOW" --no-pager -q 2>/dev/null \
      | grep -cE "Failed password|Invalid user|authentication failure"; } || true   # grep -c prints 0 when nothing matches
}

# ---------- Collect data ----------
HOSTNAME_VAL=$(hostname)
UPTIME_VAL=$(uptime -p | sed 's/^up //')   # sed removes the leading "up "
CPU=$(get_cpu_usage)
RAM=$(get_ram_usage)
SWAP=$(get_swap_usage)
DISK=$(get_disk_usage)
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg          # load averages for 1, 5 and 15 minutes
CORES=$(nproc)                                         # number of CPU cores
LOAD_LIMIT=$(awk -v c="$CORES" -v f="$LOAD_WARN_PER_CORE" 'BEGIN {printf "%.2f", c * f}')   # warning limit for the 1-minute load
SSH_FAILS=$(get_ssh_failures)

# Filesystems: skip tmpfs, devtmpfs, squashfs (snaps), overlay and efivarfs
DF_EXCLUDE=(-x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs)
mapfile -t FS_LIST < <(df -P "${DF_EXCLUDE[@]}" 2>/dev/null \
  | awk 'NR>1 && $5 ~ /^[0-9]+%$/ {gsub("%","",$5); print $6 " " $5}')    # lines like "/ 61"
declare -A INODE_USE                                                       # inode usage per mount point
while read -r mnt pct; do
  INODE_USE["$mnt"]="$pct"
done < <(df -iP "${DF_EXCLUDE[@]}" 2>/dev/null \
  | awk 'NR>1 && $5 ~ /^[0-9]+%$/ {gsub("%","",$5); print $6 " " $5}')

# ---------- Compare against limits ----------
[ "$CPU" -gt "$CPU_WARN" ] && WARNINGS+=("CPU usage is ${CPU}% (limit ${CPU_WARN}%)")
[ "$RAM" -gt "$RAM_WARN" ] && WARNINGS+=("RAM usage is ${RAM}% (limit ${RAM_WARN}%)")
if [[ "$SWAP" =~ ^[0-9]+$ ]] && [ "$SWAP" -gt "$SWAP_WARN" ]; then
  WARNINGS+=("Swap usage is ${SWAP}% (limit ${SWAP_WARN}%)")
fi
if awk -v a="$LOAD1" -v b="$LOAD_LIMIT" 'BEGIN {exit !(a > b)}'; then
  WARNINGS+=("Load average is ${LOAD1} (limit ${LOAD_LIMIT} for ${CORES} cores)")
fi
if [[ "$SSH_FAILS" =~ ^[0-9]+$ ]] && [ "$SSH_FAILS" -gt "$SSH_FAIL_WARN" ]; then
  WARNINGS+=("${SSH_FAILS} failed SSH logins (${SSH_FAIL_WINDOW}, limit ${SSH_FAIL_WARN})")
fi
for line in "${FS_LIST[@]}"; do
  mnt=${line% *}; pct=${line##* }                       # split "mount percent"
  [ "$pct" -gt "$DISK_WARN" ] && WARNINGS+=("Filesystem ${mnt} is ${pct}% full (limit ${DISK_WARN}%)")
  ipct=${INODE_USE[$mnt]}
  if [ -n "$ipct" ] && [ "$ipct" -gt "$INODE_WARN" ]; then
    WARNINGS+=("Filesystem ${mnt} inodes are ${ipct}% used (limit ${INODE_WARN}%)")
  fi
done

# ---------- Print report ----------
echo "Server Health Report"
echo "===================="
echo
echo "Date:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hostname: $HOSTNAME_VAL"
echo
printf "%-16s %s\n" "CPU Usage:"    "${CPU}%"
printf "%-16s %s\n" "RAM Usage:"    "${RAM}%"
if [[ "$SWAP" =~ ^[0-9]+$ ]]; then SWAP_TXT="${SWAP}%"; else SWAP_TXT="n/a (no swap)"; fi
printf "%-16s %s\n" "Swap Usage:"   "$SWAP_TXT"
printf "%-16s %s\n" "Load average:" "${LOAD1} ${LOAD5} ${LOAD15} (${CORES} cores)"
printf "%-16s %s\n" "Disk Usage:"   "${DISK}%"
printf "%-16s %s\n" "Uptime:"       "$UPTIME_VAL"
printf "%-16s %s\n" "SSH failures:" "${SSH_FAILS} (${SSH_FAIL_WINDOW})"
echo
echo "Filesystems:"
for line in "${FS_LIST[@]}"; do
  mnt=${line% *}; pct=${line##* }
  ipct=${INODE_USE[$mnt]}
  if [ -n "$ipct" ]; then ipct="${ipct}%"; else ipct="n/a"; fi
  printf "  %-22s disk %3s%%   inodes %s\n" "$mnt" "$pct" "$ipct"
done
echo

# Check every service in the SERVICES list
for svc in "${SERVICES[@]}"; do
  state=$(check_service "$svc")
  printf "%-16s %s\n" "${svc} service:" "$state"
  if [ "$state" = "DOWN" ]; then
    CRITICALS+=("${svc} is not running!")
  fi
done

# MariaDB: service must be running and (optionally) answer a ping
if [ "$MARIADB_CHECK" = "yes" ]; then
  state=$(check_service "$MARIADB_SERVICE")
  printf "%-16s %s\n" "${MARIADB_SERVICE} service:" "$state"
  if [ "$state" = "DOWN" ]; then
    CRITICALS+=("${MARIADB_SERVICE} is not running!")
  elif [ "$MARIADB_PING" = "yes" ]; then
    ADMIN=$(command -v mariadb-admin || command -v mysqladmin)   # whichever client tool is installed
    if [ -z "$ADMIN" ]; then
      printf "%-16s %s\n" "MariaDB ping:" "skipped (mariadb-admin not installed)"
    elif timeout 5 "$ADMIN" ping > /dev/null 2>&1; then          # exit code 0 = the server answered
      printf "%-16s %s\n" "MariaDB ping:" "alive"
    else
      printf "%-16s %s\n" "MariaDB ping:" "NO ANSWER"
      CRITICALS+=("MariaDB is running but not answering ping")
    fi
  fi
fi

# Check every website in the WEBSITES list
if [ "${#WEBSITES[@]}" -gt 0 ]; then
  echo
  for url in "${WEBSITES[@]}"; do
    code=$(check_website "$url")
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then                    # 2xx and 3xx count as up
      printf "Website %s: UP (HTTP %s)\n" "$url" "$code"
    else
      printf "Website %s: DOWN (HTTP %s)\n" "$url" "${code:-000}"
      CRITICALS+=("Website ${url} returned HTTP ${code:-000}")
    fi
  done
fi
echo

# ---------- Save a history row (only when the caller asks for it) ----------
if [ "${RECORD_HISTORY:-0}" = "1" ]; then
  mkdir -p "$(dirname "$HISTORY_FILE")"                           # make sure logs/ exists
  [ -f "$HISTORY_FILE" ] || echo "time,cpu,ram,disk,load1,swap" > "$HISTORY_FILE"   # header for a new file
  if [[ "$SWAP" =~ ^[0-9]+$ ]]; then SWAP_CSV="$SWAP"; else SWAP_CSV=0; fi
  echo "$(date '+%Y-%m-%d %H:%M'),${CPU},${RAM},${DISK},${LOAD1},${SWAP_CSV}" >> "$HISTORY_FILE"
  # keep the file small: header plus the newest rows
  if [ "$(wc -l < "$HISTORY_FILE")" -gt "$HISTORY_MAX_LINES" ]; then
    { head -n 1 "$HISTORY_FILE"; tail -n $((HISTORY_MAX_LINES - 1)) "$HISTORY_FILE"; } > "$HISTORY_FILE.tmp" \
      && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
  fi
fi

# ---------- Overall status ----------
if [ "${#CRITICALS[@]}" -gt 0 ]; then
  OVERALL="CRITICAL"; EXIT_CODE=2
elif [ "${#WARNINGS[@]}" -gt 0 ]; then
  OVERALL="WARNING"; EXIT_CODE=1
else
  OVERALL="HEALTHY"; EXIT_CODE=0
fi

echo "Overall Status:  $OVERALL"

# Print each problem on its own line
for msg in "${CRITICALS[@]}"; do echo "CRITICAL: $msg"; done
for msg in "${WARNINGS[@]}";  do echo "WARNING:  $msg"; done

exit $EXIT_CODE
