#!/bin/bash
# make-page.sh - runs health-check.sh and writes the result as a web page

BASE="$HOME/health-monitor"              # project folder
OUT="/var/www/health/index.html"         # the page Nginx serves
TMP="$OUT.tmp"                           # temporary file, so visitors never see a half-written page

REPORT=$("$BASE/health-check.sh")        # run the check and capture the report text
CODE=$?                                  # exit code: 0 healthy, 1 warning, 2 critical

# Pick a color and label based on the exit code
case $CODE in
  0) COLOR="#1a9e4b"; LABEL="HEALTHY"  ;;
  1) COLOR="#e0a100"; LABEL="WARNING"  ;;
  *) COLOR="#d62828"; LABEL="CRITICAL" ;;
esac

# Escape characters that have special meaning in HTML
SAFE=$(echo "$REPORT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

# Write the page; the meta refresh line reloads it every 30 seconds
cat > "$TMP" <<EOF
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="30">
  <title>Server Health: $LABEL</title>
  <style>
    body { font-family: sans-serif; background: #f4f4f4; margin: 2rem; }
    .status { background: $COLOR; color: white; padding: 1rem; font-size: 1.5rem; border-radius: 8px; }
    pre { background: white; padding: 1rem; border-radius: 8px; font-size: 1rem; }
  </style>
</head>
<body>
  <div class="status">$LABEL</div>
  <pre>$SAFE</pre>
  <p>Updated: $(date '+%Y-%m-%d %H:%M:%S') (page refreshes every 30 seconds)</p>
</body>
</html>
EOF

mv "$TMP" "$OUT"                         # swap the new page in at once
