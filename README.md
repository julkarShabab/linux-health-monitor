# Linux Server Health Monitor

A small Bash monitoring project for Ubuntu servers.

## What it does
- `health-check.sh` reports CPU, RAM, disk, uptime and SSH/Nginx status, ending in HEALTHY, WARNING or CRITICAL
- `alert.sh` sends a Telegram message when the status is not HEALTHY
- `make-page.sh` writes an HTML status page served by Nginx on port 8080
- Cron runs the alert check every 5 minutes and rebuilds the page every minute

## Setup
1. Copy `telegram.conf.example` to `telegram.conf` and fill in your bot token and chat ID
2. Run `chmod +x *.sh`
3. Add the cron lines for `alert.sh` and `make-page.sh`

## Scope
A single-server learning project. It does not replace tools such as Prometheus and Grafana.
