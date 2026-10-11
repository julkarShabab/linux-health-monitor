# Linux Server Health Monitor

A small, dependency-free Bash monitoring project for Ubuntu servers. It checks CPU, RAM, disk, uptime and key services, sends Telegram alerts when something is wrong, and shows live status on a web page served by Nginx.

Built as a beginner-friendly Linux administration project: one server, a few shell scripts, and standard tools (`/proc`, `free`, `df`, `systemctl`, `cron`, `curl`, Nginx).

## Features

- Reports CPU usage, RAM usage, disk usage and uptime
- Checks that required services (SSH and Nginx by default) are running
- Gives an overall status: HEALTHY, WARNING or CRITICAL
- Returns exit codes (0, 1, 2) so other tools can react to the status
- Sends a Telegram message when the status is not HEALTHY
- Generates a color-coded HTML status page that refreshes itself every 30 seconds
- Runs automatically through cron and keeps a log of every report
- Limits and monitored services are easy to change

## How it works

```
        cron (scheduler)
        /              \
 every 5 min        every 1 min
      |                  |
  alert.sh          make-page.sh
      \                  /
       health-check.sh   (collects the data and prints the report)
            |
  reads /proc, free, df, systemctl
     /                     \
 Telegram message       /var/www/health/index.html
 (only if a problem)           |
                          Nginx :8080  -->  browser
```

1. `health-check.sh` samples `/proc/stat` twice (1 second apart) to calculate CPU usage, reads `free` for RAM, `df` for disk and `systemctl is-active` for each service.
2. It compares the values with the limits and prints a report.
3. `alert.sh` and `make-page.sh` both run `health-check.sh` and use its report and exit code.

## Status levels

| Status | Exit code | Meaning |
|---|---|---|
| HEALTHY | 0 | All values are below their limits and all services are running |
| WARNING | 1 | CPU, RAM or disk usage is above its limit |
| CRITICAL | 2 | A required service is not running |

Default limits: CPU 80%, RAM 80%, disk 80%.

## Project structure

```
health-monitor/
├── health-check.sh          # collects metrics, prints the report, sets the exit code
├── alert.sh                 # runs the check, sends a Telegram message if not HEALTHY
├── make-page.sh             # runs the check, writes the HTML status page
├── telegram.conf.example    # template for the Telegram credentials (safe to share)
├── nginx/
│   └── health.conf          # copy of the Nginx server block used to serve the page
├── .gitignore               # keeps telegram.conf and logs out of Git
└── README.md
```

Files created on the server only (not in the repository):

```
health-monitor/telegram.conf   # real bot token and chat ID (ignored by Git)
health-monitor/logs/health.log # cron output (ignored by Git)
/var/www/health/index.html     # the generated status page
```

## Requirements

- Ubuntu (or another systemd-based Linux)
- Bash, `curl`, `cron`
- Nginx and OpenSSH server (the default monitored services)
- A Telegram bot (only for alerts)

```bash
# Run in terminal
sudo apt update                                    # refresh the package list
sudo apt install -y nginx openssh-server curl git # install the required packages
```

## Setup

### 1. Get the project

```bash
# Run in terminal
git clone git@github.com:julkarShabab/linux-health-monitor.git ~/health-monitor   # download the project
cd ~/health-monitor
mkdir -p logs                 # logs/ is not in the repository, so create it
chmod +x *.sh                 # allow the scripts to run
```

### 2. Test the core check

```bash
# Run in terminal
./health-check.sh             # prints the report; the last line is the overall status
echo $?                       # prints the exit code (0 = healthy)
```

### 3. Set up Telegram alerts (optional)

1. In Telegram, message `@BotFather`, send `/newbot` and follow the prompts to get a bot token.
2. Send any message to your new bot.
3. Find your chat ID:

```bash
# Run in terminal
curl -s "https://api.telegram.org/botYOUR_TOKEN/getUpdates"   # find "chat":{"id":NUMBER in the output
```

4. Create the credentials file:

```bash
# Run in terminal
cp telegram.conf.example telegram.conf   # copy the template
nano telegram.conf                       # fill in BOT_TOKEN and CHAT_ID
chmod 600 telegram.conf                  # only your user can read the file
```

5. Test:

```bash
# Run in terminal
./alert.sh                               # sends a message only if the status is not HEALTHY
```

### 4. Set up the web page (optional)

```bash
# Run in terminal
sudo mkdir -p /var/www/health            # folder Nginx will serve
sudo chown $USER:$USER /var/www/health   # let your user write the page
./make-page.sh                           # build the page once
sudo cp nginx/health.conf /etc/nginx/sites-available/health          # install the Nginx config
sudo ln -s /etc/nginx/sites-available/health /etc/nginx/sites-enabled/health   # enable it
sudo nginx -t                            # test the config
sudo systemctl reload nginx              # apply it
curl -I http://localhost:8080            # should return HTTP/1.1 200 OK
```

Open `http://YOUR_SERVER_IP:8080` in a browser. If another program already uses port 8080, change the `listen` line in `nginx/health.conf` to a free port.

### 5. Schedule with cron

```bash
# Run in terminal
crontab -e                               # opens your scheduled jobs
```

```bash
# Every 5 minutes: check, send Telegram if there is a problem, append the report to the log
*/5 * * * * /home/YOUR_USER/health-monitor/alert.sh >> /home/YOUR_USER/health-monitor/logs/health.log 2>&1
# Every minute: rebuild the web page
* * * * * /home/YOUR_USER/health-monitor/make-page.sh > /dev/null 2>&1
```

Replace `YOUR_USER` with the output of `whoami`.

## Configuration

Edit the top of `health-check.sh`:

```bash
CPU_WARN=${CPU_WARN:-80}      # CPU warning limit in percent
RAM_WARN=${RAM_WARN:-80}      # RAM warning limit in percent
DISK_WARN=${DISK_WARN:-80}    # disk warning limit in percent
SERVICES=("ssh" "nginx")      # services that must be running
```

Limits can also be changed for a single run:

```bash
# Run in terminal
DISK_WARN=10 ./health-check.sh    # test the warning logic without filling the disk
```

## Example output

```
Server Health Report
====================

Date:     2026-10-11 11:10:02
Hostname: test01

CPU Usage:       1%
RAM Usage:       36%
Disk Usage:      61%
Uptime:          27 minutes

ssh service:     UP
nginx service:   UP

Overall Status:  HEALTHY
```

When something is wrong:

```
nginx service:   DOWN

Overall Status:  CRITICAL
CRITICAL: nginx is not running!
```

## Testing the monitor

Break the server on purpose and check that the monitor notices:

```bash
# Run in terminal
sudo systemctl stop nginx                                 # expect CRITICAL
./health-check.sh
sudo systemctl start nginx                                # fix it

for i in $(seq "$(nproc)"); do yes > /dev/null & done     # load every CPU core
./health-check.sh                                         # expect a CPU WARNING
pkill yes                                                 # stop the load

DISK_WARN=10 ./health-check.sh                            # simulate a disk warning
```

Avoid stopping SSH while connected through SSH, because it can lock you out.

## Viewing logs

```bash
# Run in terminal
tail -n 20 logs/health.log                      # latest reports
grep -E "CRITICAL|WARNING" logs/health.log      # problems only
```

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| `health.log` stays empty | Wrong path or user in the cron line, or the script is not executable | Check `crontab -l`, run `chmod +x *.sh` |
| No Telegram message | Cron runs `health-check.sh` instead of `alert.sh`, or the status is HEALTHY | Point cron at `alert.sh`; test with a lowered limit |
| Telegram API returns `404 Not Found` | The URL is missing `bot` before the token | Use `https://api.telegram.org/bot<TOKEN>/...` |
| `getUpdates` returns an empty list | You have not sent a message to the bot yet | Send the bot a message and run it again |
| Web page returns 404 from `Apache` | Apache is using port 8080 | Stop Apache or change the `listen` port |
| Web page does not update | `make-page.sh` is not in cron | Add the every-minute cron line |
| A service shows DOWN but is installed | Wrong service name | Check with `systemctl list-units --type=service` |

## Security notes

- `telegram.conf` holds your bot token. It is listed in `.gitignore`, so it is never committed. Keep its permissions at `600`.
- If a token is ever exposed (pasted publicly, committed), revoke it with `/revoke` in `@BotFather` and use the new one.
- The status page shows the hostname and server load. Keep it on your local network and do not expose it to the internet without authentication.

## Limitations

- Monitors a single machine, with no history graphs or trends
- Checks only the root filesystem (`/`) and total CPU and RAM
- Repeats the Telegram alert every 5 minutes while a problem continues
- A shell-script learning project, not a replacement for Prometheus and Grafana

## Possible improvements

- Send each alert only once per problem, plus a "recovered" message
- Monitor more filesystems, network traffic and load average
- Check HTTP responses from the websites, not just that Nginx is running
- Add log rotation for `health.log`
- Move to Prometheus, Node Exporter and Grafana for multi-server monitoring

## What this project covers

Linux administration, Bash scripting, `systemctl` and services, processes and `/proc`, cron scheduling, Nginx configuration, Telegram Bot API calls with `curl`, secrets handling with `.gitignore`, and Git/GitHub basics.
