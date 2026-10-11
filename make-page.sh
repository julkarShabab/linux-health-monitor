#!/bin/bash
# make-page.sh - runs health-check.sh and writes the result as a web page with history charts

BASE="$HOME/health-monitor"              # project folder
OUT="/var/www/health/index.html"         # the page Nginx serves
TMP="$OUT.tmp"                           # temporary file, so visitors never see a half-written page

# Read the config only for HISTORY_FILE
if [ -f "$BASE/health-monitor.conf" ]; then source "$BASE/health-monitor.conf"; fi
HISTORY_FILE=${HISTORY_FILE:-$BASE/logs/history.csv}

REPORT=$("$BASE/health-check.sh")        # run the check (no history row is saved from here)
CODE=$?                                  # exit code: 0 healthy, 1 warning, 2 critical

# Pick a color and label based on the exit code
case $CODE in
  0) COLOR="#1a9e4b"; LABEL="HEALTHY"  ;;
  1) COLOR="#e0a100"; LABEL="WARNING"  ;;
  *) COLOR="#d62828"; LABEL="CRITICAL" ;;
esac

# Escape characters that have special meaning in HTML
SAFE=$(echo "$REPORT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')

# Draw one line chart as inline SVG from the newest 288 history rows (24 hours at 5 minutes each)
# $1 = CSV column number, $2 = line color, $3 = chart title
chart() {
  tail -n 288 "$HISTORY_FILE" | awk -F, -v col="$1" -v color="$2" -v title="$3" '
    $1 != "time" && $col ~ /^[0-9.]+$/ { n++; v[n] = $col; t[n] = substr($1, 12, 5) }
    END {
      if (n < 2) { printf "<p>%s: not enough history yet.</p>\n", title; exit }
      W = 600; H = 100; pts = ""
      for (i = 1; i <= n; i++) {
        x = (i - 1) * W / (n - 1)          # spread the samples across the width
        y = H - v[i] * H / 100             # 0% at the bottom, 100% at the top
        if (y < 0) y = 0
        pts = pts sprintf("%.1f,%.1f ", x, y)
      }
      printf "<h3>%s (%d samples, %s to %s)</h3>\n", title, n, t[1], t[n]
      printf "<svg viewBox=\"0 0 %d %d\" style=\"width:100%%;max-width:600px;background:white;border-radius:8px\">\n", W, H
      printf "<line x1=\"0\" y1=\"%d\" x2=\"%d\" y2=\"%d\" stroke=\"#ddd\"/>\n", H / 2, W, H / 2
      printf "<polyline fill=\"none\" stroke=\"%s\" stroke-width=\"2\" points=\"%s\"/>\n", color, pts
      printf "</svg>\n"
    }'
}

if [ -f "$HISTORY_FILE" ]; then
  CHARTS="$(chart 2 '#d62828' 'CPU usage %')
$(chart 3 '#1a73e8' 'RAM usage %')
$(chart 4 '#8e44ad' 'Disk usage % (/)')"
else
  CHARTS="<p>No history yet. It appears after the first alert run.</p>"
fi

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
    pre { background: white; padding: 1rem; border-radius: 8px; font-size: 1rem; overflow-x: auto; }
    h3 { margin-bottom: 0.3rem; }
  </style>
</head>
<body>
  <div class="status">$LABEL</div>
  <pre>$SAFE</pre>
  <h2>History (last 24 hours)</h2>
  $CHARTS
  <p>Updated: $(date '+%Y-%m-%d %H:%M:%S') (page refreshes every 30 seconds)</p>
</body>
</html>
EOF

mv "$TMP" "$OUT"                         # swap the new page in at once
