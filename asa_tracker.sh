#!/bin/bash

# --- CONFIGURATION (ARK ASCENDED) ---
LOG_FILE="ShooterGame/Saved/Logs/ShooterGame.log"
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
MAP_FILE="asa_id_map.tmp"

BOT_NAME="Skye Serve ASA Monitor"
BOT_LOGO="https://raw.githubusercontent.com/skye-serve/ASA/refs/heads/main/ARK%20VPS%20Category.jpg"

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

echo "--- Unified ASA Tracker & Logger Started: $(date) ---" > tracker_debug.log

# ========================================================
# --- INFO EXTRACTOR ---
# ========================================================
get_server_info() {
    GUS_INI="ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
    CLEAN_SNAME=""
    if [ -f "$GUS_INI" ]; then
        CLEAN_SNAME=$(grep -m 1 -i "^SessionName=" "$GUS_INI" | cut -d'=' -f2 | tr -d '\r' | tr -d '"' | tr -d "'" | tr -dc '[:print:]')
    fi
    [ -z "$CLEAN_SNAME" ] && CLEAN_SNAME="${SESSION_NAME:-${SERVER_NAME:-ASA Server}}"
    CLEAN_SNAME=$(echo "$CLEAN_SNAME" | tr -d '"' | tr -d "'" | tr -dc '[:print:]')
    CLEAN_MAP="${SERVER_MAP:-Unknown Map}"
    CLEAN_MAP="${CLEAN_MAP%_WP}"
    case "$CLEAN_MAP" in
        "TheIsland") CLEAN_MAP="The Island" ;;
        "ScorchedEarth") CLEAN_MAP="Scorched Earth" ;;
        "TheCenter") CLEAN_MAP="The Center" ;;
        "BobsMissions") CLEAN_MAP="Bob's Missions" ;;
        "LostColony") CLEAN_MAP="Lost Colony" ;;
        "TemptressLagoon") CLEAN_MAP="Temptress Lagoon" ;;
        "ClubARK") CLEAN_MAP="Club ARK" ;;
        "LostCity") CLEAN_MAP="Lost City" ;;
        "EbenusAstrum") CLEAN_MAP="Ebenus Astrum" ;;
        "TaeniaStella") CLEAN_MAP="Taenia Stella" ;;
        "PrimalGround") CLEAN_MAP="Primal Ground" ;;
        "BloodSands") CLEAN_MAP="Blood Sands" ;;
        "NexoArkano") CLEAN_MAP="Nexo Arkano" ;;
        "Nyxora_Eventmap") CLEAN_MAP="Nyxora Event Map" ;;
        "WAK_TROPICAL") CLEAN_MAP="WAK Tropical" ;;
    esac
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
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": true},
      {"name": "Map", "value": "$CLEAN_MAP", "inline": true},
      {"name": "Status", "value": "🔴 Offline", "inline": true},
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
trap send_offline SIGTERM SIGINT

# ========================================================
# --- BACKGROUND LISTENER (Player Tracking + Event Logging) ---
# ========================================================
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    
    # 1. Player Joins (Updated for ASA syntax)
    if [[ "$line" == *"joined this ARK!"* ]]; then
        # This isolates everything between ": " and " [UniqueNetId" to perfectly grab the name
        NAME=$(echo "$line" | awk -F' \\[UniqueNetId' '{print $1}' | awk -F': ' '{print $NF}' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ] && ! grep -qx "$NAME" "$LIST_FILE"; then
            echo "$NAME" >> "$LIST_FILE"
        fi
    fi

    # 2. Player Leaves (Updated to target the specific player name!)
    if [[ "$line" == *"left this ARK!"* ]]; then
        NAME=$(echo "$line" | awk -F' \\[UniqueNetId' '{print $1}' | awk -F': ' '{print $NF}' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ]; then
            # Deletes only this specific player's name from the tracker list
            sed -i "/^$NAME$/d" "$LIST_FILE"
        fi
    fi

    # Fallback Wipe for hard crashes
    if [[ "$line" == *"LogNet: UChannel::Close"* ]] || [[ "$line" == *"Account was disconnected"* ]]; then
        ONLINE_COUNT=$(grep -c "[^[:space:]]" "$LIST_FILE")
        if [ "$ONLINE_COUNT" -le 1 ]; then > "$LIST_FILE"; fi
    fi

    # 3. Admin Events (Only if LOG_WEBHOOK exists)
    if [ -n "$LOG_WEBHOOK" ]; then
        EVENT_MSG=""
        ICON=""

        if [[ "$line" == *"tamed a"* ]]; then
            EVENT_MSG="🦖 TAME: $line"
            ICON="🦖"
        elif [[ "$line" == *"claimed a"* ]]; then
            EVENT_MSG="🚩 CLAIM: $line"
            ICON="🚩"
        elif [[ "$line" == *"was born!"* ]] || [[ "$line" == *"hatched a"* ]]; then
            EVENT_MSG="🍼 NEW BABY: $line"
            ICON="🍼"
        elif [[ "$line" == *"was killed by"* ]]; then
            EVENT_MSG="💀 DEATH: $line"
            ICON="☠️"
        fi

        if [ -n "$EVENT_MSG" ]; then
            CLEAN_EVENT=$(echo "$EVENT_MSG" | sed 's/\[.*\] //')
            curl -s -X POST -H "Content-Type: application/json" -d "{\"content\": \"$ICON **$CLEAN_EVENT**\"}" "$LOG_WEBHOOK"
        fi
    fi
done &

# ========================================================
# --- MAIN DISCORD LOOP (Server Status Embed) ---
# ========================================================
while true; do
    CUR_TIME=$(date +'%T')
    get_server_info
    PLAYERS=$(grep -c "[^[:space:]]" "$LIST_FILE" | awk '{print $1}')
    [ -z "$PLAYERS" ] && PLAYERS=0
    
    if [ "$PLAYERS" -eq 0 ]; then
        FINAL_LIST="None online"
    else
        FINAL_LIST=$(sed '/^$/d' "$LIST_FILE" | tr -d '"' | paste -sd ',' - | sed 's/,/\\n/g')
    fi

    cat <<EOF > payload.json
{
  "username": "$BOT_NAME",
  "avatar_url": "$BOT_LOGO",
  "embeds": [{
    "title": "🦖 Ark Ascended Live Server Status",
    "color": 5763719,
    "fields": [
      {"name": "Server Name", "value": "$CLEAN_SNAME", "inline": true},
      {"name": "Map", "value": "$CLEAN_MAP", "inline": true},
      {"name": "Status", "value": "🟢 Online", "inline": true},
      {"name": "Current Players", "value": "$PLAYERS", "inline": true},
      {"name": "Online Players", "value": "\`\`\`\n$FINAL_LIST\n\`\`\`", "inline": false}
    ],
    "footer": {"text": "Last Updated: $CUR_TIME | Skye Serve"}
  }]
}
EOF

    if [ ! -s "$MSG_ID_FILE" ]; then
        RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}?wait=true")
        NEW_ID=$(echo "$RESPONSE" | grep -o '"id":"[0-9]*"' | head -n 1 | cut -d'"' -f4)
        if [[ "$NEW_ID" =~ ^[0-9]+$ ]]; then echo "$NEW_ID" > "$MSG_ID_FILE"; fi
    else
        MESSAGE_ID=$(cat "$MSG_ID_FILE")
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH -H "Content-Type: application/json" -d @payload.json "${DISCORD_WEBHOOK}/messages/${MESSAGE_ID}")
        if [ "$HTTP_CODE" == "404" ]; then rm -f "$MSG_ID_FILE"; fi
    fi
    sleep 5 &
    wait $!
done
