#!/bin/bash
# health-check.sh - Linux Server Health Monitor
# Checks CPU, RAM, disk, uptime and key services, then prints a report.
# Exit codes: 0 = HEALTHY, 1 = WARNING, 2 = CRITICAL

# ---------- Settings ----------
# Limits can be overridden for one run, e.g.:  DISK_WARN=10 ./health-check.sh
CPU_WARN=${CPU_WARN:-80}      # warn if CPU usage % is above this
RAM_WARN=${RAM_WARN:-80}      # warn if RAM usage % is above this
DISK_WARN=${DISK_WARN:-80}    # warn if disk usage % is above this
SERVICES=("ssh" "nginx")      # services that must be running (add more names here)

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

# Disk usage % of the root filesystem
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

# ---------- Collect data ----------
HOSTNAME_VAL=$(hostname)
UPTIME_VAL=$(uptime -p | sed 's/^up //')   # sed removes the leading "up "
CPU=$(get_cpu_usage)
RAM=$(get_ram_usage)
DISK=$(get_disk_usage)

# ---------- Compare against limits ----------
[ "$CPU"  -gt "$CPU_WARN"  ] && WARNINGS+=("CPU usage is ${CPU}% (limit ${CPU_WARN}%)")
[ "$RAM"  -gt "$RAM_WARN"  ] && WARNINGS+=("RAM usage is ${RAM}% (limit ${RAM_WARN}%)")
[ "$DISK" -gt "$DISK_WARN" ] && WARNINGS+=("Disk usage is ${DISK}% (limit ${DISK_WARN}%)")

# ---------- Print report ----------
echo "Server Health Report"
echo "===================="
echo
echo "Date:     $(date '+%Y-%m-%d %H:%M:%S')"
echo "Hostname: $HOSTNAME_VAL"
echo
printf "%-16s %s\n" "CPU Usage:"  "${CPU}%"
printf "%-16s %s\n" "RAM Usage:"  "${RAM}%"
printf "%-16s %s\n" "Disk Usage:" "${DISK}%"
printf "%-16s %s\n" "Uptime:"     "$UPTIME_VAL"
echo

# Check every service in the SERVICES list
for svc in "${SERVICES[@]}"; do
  state=$(check_service "$svc")
  printf "%-16s %s\n" "${svc} service:" "$state"
  if [ "$state" = "DOWN" ]; then
    CRITICALS+=("${svc} is not running!")
  fi
done
echo

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
