#!/bin/bash

# --- CONFIGURATION (ARK ASCENDED) ---
LOG_FILE="ShooterGame/Saved/Logs/ShooterGame.log"
MSG_ID_FILE="discord_message_id.txt"
LIST_FILE="current_players.tmp"
MAP_FILE="asa_id_map.tmp"

# --- WEBHOOKS ---
# Pulling from Panel Environment Variables
DISCORD_WEBHOOK="${DISCORD_WEBHOOK}"
CHAT_WEBHOOK="${CHAT_WEBHOOK}"
LOG_WEBHOOK="${LOG_WEBHOOK}"

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

echo "--- Unified ASA Tracker, Chat, & Logger Started: $(date) ---" > tracker_debug.log

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
# --- BACKGROUND LISTENER (Player Tracking + Logs + Chat) ---
# ========================================================
tail -F -n 0 "$LOG_FILE" 2>/dev/null | while read -r line; do
    # Strip carriage returns to prevent pipeline hanging
    line="${line//$'\r'/}"
    
    # ----------------------------------------------------
    # 💬 1. CHAT RELAY LOGIC
    # ----------------------------------------------------
    if [[ "$line" == *"ServerChat: "* ]]; then
        # Ignore Discord relayed messages to prevent loops
        if [[ "$line" != *"[Discord]"* ]]; then
            # Format: [Time]ServerChat: PlayerName: Message...
            CHAT_RAW=$(echo "$line" | sed 's/.*ServerChat: //')
            P_NAME=$(echo "$CHAT_RAW" | cut -d':' -f1 | xargs)
            P_MSG=$(echo "$CHAT_RAW" | cut -d':' -f2- | xargs)

            if [ -n "$P_NAME" ] && [ -n "$P_MSG" ] && [ -n "$CHAT_WEBHOOK" ]; then
                curl -s --max-time 8 -X POST -H "Content-Type: application/json" \
                -d "{\"username\": \"$P_NAME\", \"content\": \"$P_MSG\"}" \
                "$CHAT_WEBHOOK"
            fi
        fi
    fi

    # ----------------------------------------------------
    # 👥 2. PLAYER JOIN/LEAVE LOGIC
    # ----------------------------------------------------
    if [[ "$line" == *"joined this ARK!"* ]]; then
        NAME=$(echo "$line" | awk -F' \\[UniqueNetId' '{print $1}' | awk -F': ' '{print $NF}' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ] && ! grep -qx "$NAME" "$LIST_FILE"; then
            echo "$NAME" >> "$LIST_FILE"
        fi
    fi

    if [[ "$line" == *"left this ARK!"* ]]; then
        NAME=$(echo "$line" | awk -F' \\[UniqueNetId' '{print $1}' | awk -F': ' '{print $NF}' | tr -d '\r\n' | tr -d '"' | tr -d "'" | xargs)
        if [ -n "$NAME" ]; then
            sed -i "/^$NAME$/d" "$LIST_FILE"
        fi
    fi

    if [[ "$line" == *"LogNet: UChannel::Close"* ]] || [[ "$line" == *"Account was disconnected"* ]]; then
        ONLINE_COUNT=$(grep -c "[^[:space:]]" "$LIST_FILE")
        if [ "$ONLINE_COUNT" -le 1 ]; then > "$LIST_FILE"; fi
    fi

    # ----------------------------------------------------
    # 🛠️ 3. ADMIN & ACTION EVENTS LOGIC
    # ----------------------------------------------------
    if [ -n "$LOG_WEBHOOK" ]; then
        EVENT_MSG=""
        ICON=""

        # Catch Admin Commands
        if [[ "$line" == *"AdminCmd:"* ]]; then
            EVENT_MSG=$(echo "$line" | sed 's/.*AdminCmd: //')
            EVENT_MSG="**ADMIN COMMAND:** $EVENT_MSG"
            ICON="🚨"
        
        # Catch Player Actions (Tames, Claims, Births, Deaths)
        elif [[ "$line" == *"tamed a"* ]]; then
            EVENT_MSG=$(echo "$line" | sed -E 's/.*(: |\])//')
            EVENT_MSG="TAME: $EVENT_MSG"
            ICON="🦕"
        elif [[ "$line" == *"claimed a"* ]]; then
            EVENT_MSG=$(echo "$line" | sed -E 's/.*(: |\])//')
            EVENT_MSG="CLAIM: $EVENT_MSG"
            ICON="🚩"
        elif [[ "$line" == *"was born!"* ]] || [[ "$line" == *"hatched a"* ]]; then
            EVENT_MSG=$(echo "$line" | sed -E 's/.*(: |\])//')
            EVENT_MSG="NEW BABY: $EVENT_MSG"
            ICON="🍼"
        elif [[ "$line" == *"was killed by"* ]] || [[ "$line" == *"died!"* ]]; then
            EVENT_MSG=$(echo "$line" | sed -E 's/.*(: |\])//')
            EVENT_MSG="DEATH: $EVENT_MSG"
            ICON="☠️"
        fi

        # Push to Discord
        if [ -n "$EVENT_MSG" ]; then
            # Clean off any lingering date/time prefixes for a clean Discord embed
            CLEAN_EVENT=$(echo "$EVENT_MSG" | sed -E 's/\[[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}\.[0-9]{2}\.[0-9]{2}:[0-9]+\]\[[ ]*[0-9]+\]//g' | xargs)
            
            curl -s --max-time 5 -X POST -H "Content-Type: application/json" \
            -d "{\"content\": \"$ICON $CLEAN_EVENT\"}" "$LOG_WEBHOOK"
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
    sleep 5
done
