#!/bin/bash
# alert.sh - runs health-check.sh and sends a Telegram message only when the status CHANGES.
# HEALTHY -> problem = alert, problem -> HEALTHY = RECOVERED, same status again = silence.

BASE="$HOME/health-monitor"              # project folder
STATE_FILE="$BASE/logs/last_status"      # remembers the status of the previous run

# Load BOT_TOKEN and CHAT_ID; stop with an error if the credentials file is missing
if [ ! -f "$BASE/telegram.conf" ]; then
  echo "ERROR: $BASE/telegram.conf not found" >&2   # >&2 sends the message to the error output
  exit 3
fi
source "$BASE/telegram.conf"

REPORT=$("$BASE/health-check.sh")        # run the check and capture the report text
CODE=$?                                  # exit code: 0 healthy, 1 warning, 2 critical

echo "$REPORT"                           # print the report so the log still gets every run

# Turn the exit code into a status word
case $CODE in
  0) NEW="HEALTHY"  ;;
  1) NEW="WARNING"  ;;
  *) NEW="CRITICAL" ;;
esac

# Read the previous status; with no state file yet, assume HEALTHY
if [ -f "$STATE_FILE" ]; then
  PREV=$(cat "$STATE_FILE")
else
  PREV="HEALTHY"
fi

# Send one Telegram message; curl -f makes HTTP errors count as failures
send_telegram() {
  curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=$1" > /dev/null
}

# Only act when the status changed since the last run
if [ "$NEW" != "$PREV" ]; then
  HOST=$(hostname)
  if [ "$NEW" = "HEALTHY" ]; then
    MSG="RECOVERED on ${HOST}: status is now HEALTHY (was ${PREV})

${REPORT}"
  else
    MSG="${NEW} on ${HOST}: status changed from ${PREV} to ${NEW}

${REPORT}"
  fi

  if send_telegram "$MSG"; then
    echo "$NEW" > "$STATE_FILE"            # save the new status only after the message was sent
    echo "Alert sent: ${PREV} -> ${NEW}"   # visible in the log
  else
    echo "ERROR: Telegram send failed, will retry on next run" >&2
  fi
fi

exit $CODE                                 # pass the original exit code along
