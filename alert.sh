#!/bin/bash
# alert.sh - runs health-check.sh and sends a Telegram message if status is not HEALTHY

BASE="$HOME/health-monitor"          # project folder
source "$BASE/telegram.conf"         # loads BOT_TOKEN and CHAT_ID

REPORT=$("$BASE/health-check.sh")    # run the check and capture the report text
CODE=$?                              # capture its exit code (0 healthy, 1 warning, 2 critical)

echo "$REPORT"                       # print the report so cron still writes it to the log

# Only send a message when something is wrong
if [ "$CODE" -ne 0 ]; then
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=${REPORT}" > /dev/null   # sends the full report as the message
fi

exit $CODE                           # pass the original exit code along
