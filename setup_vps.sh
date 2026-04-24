#!/bin/bash
# =============================================================================
# VPS SETUP SCRIPT — Debian Minimal
# Trading automation: IB Gateway + Telegram bot + Python/conda environment
#
# PURPOSE
# -------
# This script turns a freshly provisioned Debian droplet into a hardened,
# minimal trading server. It is designed to be run once as root immediately
# after first login. After it completes, you should never need to log in as
# root again — all ongoing work happens as the unprivileged "deploy" user.
#
# HOW TO RUN
# ----------
#   chmod +x setup_vps.sh
#   sudo bash setup_vps.sh
#
# IMPORTANT: Do not close your root session until you have confirmed that
# SSH login works on your new custom port. See the final instructions.
# =============================================================================


# =============================================================================
# SHELL SAFETY OPTIONS
# =============================================================================
#
# These three options make the script fail loudly rather than silently
# continuing after an error, which is critical for a setup script where
# each step often depends on the previous one succeeding.
#
#   set -e  (errexit)  — exit immediately if any command returns a non-zero
#                        exit code. Without this, a failed apt install would
#                        be silently ignored and the script would keep going.
#
#   set -u  (nounset)  — treat references to undefined variables as errors.
#                        Prevents subtle bugs like a typo in $NEW_USER causing
#                        a command to run with an empty string instead of the
#                        intended username.
#
#   set -o pipefail    — by default, a pipeline like "cmd1 | cmd2" only fails
#                        if the last command fails. This makes the whole
#                        pipeline fail if any stage fails.
#
# The combined shorthand "set -euo pipefail" is standard practice for
# robust shell scripts.

set -euo pipefail

# IFS (Internal Field Separator) controls how bash splits words and lines.
# Setting it to newline+tab (instead of the default which includes spaces)
# prevents subtle bugs when filenames or variables contain spaces.

IFS=$'\n\t'


# =============================================================================
# CONFIGURATION — EDIT THESE BEFORE RUNNING
# =============================================================================
#
# These are the only values you should need to change before running the
# script. Everything else is derived from these.
#
# NEW_USER
#   The name of the unprivileged system user that will own and run all
#   trading processes. Using a dedicated user (rather than root) means that
#   even if your trading scripts are compromised, the attacker cannot affect
#   system files. "deploy" is a common convention for this pattern.
#
# SSH_PORT
#   The port your SSH server will listen on. Changing from the default (22)
#   dramatically reduces log noise from automated scanners, which probe port
#   22 on every IP on the internet within minutes of a new server going live.
#   Any port above 1024 that isn't used by another service works. 2222 is a
#   common alternative — you could use anything like 2222, 2244, 7722, etc.
#
# YOUR_PUBLIC_KEY
#   Your SSH public key from your local machine. This is NOT your private key
#   (which stays on your laptop and never leaves it). To get your public key:
#     cat ~/.ssh/id_ed25519.pub     (if you have an ed25519 key)
#     cat ~/.ssh/id_rsa.pub         (if you have an RSA key)
#   If you don't have a key pair yet, generate one on your local machine with:
#     ssh-keygen -t ed25519 -C "trading-vps"
#   Then paste the entire contents of the .pub file as the value below.

NEW_USER="deploy"
SSH_PORT="2222"
YOUR_PUBLIC_KEY="ssh-ed25519 AAAA...your_public_key_here"


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
#
# Small utility functions used throughout the script for consistent output
# and safety checks.
#
# log()  — prints a green header line so you can easily follow progress when
#          the script is running. The \033[1;32m and \033[0m are ANSI escape
#          codes for bold green and reset respectively.
#
# warn() — prints a yellow warning line for non-fatal issues worth noting
#          (e.g. a user that already exists and is being skipped).
#
# require_root() — checks that the script is being run as root (UID 0).
#          EUID is the "effective user ID" — 0 means root. Many of the
#          operations below (installing packages, modifying system config,
#          creating users) require root privileges and will silently fail or
#          produce confusing errors if run as a regular user.

log()  { echo -e "\n\033[1;32m>>> $1\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $1\033[0m"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Try: sudo bash setup_vps.sh" >&2
        exit 1
    fi
}

require_root


# =============================================================================
# STEP 1 — SYSTEM UPDATE
# =============================================================================
#
# Before installing anything, bring all existing packages up to date. This is
# important because a fresh Debian image from DigitalOcean may be days or
# weeks old and could have known security vulnerabilities in its packages.
#
# apt update        — refreshes the local package index (the list of what
#                     versions are available). Does NOT install anything.
#
# apt upgrade -y    — installs available updates for all installed packages.
#                     The -y flag answers "yes" to the confirmation prompt
#                     automatically, since we're running non-interactively.
#
# apt autoremove -y — removes packages that were installed as dependencies
#                     but are no longer needed. Keeps the system lean.

log "Updating system packages"
apt update -y
apt upgrade -y
apt autoremove -y


# =============================================================================
# STEP 2 — INSTALL MINIMAL REQUIRED PACKAGES
# =============================================================================
#
# We install only what is strictly necessary for our use case. Every
# unnecessary package is an additional attack surface — more code that could
# have vulnerabilities, more services that could be exploited. This is the
# principle of minimal footprint.
#
# ufw               — Uncomplicated Firewall. A user-friendly front-end to
#                     iptables (Linux's built-in packet filtering). We'll
#                     configure it to block all inbound connections except SSH.
#
# fail2ban          — Monitors log files for repeated authentication failures
#                     and automatically bans offending IPs using firewall rules.
#                     Essential for SSH protection even with key-only auth.
#
# unattended-upgrades — Automatically applies security patches in the
#                     background. Critical for a server you don't log into
#                     daily.
#
# curl / wget       — HTTP download tools. wget is used here to download the
#                     Miniconda installer; curl is useful for general scripting
#                     and health checks.
#
# git               — Version control. Used to clone your trading code repo
#                     onto the server. Also useful for pulling updates.
#
# bzip2             — Compression utility required by the Miniconda installer,
#                     which is distributed as a .sh file containing a
#                     bzip2-compressed archive.
#
# ca-certificates   — Root certificate authorities trusted by the system.
#                     Required for HTTPS connections to work correctly (e.g.
#                     downloading Miniconda, Telegram API calls).
#
# sudo              — Allows the deploy user to run specific commands as root
#                     when needed, without giving full root access.
#
# logrotate         — Automatically rotates, compresses, and deletes old log
#                     files. Without this, log files grow indefinitely and can
#                     fill the disk.
#
# htop              — Interactive process viewer. The first thing you'll want
#                     when SSHing in to check if IB Gateway or your strategy
#                     is consuming unexpected CPU/memory.
#
# tmux              — Terminal multiplexer. Lets you run multiple terminal
#                     sessions within a single SSH connection, and keeps them
#                     alive if your SSH connection drops. Useful for manual
#                     debugging sessions.
#
# openjdk-17-jre-headless — Java runtime required by IB Gateway. The
#                     "headless" variant excludes graphical libraries (AWT,
#                     Swing) that we don't need, reducing the footprint.
#                     IB Gateway itself still requires a display to start
#                     (even in "headless" mode), which is why we also install
#                     Xvfb below.
#
# xvfb              — X Virtual Framebuffer. Creates a virtual display in
#                     memory without any physical screen. IB Gateway's startup
#                     sequence uses Java's GUI libraries to initialize, even
#                     when running without a visible window. Xvfb satisfies
#                     that requirement without a real monitor.

log "Installing minimal required packages"
apt install -y \
    ufw \
    fail2ban \
    unattended-upgrades \
    curl \
    wget \
    git \
    bzip2 \
    ca-certificates \
    sudo \
    logrotate \
    htop \
    tmux \
    openjdk-17-jre-headless \
    xvfb


# =============================================================================
# STEP 3 — CREATE A NON-ROOT DEPLOY USER
# =============================================================================
#
# Running trading software as root is a serious security mistake. If any
# process is compromised (a bug in ib_insync, a malicious package, etc.),
# an attacker running as root can do anything to the system: install backdoors,
# exfiltrate files, pivot to other systems. Running as an unprivileged user
# limits the blast radius of any compromise to that user's home directory.
#
# useradd -m        — creates the user and their home directory (/home/deploy)
# useradd -s /bin/bash — sets bash as the login shell
# usermod -aG sudo  — adds the user to the sudo group, giving them the
#                     ability to run commands as root with "sudo" when needed
#                     for maintenance. The -a flag means "append" (don't
#                     remove from other groups).
#
# The SSH key setup below deserves careful attention:
#
# ~/.ssh/            — the directory that SSH looks in for authorized keys.
#                     Must be owned by the user and have permissions 700
#                     (read/write/execute for owner only). SSH refuses to
#                     use keys from directories with looser permissions as a
#                     security measure.
#
# authorized_keys    — the file containing public keys allowed to log in as
#                     this user. Each line is one public key. Must have
#                     permissions 600 (read/write for owner only). Again,
#                     SSH enforces this strictly.
#
# chown -R           — sets ownership of the entire .ssh directory recursively
#                     to the deploy user. Since we're running as root, files
#                     we create are owned by root by default — we must
#                     explicitly transfer ownership.

log "Creating deploy user: $NEW_USER"

# Check if user already exists to make the script idempotent (safe to re-run)
if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists, skipping creation"
else
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
fi

mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
echo "$YOUR_PUBLIC_KEY" > /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh


# =============================================================================
# STEP 4 — SSH HARDENING
# =============================================================================
#
# The SSH daemon configuration controls how remote logins work. The default
# Debian configuration is reasonable but not optimal for a server where you
# want to minimize attack surface. We rewrite the entire config file to ensure
# only our desired settings are active (rather than commenting/uncommenting
# individual lines, which can leave surprising defaults in place).
#
# We first back up the original so it can be restored if something goes wrong.
#
# Key settings explained:
#
# Port $SSH_PORT           — listen on our custom port instead of 22.
#                            Eliminates the vast majority of automated scanning
#                            noise, which only probes port 22.
#
# Protocol 2               — only allow SSH protocol version 2. Version 1 has
#                            known cryptographic weaknesses and has been
#                            deprecated for years.
#
# PermitRootLogin no       — disable direct root login entirely. Even with
#                            key-only auth, there's no reason to expose the
#                            root account directly. Any admin tasks can be done
#                            by the deploy user with sudo.
#
# PasswordAuthentication no — disable password-based login. Only SSH key
#                            authentication is allowed. This is the single most
#                            important SSH hardening step — passwords can be
#                            brute-forced; private keys cannot (in any
#                            practical sense).
#
# PubkeyAuthentication yes — explicitly enable public key authentication,
#                            which is the only method we want to allow.
#
# ChallengeResponseAuthentication no — disables PAM-based challenge/response
#                            (e.g. one-time passwords). Not needed here.
#
# X11Forwarding no         — disables X11 (graphical) forwarding over SSH.
#                            We have no GUI, so this is just attack surface.
#
# AllowAgentForwarding no  — disables SSH agent forwarding. If an attacker
#                            compromises the server, they cannot use your
#                            local SSH agent to pivot to other systems.
#
# AllowTcpForwarding no    — disables TCP port forwarding through SSH tunnels.
#                            Reduces what an attacker could do with an SSH
#                            session.
#
# LoginGraceTime 20        — give a connecting client only 20 seconds to
#                            authenticate before disconnecting. Reduces the
#                            window for slow brute-force attempts.
#
# ClientAliveInterval 300  — send a keepalive to the client every 300 seconds
#                            (5 minutes). If the client doesn't respond after
#                            ClientAliveCountMax attempts, disconnect. This
#                            cleans up stale SSH sessions (e.g. from a dropped
#                            laptop connection) that would otherwise linger
#                            indefinitely.
#
# MaxAuthTries 3           — allow only 3 authentication attempts per
#                            connection before disconnecting. Limits
#                            per-connection brute force attempts.
#
# AllowUsers $NEW_USER     — whitelist only our deploy user. Even if someone
#                            creates another user account somehow, they cannot
#                            SSH in.
#
# After writing the config, we restart the SSH daemon to apply the changes.
# Note: we do NOT disconnect the current root session — that stays open until
# we explicitly close it. This is intentional: if the new config has an error
# and locks us out, we still have the current session to fix it.

log "Hardening SSH configuration"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp $SSHD_CONFIG ${SSHD_CONFIG}.bak

cat > $SSHD_CONFIG << EOF
# Hardened SSH configuration — generated by setup_vps.sh

Port $SSH_PORT
Protocol 2

# Disable root login and password authentication
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
ChallengeResponseAuthentication no
UsePAM no

# Reduce attack surface — disable unused features
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PrintMotd no
AcceptEnv LANG LC_*

# Timeout and connection limits
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
MaxSessions 3

# Whitelist only the deploy user
AllowUsers $NEW_USER
EOF

systemctl restart sshd


# =============================================================================
# STEP 5 — FIREWALL: ALLOW ONLY WHAT IS NECESSARY
# =============================================================================
#
# UFW (Uncomplicated Firewall) sits in front of all network connections and
# blocks anything we haven't explicitly permitted. The philosophy here is
# "default deny" — block everything, then whitelist only what we need.
#
# Our application's network topology is important to understand:
#
#   INBOUND connections (things connecting TO our server):
#     - Only SSH from our laptop. That's it. Nothing else.
#
#   OUTBOUND connections (things our server connects TO):
#     - IBKR's servers (IB Gateway connects out to IBKR)
#     - Telegram's API servers (our bot calls api.telegram.org)
#     - apt servers (for updates)
#     - Conda/PyPI servers (for package installs)
#
# Because Telegram and IBKR are outbound connections that our server
# initiates, they don't require any inbound firewall rules. The firewall
# automatically allows return traffic for outbound connections we initiate
# (this is called "stateful" packet inspection — the firewall tracks
# connection state).
#
# ufw default deny incoming  — block all inbound traffic by default
# ufw default allow outgoing — allow all outbound traffic by default
# ufw allow ${SSH_PORT}/tcp  — punch one hole for SSH on our custom port
# ufw --force enable         — activate the firewall. --force skips the
#                              interactive confirmation prompt.
#
# After enabling, we print the status so you can verify in the script output
# that only the intended rule is active.

log "Configuring firewall — default deny inbound, SSH only"

ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment "SSH access"
ufw --force enable

ufw status verbose


# =============================================================================
# STEP 6 — FAIL2BAN: AUTOMATIC IP BANNING
# =============================================================================
#
# Even with key-only SSH auth (which makes brute-forcing theoretically
# impossible), bots will still hammer port 2222 continuously, filling your
# logs with noise and consuming small amounts of resources. Fail2ban watches
# your SSH logs and automatically adds firewall rules to ban IPs that
# repeatedly fail to authenticate.
#
# We write a /etc/fail2ban/jail.local file (which overrides the defaults in
# jail.conf — always edit .local files, never the .conf originals, so that
# package updates don't overwrite your customizations).
#
# [DEFAULT] section applies to all jails (monitored services):
#
#   bantime = 1h        — ban offending IPs for 1 hour. Could be made longer
#                         (24h, permanent) but 1h is sufficient for our needs
#                         and avoids the edge case of accidentally banning
#                         yourself.
#
#   findtime = 10m      — the window within which maxretry failures must occur
#                         to trigger a ban. 3 failures spread over a day would
#                         not trigger a ban; 3 failures within 10 minutes would.
#
#   maxretry = 3        — number of failures within findtime before banning.
#
#   backend = systemd   — tells fail2ban to read logs from systemd's journal
#                         rather than from log files, which is the modern
#                         approach on Debian systems using systemd.
#
# [sshd] section configures the SSH-specific jail:
#
#   enabled = true      — activate this jail
#   port = $SSH_PORT    — tell fail2ban to watch our custom SSH port, not
#                         the default 22

log "Configuring fail2ban"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd

[sshd]
enabled = true
port    = $SSH_PORT
EOF

systemctl enable fail2ban
systemctl restart fail2ban


# =============================================================================
# STEP 7 — AUTOMATIC SECURITY UPDATES
# =============================================================================
#
# A server you don't actively maintain will accumulate unpatched
# vulnerabilities over time. The unattended-upgrades package handles security
# patches automatically in the background, without requiring manual
# intervention or reboots.
#
# We configure two files:
#
# 50unattended-upgrades — controls WHAT gets upgraded:
#
#   Allowed-Origins      — we restrict automatic upgrades to security updates
#                          only (the "-security" suite). Regular package
#                          updates are deliberately excluded because they can
#                          change behavior in unexpected ways. Security patches
#                          fix vulnerabilities without changing functionality.
#
#   AutoFixInterruptedDpkg — if a previous upgrade was interrupted (e.g. by
#                          a power failure), automatically fix the package
#                          manager state before proceeding.
#
#   MinimalSteps         — apply upgrades in small chunks so that if something
#                          fails, it fails cleanly rather than leaving the
#                          system in a partially-upgraded state.
#
#   Remove-Unused-Dependencies — clean up orphaned packages after upgrades,
#                          keeping the system footprint small.
#
#   Automatic-Reboot "false" — CRITICAL for a trading server. Some kernel
#                          security updates require a reboot to take effect.
#                          We disable automatic reboots because an unexpected
#                          reboot at 3:30pm on a trading day would be
#                          disastrous. You'll occasionally see a "reboot
#                          required" notice when you SSH in — schedule that
#                          for a weekend.
#
# 20auto-upgrades — controls WHEN the upgrade process runs:
#
#   Update-Package-Lists "1" — refresh the package index daily
#   Unattended-Upgrade "1"   — run the upgrade process daily

log "Enabling automatic security updates"

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF


# =============================================================================
# STEP 8 — INSTALL MINICONDA
# =============================================================================
#
# We use Miniconda (a minimal Conda distribution) rather than the system
# Python for several reasons:
#
#   1. ISOLATION — system Python is used by Debian's package manager and
#      system tools. Installing packages into it with pip can break system
#      tools in subtle ways. Conda creates a completely separate Python
#      installation.
#
#   2. ENVIRONMENT CONTROL — conda environments let you pin exact package
#      versions and recreate the environment exactly. "It works on my laptop"
#      becomes reproducible.
#
#   3. NO ROOT REQUIRED — Miniconda installs entirely into the user's home
#      directory. No system files are touched, consistent with our principle
#      of minimal root footprint.
#
# We download the official Miniconda installer script from Anaconda's servers,
# run it in batch mode (-b flag = no prompts, no modifying .bashrc
# interactively), and install into /home/deploy/miniconda3.
#
# We then manually add conda to the deploy user's PATH in .bashrc so it's
# available in every future login shell.
#
# The "sudo -u $NEW_USER bash -c '...'" pattern runs commands as the deploy
# user rather than root. This is important — Miniconda must be installed as
# the user who will use it, not as root.

log "Installing Miniconda for user: $NEW_USER"

MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
MINICONDA_INSTALLER="/tmp/miniconda.sh"

wget -q $MINICONDA_URL -O $MINICONDA_INSTALLER
chmod +x $MINICONDA_INSTALLER

# Run the installer as the deploy user, not as root
# -b = batch mode (no interactive prompts)
# -p = installation prefix (where to install)
sudo -u $NEW_USER bash $MINICONDA_INSTALLER -b -p /home/$NEW_USER/miniconda3
rm $MINICONDA_INSTALLER

# Initialize conda for the deploy user's bash shell and add to PATH
# This writes the conda initialization block into ~/.bashrc so that
# "conda" is available every time the deploy user opens a shell
sudo -u $NEW_USER bash -c "
    /home/$NEW_USER/miniconda3/bin/conda init bash
    echo 'export PATH=/home/$NEW_USER/miniconda3/bin:\$PATH' >> /home/$NEW_USER/.bashrc
"


# =============================================================================
# STEP 9 — CREATE CONDA ENVIRONMENT WITH TRADING PACKAGES
# =============================================================================
#
# We create a named conda environment called "trading" with a pinned Python
# version (3.11). Using a named environment (rather than installing into the
# base environment) means:
#
#   - Your trading dependencies are isolated from anything else you might
#     install later
#   - You can recreate or update the environment without affecting the base
#   - The systemd service can point to the exact Python binary in this
#     environment: /home/deploy/miniconda3/envs/trading/bin/python
#
# Package descriptions:
#
#   ib_insync       — the standard Python library for the IBKR TWS/Gateway API.
#                     Wraps the low-level IBKR API in a clean asyncio interface.
#                     Handles connection management, order submission, market
#                     data subscriptions, and account queries.
#
#   python-telegram-bot — official async Telegram bot library. Handles
#                     webhook/polling setup, update routing, and provides a
#                     clean handler-based architecture for commands.
#
#   pandas          — DataFrame library for data manipulation. Useful for
#                     processing historical trade data, computing P/L
#                     statistics, and preparing features.
#
#   numpy           — numerical computing library. Underlying dependency for
#                     pandas and useful for any numerical calculations in your
#                     strategy logic.
#
#   requests        — HTTP library for making API calls. Useful for fetching
#                     data from Polygon.io or other REST APIs.
#
#   python-dotenv   — loads environment variables from a .env file into the
#                     process environment. This is how secrets (Telegram token,
#                     etc.) are passed to the application without hardcoding
#                     them in source code or exposing them in environment
#                     variable lists.
#
#   schedule        — simple Python job scheduling library. Allows you to
#                     write "run this function every day at 3:28pm ET" in
#                     pure Python without cron syntax.

log "Creating conda environment: trading"

CONDA="/home/$NEW_USER/miniconda3/bin/conda"

sudo -u $NEW_USER $CONDA create -y -n trading python=3.11

sudo -u $NEW_USER $CONDA run -n trading pip install \
    ib_insync \
    python-telegram-bot \
    pandas \
    numpy \
    requests \
    python-dotenv \
    schedule


# =============================================================================
# STEP 10 — PROJECT DIRECTORY STRUCTURE
# =============================================================================
#
# A consistent directory layout makes the project easy to navigate, back up,
# and reason about. We create the following structure:
#
#   ~/trading/
#   ├── config/         — configuration files and secrets (never commit to git)
#   ├── data/           — SQLite database, any local data files
#   ├── logs/           — application log files (rotated by logrotate)
#   └── scripts/        — Python scripts for bot, strategy, utilities
#
# The secrets.env.template file documents what secrets are required without
# containing actual values. The workflow is:
#   1. The template is committed to git (documents required variables)
#   2. You copy it to secrets.env and fill in real values on the server
#   3. secrets.env is in .gitignore and never committed
#
# This pattern means you can fully document your configuration requirements
# in version control without ever exposing actual credentials.

log "Creating project directory structure"

sudo -u $NEW_USER mkdir -p /home/$NEW_USER/trading/{logs,data,scripts,config}

cat > /home/$NEW_USER/trading/config/secrets.env.template << 'EOF'
# Trading bot secrets — copy this file to secrets.env and fill in values
# NEVER commit secrets.env to git
#
# TELEGRAM_BOT_TOKEN
#   Get this from @BotFather on Telegram:
#   1. Open Telegram and search for @BotFather
#   2. Send /newbot and follow the prompts
#   3. BotFather will give you a token like: 110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw
#
# TELEGRAM_ALLOWED_USER_ID
#   Your personal Telegram user ID (a number, not your username).
#   Get it by messaging @userinfobot on Telegram.
#   This is the ONLY user ID that can control your bot.
#
# IBKR_HOST / IBKR_PORT
#   IB Gateway listens on localhost. Port 4001 is the default for live
#   trading; 4002 is the default for paper trading.
#
# IBKR_CLIENT_ID
#   An arbitrary integer identifying this API client connection to IB
#   Gateway. If you ever run multiple scripts simultaneously, each needs
#   a unique client ID.

TELEGRAM_BOT_TOKEN=your_bot_token_here
TELEGRAM_ALLOWED_USER_ID=your_telegram_user_id_here
IBKR_HOST=127.0.0.1
IBKR_PORT=4001
IBKR_CLIENT_ID=1
EOF

chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/trading


# =============================================================================
# STEP 11 — TELEGRAM BOT SKELETON
# =============================================================================
#
# This is the foundation of your bidirectional control interface. The bot
# runs as a persistent process alongside your strategy, communicating via
# a shared SQLite database (the state DB created in Step 12).
#
# ARCHITECTURE
# ------------
# The bot uses python-telegram-bot's polling mechanism: it repeatedly asks
# Telegram's servers "any new messages for me?" and processes them as they
# arrive. This requires no inbound firewall ports — all communication is
# outbound HTTPS from your server to api.telegram.org.
#
# SECURITY MODEL
# --------------
# The ALLOWED_USER_ID check in every handler is critical. A Telegram bot
# is publicly accessible — anyone who finds your bot's username can send
# it messages. Without the user ID check, anyone could trigger your kill
# switch or read your positions. The user ID check ensures only you
# (identified by your unique Telegram user ID, not your username which
# can be changed) can control the bot.
#
# STATE SHARING
# -------------
# The bot and your strategy script share state via SQLite. The strategy
# writes to the database (updating P/L, position info, order counts) and
# reads from it (checking kill switch, paused flag). The bot reads from it
# (for status/pnl/positions commands) and writes to it (for kill/pause/
# resume commands). SQLite handles concurrent access safely for our
# single-writer-at-a-time use case.
#
# COMMANDS
# --------
# /start     — initial greeting, lists available commands
# /status    — overview: kill switch state, paused state, orders today, P/L
# /pnl       — today's P/L and last fill details
# /positions — current open positions
# /kill      — activate kill switch: blocks all new orders
# /pause     — pause today's entry without activating full kill switch
# /resume    — clear kill switch and paused flag, resume normal operation
#
# Adding new commands later is straightforward: write an async handler
# function following the same pattern, then register it with add_handler().

log "Writing Telegram bot skeleton"

cat > /home/$NEW_USER/trading/scripts/bot.py << 'PYEOF'
"""
Telegram bot — bidirectional control and monitoring interface.

Runs as a persistent systemd service. Shares state with the strategy
script via a SQLite database at ~/trading/data/state.db.

To add a new command:
  1. Write an async handler function (see examples below)
  2. Add app.add_handler(CommandHandler("yourcommand", your_function))
     in the main() function
"""

import os
import sqlite3
import logging
from pathlib import Path
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# load_dotenv reads key=value pairs from secrets.env into os.environ.
# The path is resolved relative to this script's location so it works
# regardless of what directory the script is launched from.

load_dotenv(Path(__file__).parent.parent / "config/secrets.env")

TOKEN           = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED_USER_ID = int(os.environ["TELEGRAM_ALLOWED_USER_ID"])
DB_PATH         = Path(__file__).parent.parent / "data/state.db"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# We log to both a file (for persistent history) and stdout (captured by
# systemd's journal, viewable with: journalctl -u trading-bot -f)

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    level=logging.INFO,
    handlers=[
        logging.FileHandler(Path(__file__).parent.parent / "logs/bot.log"),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Authorization guard
# ---------------------------------------------------------------------------
# Every command handler calls this first. Returns True only if the message
# came from your Telegram account. Silently ignores all other users —
# giving no response is better than acknowledging the bot exists to
# unauthorized users.

def authorized(update: Update) -> bool:
    return update.effective_user.id == ALLOWED_USER_ID

# ---------------------------------------------------------------------------
# SQLite state helpers
# ---------------------------------------------------------------------------
# read_state() returns the entire state table as a dict {key: value}.
# set_state() writes a single key-value pair.
#
# We open and close a fresh connection on each call rather than keeping a
# persistent connection. This is slightly less efficient but avoids issues
# with SQLite's threading model when the bot and strategy both access the
# DB concurrently.

def read_state() -> dict:
    """Read all state key-value pairs from the shared database."""
    try:
        conn = sqlite3.connect(DB_PATH)
        rows = conn.execute("SELECT key, value FROM state").fetchall()
        conn.close()
        return dict(rows)
    except Exception as e:
        log.error("Failed to read state: %s", e)
        return {}

def set_state(key: str, value: str):
    """Write a single key-value pair to the shared database."""
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)",
            (key, value)
        )
        conn.commit()
        conn.close()
    except Exception as e:
        log.error("Failed to write state key=%s: %s", key, e)

# ---------------------------------------------------------------------------
# Command handlers
# ---------------------------------------------------------------------------
# Each handler is an async function that receives an Update (the incoming
# message) and a Context (bot context). The pattern is always:
#   1. Auth check
#   2. Read state / perform action
#   3. Reply to the user

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Greet the user and list available commands."""
    if not authorized(update): return
    await update.message.reply_text(
        "Trading system online.\n\n"
        "Available commands:\n"
        "/status   — system overview\n"
        "/pnl      — today's P&L\n"
        "/positions — open positions\n"
        "/pause    — skip today's entry\n"
        "/resume   — re-enable after pause or kill\n"
        "/kill     — emergency stop, block all new orders"
    )

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """System health overview: kill switch, paused, orders today, P/L."""
    if not authorized(update): return
    s = read_state()
    kill   = s.get("kill_switch", "0") == "1"
    paused = s.get("paused",      "0") == "1"
    await update.message.reply_text(
        f"System status\n"
        f"─────────────────────\n"
        f"Kill switch  : {'🔴 ACTIVE' if kill else '🟢 off'}\n"
        f"Paused       : {'⏸  yes'   if paused else '▶️  no'}\n"
        f"Orders today : {s.get('orders_today', '0')}\n"
        f"Daily P/L    : ${float(s.get('daily_pnl', 0)):,.0f}\n"
        f"Last update  : {s.get('last_update', 'n/a')}"
    )

async def pnl(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Today's P/L and last fill details."""
    if not authorized(update): return
    s = read_state()
    await update.message.reply_text(
        f"P/L today  : ${float(s.get('daily_pnl', 0)):,.0f}\n"
        f"Last fill  : {s.get('last_fill', 'none')}\n"
        f"Last credit: {s.get('last_credit', 'n/a')}"
    )

async def positions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Current open positions."""
    if not authorized(update): return
    s = read_state()
    pos = s.get("open_positions", "No open positions")
    await update.message.reply_text(f"Open positions:\n{pos}")

async def kill(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Activate kill switch — blocks all new order submissions."""
    if not authorized(update): return
    set_state("kill_switch", "1")
    log.warning(
        "Kill switch activated via Telegram by user_id=%s",
        update.effective_user.id
    )
    await update.message.reply_text(
        "🛑 Kill switch activated.\n"
        "All new orders are blocked.\n"
        "Use /resume to re-enable."
    )

async def pause(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Pause — skip today's entry without a full kill switch."""
    if not authorized(update): return
    set_state("paused", "1")
    log.info("Strategy paused via Telegram")
    await update.message.reply_text(
        "⏸ Strategy paused.\n"
        "Today's entry will be skipped.\n"
        "Use /resume to re-enable."
    )

async def resume(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Clear kill switch and paused flag. Resume normal operation."""
    if not authorized(update): return
    set_state("kill_switch", "0")
    set_state("paused", "0")
    log.info("Strategy resumed via Telegram")
    await update.message.reply_text("✅ System resumed. Kill switch cleared.")

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
# Application.builder().token(TOKEN).build() creates the bot application.
# Each add_handler() call registers a command: when a user sends /status,
# the status() function is called.
# run_polling() starts the event loop — the bot will run until interrupted.

def main():
    app = Application.builder().token(TOKEN).build()

    app.add_handler(CommandHandler("start",     start))
    app.add_handler(CommandHandler("status",    status))
    app.add_handler(CommandHandler("pnl",       pnl))
    app.add_handler(CommandHandler("positions", positions))
    app.add_handler(CommandHandler("kill",      kill))
    app.add_handler(CommandHandler("pause",     pause))
    app.add_handler(CommandHandler("resume",    resume))

    log.info("Telegram bot starting, polling for updates")
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
PYEOF

chown $NEW_USER:$NEW_USER /home/$NEW_USER/trading/scripts/bot.py


# =============================================================================
# STEP 12 — STATE DATABASE INITIALIZER
# =============================================================================
#
# The SQLite database is the communication backbone between the bot and the
# strategy. It stores the current state of the system in a simple key-value
# table that both processes can read and write.
#
# WHY SQLITE?
# -----------
# For our use case (one write per trade, occasional reads) SQLite is ideal:
#   - No separate server process to manage
#   - The database is just a file in ~/trading/data/
#   - Handles concurrent access from bot + strategy safely for our workload
#   - Trivial to back up (just copy the file)
#   - Survives restarts (unlike in-memory state)
#
# That last point is critical. If your strategy script crashes and restarts,
# it must not reset the "orders_today" counter to 0. If it did, a script
# that crashes and restarts 10 times could submit 10 orders. By reading
# orders_today from SQLite, the restarted script inherits the correct count.
#
# SCHEMA
# ------
# A single "state" table with two columns:
#   key   TEXT PRIMARY KEY — the state variable name
#   value TEXT             — its current value as a string
#
# All values are stored as strings and cast to appropriate types when read.
# This keeps the schema trivially simple.
#
# DEFAULT VALUES
# --------------
# kill_switch    "0" — 0 = inactive, 1 = active
# paused         "0" — 0 = running, 1 = paused
# orders_today   "0" — count of orders submitted today (reset each morning)
# daily_pnl      "0" — running P/L for today in dollars
# last_fill      "none" — description of the most recent fill
# last_credit    "n/a"  — credit received on last spread entry
# open_positions "none" — human-readable current position description
# last_update    "never" — timestamp of last strategy heartbeat

log "Writing state database initializer"

cat > /home/$NEW_USER/trading/scripts/init_db.py << 'PYEOF'
"""
Initialize the shared SQLite state database.

Run this once after first deployment:
    conda run -n trading python ~/trading/scripts/init_db.py

Safe to re-run — uses INSERT OR IGNORE so existing values are preserved.
"""

import sqlite3
from pathlib import Path
from datetime import datetime

DB_PATH = Path(__file__).parent.parent / "data/state.db"
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

conn = sqlite3.connect(DB_PATH)

# Create the state table if it doesn't already exist.
# PRIMARY KEY on 'key' enforces uniqueness and enables INSERT OR REPLACE
# as an upsert operation (used throughout the codebase for writes).
conn.execute("""
    CREATE TABLE IF NOT EXISTS state (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
""")

# Insert default values. INSERT OR IGNORE means existing values are left
# untouched — re-running this script after deployment won't reset live state.
defaults = {
    "kill_switch":      "0",
    "paused":           "0",
    "orders_today":     "0",
    "daily_pnl":        "0.0",
    "last_fill":        "none",
    "last_credit":      "n/a",
    "open_positions":   "none",
    "last_update":      "never",
}
for k, v in defaults.items():
    conn.execute(
        "INSERT OR IGNORE INTO state (key, value) VALUES (?, ?)", (k, v)
    )

conn.commit()
conn.close()
print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] Database initialized at {DB_PATH}")
PYEOF

chown $NEW_USER:$NEW_USER /home/$NEW_USER/trading/scripts/init_db.py


# =============================================================================
# STEP 13 — SYSTEMD SERVICES
# =============================================================================
#
# Systemd is the process manager for modern Linux systems. We create systemd
# service units for the bot and strategy, which gives us:
#
#   - Automatic startup on server reboot
#   - Automatic restart on crash (with configurable delay)
#   - Centralized log aggregation via journald
#   - Simple start/stop/status commands: systemctl start trading-bot
#   - Clean process lifecycle management
#
# This is far superior to screen/tmux sessions for production use because
# those don't survive reboots and require manual intervention to restart
# after crashes.
#
# SERVICE FILE STRUCTURE
# ----------------------
# [Unit]   — metadata and dependencies
# [Service] — how to run the process
# [Install] — when to start it (WantedBy=multi-user.target means "when
#              the system reaches normal multi-user mode on boot")
#
# KEY SERVICE SETTINGS
# --------------------
# User=$NEW_USER        — run as unprivileged deploy user, not root
#
# WorkingDirectory      — the current directory when the script starts.
#                         Path() calls in Python resolve relative to this.
#
# ExecStart             — the exact command to run. We use the full path to
#                         the conda environment's Python binary, bypassing
#                         any PATH issues.
#
# Restart=on-failure    — restart the service if it exits with a non-zero
#                         code (i.e. crashed). Does NOT restart if it exits
#                         cleanly (code 0), which is correct behavior.
#
# RestartSec=10s        — wait 10 seconds before restarting after a crash.
#                         Prevents a tight crash loop from hammering IBKR's
#                         API or Telegram.
#
# SECURITY HARDENING IN SERVICE FILES
# ------------------------------------
# These systemd directives create an additional security layer on top of
# running as an unprivileged user:
#
# NoNewPrivileges=true  — the process cannot gain additional privileges via
#                         setuid binaries or similar mechanisms.
#
# PrivateTmp=true       — the process gets its own isolated /tmp directory,
#                         preventing one service from reading /tmp files
#                         written by another.
#
# ProtectSystem=strict  — the entire filesystem is mounted read-only for
#                         this process, EXCEPT directories explicitly listed
#                         in ReadWritePaths. This means even a compromised
#                         strategy script cannot write to system directories.
#
# ReadWritePaths        — the only directory the process can write to. Our
#                         entire application lives here.
#
# NOTE ON THE STRATEGY SERVICE
# ----------------------------
# The strategy service is created but NOT enabled here. You need to add your
# actual strategy.py script first. Once it's ready:
#   systemctl enable --now trading-strategy

log "Creating systemd service units"

CONDA_PYTHON="/home/$NEW_USER/miniconda3/envs/trading/bin/python"

cat > /etc/systemd/system/trading-bot.service << EOF
[Unit]
Description=Trading System — Telegram Bot
Documentation=https://github.com/you/your-strategy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NEW_USER
WorkingDirectory=/home/$NEW_USER/trading
ExecStart=$CONDA_PYTHON /home/$NEW_USER/trading/scripts/bot.py
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=trading-bot

# Systemd-level security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/$NEW_USER/trading

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/trading-strategy.service << EOF
[Unit]
Description=Trading System — Strategy Runner
Documentation=https://github.com/you/your-strategy
After=network-online.target trading-bot.service
Wants=network-online.target

[Service]
Type=simple
User=$NEW_USER
WorkingDirectory=/home/$NEW_USER/trading
ExecStart=$CONDA_PYTHON /home/$NEW_USER/trading/scripts/strategy.py
Restart=on-failure
RestartSec=30s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=trading-strategy

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/home/$NEW_USER/trading

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to recognize the new service files
systemctl daemon-reload

# Enable bot service to start on boot (but don't start it yet —
# secrets.env needs to be filled in first)
systemctl enable trading-bot.service

# Strategy service: enable manually once strategy.py is in place
# systemctl enable trading-strategy.service


# =============================================================================
# STEP 14 — LOG ROTATION
# =============================================================================
#
# Without log rotation, log files grow indefinitely. A strategy running daily
# for a year will produce substantial log output. logrotate handles this
# automatically by periodically rotating the active log file to a dated
# archive, compressing old archives, and deleting archives older than the
# retention period.
#
# daily         — rotate logs once per day
# rotate 30     — keep 30 days of history before deleting
# compress      — gzip old log files to save disk space
# missingok     — don't error if the log file doesn't exist yet
# notifempty    — don't rotate if the log file is empty
# create 0640   — create the new (empty) log file with these permissions
#                 after rotation: read/write for owner, read for group,
#                 no access for others

log "Configuring log rotation"

cat > /etc/logrotate.d/trading << EOF
/home/$NEW_USER/trading/logs/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 0640 $NEW_USER $NEW_USER
}
EOF


# =============================================================================
# STEP 15 — EMERGENCY KILL SCRIPT
# =============================================================================
#
# This is a last-resort tool for when Telegram is unreachable (e.g. your
# phone dies, Telegram is down, network issues) but you can still SSH in.
#
# It does three things in order:
#   1. Writes a KILL_SWITCH file to /tmp — your strategy script should check
#      for this file's existence on every loop iteration as a belt-and-
#      suspenders fallback to the SQLite kill switch.
#   2. Sets kill_switch=1 in SQLite directly via the sqlite3 CLI tool —
#      updates the shared state database without needing Python.
#   3. Stops the strategy systemd service immediately — the most nuclear
#      option, guaranteed to stop order submission even if the Python
#      code fails to check the kill switch.
#
# Usage (SSH into the server, then):
#   bash ~/trading/kill.sh

log "Writing emergency kill script"

cat > /home/$NEW_USER/trading/kill.sh << 'EOF'
#!/bin/bash
# Emergency kill switch — use when Telegram is unreachable
# Stops order submission via three independent mechanisms

echo "Activating emergency kill switch..."

# Method 1: filesystem sentinel file (checked in strategy loop)
echo "1" > /tmp/KILL_SWITCH
echo "  [1/3] Kill switch file written to /tmp/KILL_SWITCH"

# Method 2: update SQLite state (checked by strategy and bot)
sqlite3 ~/trading/data/state.db \
    "INSERT OR REPLACE INTO state (key, value) VALUES ('kill_switch', '1');"
echo "  [2/3] Kill switch set in SQLite state database"

# Method 3: stop the systemd service entirely
systemctl stop trading-strategy.service 2>/dev/null && \
    echo "  [3/3] trading-strategy service stopped" || \
    echo "  [3/3] Service was not running (already stopped)"

echo ""
echo "Kill switch active. Run 'systemctl start trading-strategy' to restart."
EOF

chmod +x /home/$NEW_USER/trading/kill.sh
chown $NEW_USER:$NEW_USER /home/$NEW_USER/trading/kill.sh


# =============================================================================
# COMPLETE
# =============================================================================

log "Setup complete"

cat << EOF

================================================================
  SETUP COMPLETE — NEXT STEPS
================================================================

  IMPORTANT: Do NOT close this root session until you have
  verified SSH login works on the new port. Test first:

    ssh -p $SSH_PORT $NEW_USER@<your-droplet-ip>

  If that works, you can safely close the root session.
  If it doesn't work, you still have this session to debug.

----------------------------------------------------------------
  1. Fill in your secrets file:

       sudo -u $NEW_USER cp \\
         ~/trading/config/secrets.env.template \\
         ~/trading/config/secrets.env

       sudo -u $NEW_USER nano ~/trading/config/secrets.env

     Get your Telegram bot token from @BotFather.
     Get your Telegram user ID from @userinfobot.

----------------------------------------------------------------
  2. Initialize the state database:

       sudo -u $NEW_USER \\
         /home/$NEW_USER/miniconda3/envs/trading/bin/python \\
         ~/trading/scripts/init_db.py

----------------------------------------------------------------
  3. Start the Telegram bot:

       systemctl start trading-bot
       systemctl status trading-bot

     Then send /start to your bot on Telegram to verify.

----------------------------------------------------------------
  4. Add your strategy script:

       Place it at: ~/trading/scripts/strategy.py
       Then enable: systemctl enable --now trading-strategy

----------------------------------------------------------------
  5. Take a DigitalOcean snapshot NOW as your clean baseline.
     DO Dashboard → Your Droplet → Snapshots → Take Snapshot

================================================================
EOF