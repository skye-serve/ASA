#!/bin/bash

# --- CONFIGURATION (ARK ASCENDED) ---
LOG_FILE="ShooterGame/Saved/Logs/ShooterGame.log"
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
MAP_FILE="asa_id_map.tmp"

BOT_NAME="Skye Serve Monitor"
BOT_LOGO="https://raw.githubusercontent.com/parkervcp/pterodactyl-images/master/logos/ark_survival_ascended.png"

# --- GHOST KILLER ---
for pid in $(pgrep -f asa_tracker.sh); do
    if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
        kill -9 "$pid" 2>/dev/null
    fi
done

# CLEAN RESET
rm -f "payload.json"
> "$LIST_FILE" 
touch "$MAP_FILE"

echo "--- Stable ASA Tracker Started: $(date) ---" > tracker_debug.log

# ========================================================
# --- DATA EXTRACTION ---
# Pterodactyl passes these from your Variables tab. 
# We check the most common variable names used in ASA eggs.
# ========================================================
get_server_info() {
    # Find Server Name (Checks SESSION_NAME first, then SERVER_NAME)
    CLEAN_SNAME=$(echo "${SESSION_NAME:-${SERVER_NAME:-ASA Server}}" | tr -d '"' | tr -dc '[:print:]')
    
    # Find Map Name (Checks SERVER_MAP first, then MAP)
    CLEAN_MAP=$(echo "${SERVER_MAP:-${MAP:-TheIsland_WP}}" | tr -d '"' | tr -dc '[:print:]')
}

# ========================================================
# --- SHUTDOWN INTERCEPTOR ---
# ========================================================
send_offline() {
    echo "[SHUTDOWN] Kill signal received! Updating Discord..." >> tracker_debug.log
    CUR_TIME=$(date +'%T')
    get_server_info
    
    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🦖 Ark Ascended Live Server Status",
    "color": 15548997, 
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": false},
      {"name": "Map", "value": "$CLEAN_MAP", "inline": true},
      {"name": "Status", "value": "🔴 Offline", "inline": true},
      {"name": "Current Players", "value": "0", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\nServer is currently offline\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF
    if [ -s "$MSG_ID_FILE" ]; then
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        curl -s -o /dev/null -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}"
    fi
    exit 0
}

# Trap Pterodactyl's Stop button
trap send_offline SIGTERM SIGINT
# ========================================================

# --- Background Listener ---
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do

    # Trigger #1: Player Joins
    if [[ "$line" == *"Join succeeded:"* ]]; then
        NAME=$(echo "$line" | sed 's/.*Join succeeded: //' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ] && ! grep -qx "$NAME" "$LIST_FILE"; then
            echo "$NAME" >> "$LIST_FILE"
        fi
    fi

    # Trigger #2: Player Leaves
    if [[ "$line" == *"CloseBunch"* ]] || [[ "$line" == *"LogNet: UChannel::Close"* ]]; then
        if [[ "$line" == *"Account was disconnected"* ]]; then
            LEAVE_ID=$(echo "$line" | sed -n 's/.*AccountId \([A-F0-9]*\)\..*/\1/p')
        fi
        
        # Fallback for generic disconnects: if we only have 1 player, clear the list
        ONLINE
