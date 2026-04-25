#!/bin/bash
# =============================================================================
# SCRIPT 1 OF 2 — BASE SETUP
# Run this at droplet creation via DO "User Data" field, or manually as root.
#
# What it does:
#   - Updates the system
#   - Creates the deploy user with your SSH public key
#   - Installs all required packages (Java, Xvfb, conda, trading packages)
#   - Creates project directory structure
#
# What it does NOT do:
#   - Does not change SSH port (stays on 22 so you can still get in)
#   - Does not disable password auth
#   - Does not enable firewall
#
# After this script completes:
#   1. Verify you can SSH in as deploy on port 22:
#      ssh -p 22 -i ~/.ssh/trading_vps deploy@<your-droplet-ip>
#   2. If that works, run setup_harden.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION — edit these before running
# =============================================================================

NEW_USER="deploy"

# Paste your public key here — get it with: cat ~/.ssh/trading_vps.pub
YOUR_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJHXBw5vt+qrJUu8I8Z+d5WVrBUiBu/Rc8OCOxjG7Oyy trading-vps"

# =============================================================================
# HELPERS
# =============================================================================

log()  { echo -e "\n\033[1;32m>>> $1\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $1\033[0m"; }

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

# =============================================================================
# 1. SYSTEM UPDATE
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
export UCF_FORCE_CONFFOLD=1

log "Updating system packages"
apt update -y
apt upgrade -y -o Dpkg::Options::="--force-confold"
# apt upgrade -y
apt autoremove -y

# =============================================================================
# 2. INSTALL PACKAGES
# =============================================================================

log "Installing required packages"


apt install -y \
    curl \
    wget \
    git \
    bzip2 \
    ca-certificates \
    sudo \
    logrotate \
    htop \
    tmux \
    ufw \
    fail2ban \
    unattended-upgrades \
    openjdk-21-jre-headless \
    xvfb \
    sqlite3

# =============================================================================
# 3. CREATE DEPLOY USER
# =============================================================================

log "Creating user: $NEW_USER"

if id "$NEW_USER" &>/dev/null; then
    warn "User $NEW_USER already exists, skipping"
else
    useradd -m -s /bin/bash "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    log "User $NEW_USER created"
fi

# Set up SSH key authentication for deploy user
mkdir -p /home/$NEW_USER/.ssh
chmod 700 /home/$NEW_USER/.ssh
echo "$YOUR_PUBLIC_KEY" > /home/$NEW_USER/.ssh/authorized_keys
chmod 600 /home/$NEW_USER/.ssh/authorized_keys
chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/.ssh

log "SSH key installed for $NEW_USER"

# =============================================================================
# 4. INSTALL MINIFORGE
# =============================================================================
# We use Miniforge instead of Miniconda — it uses the community conda-forge
# channel by default, avoiding Anaconda's Terms of Service requirements
# that affect automated/server use.

log "Installing Miniforge"

MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh"
MINIFORGE_INSTALLER="/tmp/miniforge.sh"

wget -q $MINIFORGE_URL -O $MINIFORGE_INSTALLER
chmod +x $MINIFORGE_INSTALLER

# Install as deploy user into their home directory
su - $NEW_USER -c "bash $MINIFORGE_INSTALLER -b -p /home/$NEW_USER/miniforge3"
rm $MINIFORGE_INSTALLER

# Add to deploy user's PATH
su - $NEW_USER -c "echo 'export PATH=/home/$NEW_USER/miniforge3/bin:\$PATH' >> /home/$NEW_USER/.bashrc"

log "Miniforge installed"

# =============================================================================
# 5. CREATE CONDA ENVIRONMENT
# =============================================================================

log "Creating conda trading environment (python 3.11)"

CONDA="/home/$NEW_USER/miniforge3/bin/conda"

su - $NEW_USER -c "$CONDA create -y -n trading python=3.11"

log "Installing Python packages"

su - $NEW_USER -c "$CONDA run -n trading pip install \
    ib_insync \
    python-telegram-bot \
    pandas \
    numpy \
    requests \
    python-dotenv \
    schedule"

# =============================================================================
# 6. VERIFY PACKAGES
# =============================================================================

log "Verifying package installation"

su - $NEW_USER -c "/home/$NEW_USER/miniforge3/bin/conda run -n trading python -c \
    'import ib_insync; import telegram; import pandas; print(\"All packages OK\")'"

# =============================================================================
# 7. PROJECT DIRECTORY STRUCTURE
# =============================================================================

log "Creating project directories"

su - $NEW_USER -c "mkdir -p /home/$NEW_USER/trading/{logs,data,scripts,config}"

# Secrets template
cat > /home/$NEW_USER/trading/config/secrets.env.template << 'EOF'
# Copy to secrets.env and fill in values — never commit secrets.env to git
#
# TELEGRAM_BOT_TOKEN: get from @BotFather on Telegram
# TELEGRAM_ALLOWED_USER_ID: get from @userinfobot on Telegram
# IBKR_PORT: 4001 for live trading, 4002 for paper trading

TELEGRAM_BOT_TOKEN=your_bot_token_here
TELEGRAM_ALLOWED_USER_ID=your_telegram_user_id_here
IBKR_HOST=127.0.0.1
IBKR_PORT=4001
IBKR_CLIENT_ID=1
EOF

chown -R $NEW_USER:$NEW_USER /home/$NEW_USER/trading

# =============================================================================
# 8. STATE DATABASE INITIALIZER
# =============================================================================

cat > /home/$NEW_USER/trading/scripts/init_db.py << 'PYEOF'
"""
Initialize shared SQLite state database.
Run once after deployment:
    conda run -n trading python ~/trading/scripts/init_db.py
"""
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).parent.parent / "data/state.db"
DB_PATH.parent.mkdir(parents=True, exist_ok=True)

conn = sqlite3.connect(DB_PATH)
conn.execute("""
    CREATE TABLE IF NOT EXISTS state (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    )
""")

defaults = {
    "kill_switch":    "0",
    "paused":         "0",
    "orders_today":   "0",
    "daily_pnl":      "0.0",
    "last_fill":      "none",
    "last_credit":    "n/a",
    "open_positions": "none",
    "last_update":    "never",
}
for k, v in defaults.items():
    conn.execute(
        "INSERT OR IGNORE INTO state (key, value) VALUES (?, ?)", (k, v)
    )
conn.commit()
conn.close()
print(f"Database initialized at {DB_PATH}")
PYEOF

chown $NEW_USER:$NEW_USER /home/$NEW_USER/trading/scripts/init_db.py

# =============================================================================
# 9. TELEGRAM BOT SKELETON
# =============================================================================

cat > /home/$NEW_USER/trading/scripts/bot.py << 'PYEOF'
"""
Telegram bot — bidirectional control and monitoring interface.
Shares state with strategy via SQLite at ~/trading/data/state.db.
"""

import os
import sqlite3
import logging
from pathlib import Path
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes

load_dotenv(Path(__file__).parent.parent / "config/secrets.env")

TOKEN           = os.environ["TELEGRAM_BOT_TOKEN"]
ALLOWED_USER_ID = int(os.environ["TELEGRAM_ALLOWED_USER_ID"])
DB_PATH         = Path(__file__).parent.parent / "data/state.db"

logging.basicConfig(
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
    level=logging.INFO,
    handlers=[
        logging.FileHandler(Path(__file__).parent.parent / "logs/bot.log"),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger(__name__)

def authorized(update: Update) -> bool:
    return update.effective_user.id == ALLOWED_USER_ID

def read_state() -> dict:
    try:
        conn = sqlite3.connect(DB_PATH)
        rows = conn.execute("SELECT key, value FROM state").fetchall()
        conn.close()
        return dict(rows)
    except Exception as e:
        log.error("Failed to read state: %s", e)
        return {}

def set_state(key: str, value: str):
    try:
        conn = sqlite3.connect(DB_PATH)
        conn.execute(
            "INSERT OR REPLACE INTO state (key, value) VALUES (?, ?)",
            (key, value)
        )
        conn.commit()
        conn.close()
    except Exception as e:
        log.error("Failed to write state: %s", e)

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update): return
    await update.message.reply_text(
        "Trading system online.\n\n"
        "/status   — system overview\n"
        "/pnl      — today's P&L\n"
        "/positions — open positions\n"
        "/pause    — skip today's entry\n"
        "/resume   — re-enable\n"
        "/kill     — emergency stop"
    )

async def status(update: Update, context: ContextTypes.DEFAULT_TYPE):
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
    if not authorized(update): return
    s = read_state()
    await update.message.reply_text(
        f"P/L today  : ${float(s.get('daily_pnl', 0)):,.0f}\n"
        f"Last fill  : {s.get('last_fill', 'none')}\n"
        f"Last credit: {s.get('last_credit', 'n/a')}"
    )

async def positions(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update): return
    s = read_state()
    await update.message.reply_text(
        f"Open positions:\n{s.get('open_positions', 'none')}"
    )

async def kill(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update): return
    set_state("kill_switch", "1")
    log.warning("Kill switch activated via Telegram by user_id=%s",
                update.effective_user.id)
    await update.message.reply_text(
        "🛑 Kill switch activated.\n"
        "All new orders blocked.\n"
        "Use /resume to re-enable."
    )

async def pause(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update): return
    set_state("paused", "1")
    await update.message.reply_text(
        "⏸ Strategy paused.\n"
        "Today's entry will be skipped.\n"
        "Use /resume to re-enable."
    )

async def resume(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not authorized(update): return
    set_state("kill_switch", "0")
    set_state("paused", "0")
    await update.message.reply_text("✅ System resumed. Kill switch cleared.")

def main():
    app = Application.builder().token(TOKEN).build()
    app.add_handler(CommandHandler("start",     start))
    app.add_handler(CommandHandler("status",    status))
    app.add_handler(CommandHandler("pnl",       pnl))
    app.add_handler(CommandHandler("positions", positions))
    app.add_handler(CommandHandler("kill",      kill))
    app.add_handler(CommandHandler("pause",     pause))
    app.add_handler(CommandHandler("resume",    resume))
    log.info("Telegram bot starting")
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
PYEOF

chown $NEW_USER:$NEW_USER /home/$NEW_USER/trading/scripts/bot.py

# =============================================================================
# DONE
# =============================================================================

log "Base setup complete"

# Print deploy user's public key fingerprint for verification
echo ""
echo "============================================================"
echo "  BASE SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Authorized key installed for $NEW_USER:"
cat /home/$NEW_USER/.ssh/authorized_keys
echo ""
echo "  NEXT STEP: verify SSH access as deploy user:"
echo "  ssh -p 22 -i ~/.ssh/trading_vps $NEW_USER@<your-droplet-ip>"
echo ""
echo "  If that works, run setup_harden.sh"
echo "============================================================"
