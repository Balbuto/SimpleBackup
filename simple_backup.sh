#!/bin/bash

# --- 1. ПРОВЕРКА ПРАВ ROOT ---
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[0;31mОшибка: Запустите скрипт от имени root (sudo).\033[0m"
   exit 1
fi

# --- 2. ПРОВЕРКА И УСТАНОВКА КОМПОНЕНТОВ ---
check_dependencies() {
    local tools=("curl" "mutt" "docker" "gzip" "tar" "zip")
    local missing=()
    for t in "${tools[@]}"; do
        command -v "$t" &> /dev/null || missing+=("$t")
    done

    if [ ${#missing[@]} -ne 0 ]; then
        echo -e "\033[1;33mОтсутствуют компоненты: ${missing[*]}\033[0m"
        read -p "Установить их сейчас? [y/N]: " inst
        if [[ "$inst" =~ ^[Yy]$ ]]; then
            apt-get update && apt-get install -y "${missing[@]}"
        else
            echo "Работа невозможна без зависимостей. Выход."; exit 1
        fi
    fi
}
check_dependencies

# --- 3. ЗАГРУЗКА КОНФИГУРАЦИИ ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo -e "${RED}Ошибка: Конфиг $CONFIG_FILE не найден!${NC}"
    exit 1
fi

CURRENT_NOTIFY_MODE=${DEFAULT_NOTIFY_MODE:-3}

# --- 4. ФУНКЦИИ УВЕДОМЛЕНИЙ ---
choose_notify_mode() {
    echo -e "\n${BLUE}>> Настройка уведомлений <<${NC}"
    echo "1) Только Telegram  2) Только Email  3) Оба  4) Тихий режим"
    read -p "Выберите режим [$CURRENT_NOTIFY_MODE]: " mode_choice
    CURRENT_NOTIFY_MODE=${mode_choice:-$CURRENT_NOTIFY_MODE}
}

send_reports() {
    local msg=$1; local file=$2; local subject=$3
    [ ! -f "$file" ] && file=""

    # Telegram
    if [[ "$CURRENT_NOTIFY_MODE" == "1" || "$CURRENT_NOTIFY_MODE" == "3" ]]; then
        if [[ ! -z "$TG_TOKEN" && ! -z "$TG_CHAT_ID" ]]; then
            curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d chat_id="$TG_CHAT_ID" -d text="$msg" > /dev/null
            if [[ ! -z "$file" && $(stat -c%s "$file") -le ${TG_MAX_SIZE:-52428800} ]]; then
                curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendDocument" -F chat_id="$TG_CHAT_ID" -F document=@"$file" > /dev/null
            fi
        fi
    fi

    # Email
    if [[ "$CURRENT_NOTIFY_MODE" == "2" || "$CURRENT_NOTIFY_MODE" == "3" ]]; then
        if [[ ! -z "$ADMIN_EMAIL" ]]; then
            if [ ! -z "$file" ]; then
                echo "$msg" | mutt -s "$subject" -a "$file" -- "$ADMIN_EMAIL"
            else
                echo "$msg" | mail -s "$subject" "$ADMIN_EMAIL"
            fi
        fi
    fi
}

# --- 5. ПОЛУЧЕНИЕ ПАРАМЕТРОВ БД ---
get_db_params() {
    echo -e "\n${BLUE}>> Параметры БД <<${NC}"
    read -p "Путь к проекту [$(pwd)]: " SOURCE_DIR
    SOURCE_DIR=${SOURCE_DIR:-$(pwd)}
    ENV_FILE="$SOURCE_DIR/.env"
    if [ -f "$ENV_FILE" ]; then
        DB_NAME=$(grep '^DATABASE_NAME=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_USER=$(grep '^DATABASE_USER=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_PASS=$(grep '^DATABASE_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        DB_CONT=$(grep '^DATABASE_HOST=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' | tr -d "'" | tr -d '\r')
        echo -e "Найдено в .env: ${YELLOW}$DB_NAME${NC} (Контейнер: ${YELLOW}$DB_CONT${NC})"
        read -p "Использовать эти данные? [Y/n]: " conf
        [[ ! $conf =~ ^[Yy]$ && ! -z $conf ]] && unset DB_NAME
    fi
    if [ -z "$DB_NAME" ]; then
        read -p "Контейнер: " DB_CONT; read -p "Имя БД: " DB_NAME
        read -p "Пользователь: " DB_USER; read -s -p "Пароль: " DB_PASS; echo ""
    fi
}

# --- 6. БЭКАП ---
do_backup() {
    choose_notify_mode
    get_db_params
    read -p "Путь сохранения [$DEFAULT_BACKUP_DEST]: " B_DEST
    B_DEST=${B_DEST:-$DEFAULT_BACKUP_DEST}
    mkdir -p "$B_DEST"
    DATE=$(date +%Y-%m-%d_%H-%M-%S); HOSTNAME=$(hostname)

    DB_FILE="$B_DEST/db_$DATE.sql.gz"
    echo "Выполняю дамп БД..."
    docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$DB_FILE"
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        send_reports "✅ БЭКАП БД ГОТОВ: $DB_NAME на $HOSTNAME" "$DB_FILE" "Backup Success: DB"
    else
        send_reports "❌ ОШИБКА БЭКАПА БД на $HOSTNAME" "" "Backup ERROR: DB"
    fi

    FILE_ARCH="$B_DEST/files_$DATE.tar.gz"
    echo "Архивирую файлы..."
    tar -czf "$FILE_ARCH" -C "$SOURCE_DIR" .
    send_reports "✅ БЭКАП ФАЙЛОВ ГОТОВ на $HOSTNAME" "$FILE_ARCH" "Backup Success: Files"
    echo -e "${GREEN}Бэкап завершен.${NC}"
}

# --- 7. ВОССТАНОВЛЕНИЕ ---
do_restore() {
    choose_notify_mode
    read -p "Папка бэкапов [$DEFAULT_BACKUP_DEST]: " B_DEST
    B_DEST=${B_DEST:-$DEFAULT_BACKUP_DEST}
    HOSTNAME=$(hostname)

    # Восстановление БД
    ls -1 "$B_DEST" | grep "db_.*\.sql\.gz"
    read -p "Имя файла БД (Enter - пропустить): " DB_FILE
    if [[ -f "$B_DEST/$DB_FILE" ]]; then
        get_db_params
        echo -e "${RED}ВНИМАНИЕ: База $DB_NAME будет перезаписана!${NC}"
        echo "1) Очистить БД (Wipe)  2) Поверх  3) Отмена"
        read -p "Выбор: " db_act
        if [[ "$db_act" == "1" || "$db_act" == "2" ]]; then
            [[ "$db_act" == "1" ]] && docker exec -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
            gunzip -c "$B_DEST/$DB_FILE" | docker exec -i -e PGPASSWORD="$DB_PASS" "$DB_CONT" psql -U "$DB_USER" -d "$DB_NAME"
            [ $? -eq 0 ] && send_reports "🔄 ВОССТАНОВЛЕНА БД: $DB_NAME на $HOSTNAME" "" "Restore OK" || send_reports "⚠️ ОШИБКА ВОССТАНОВЛЕНИЯ БД" "" "Restore ERR"
        fi
    fi

    # Восстановление Файлов
    ls -1 "$B_DEST" | grep "files_.*\.tar\.gz"
    read -p "Имя архива файлов (Enter - пропустить): " F_FILE
    if [[ -f "$B_DEST/$F_FILE" ]]; then
        read -p "Куда восстановить? [$SOURCE_DIR]: " R_DIR
        R_DIR=${R_DIR:-$SOURCE_DIR}
        echo "1) Очистить папку  2) Поверх  3) Отмена"
        read -p "Выбор: " f_act
        if [[ "$f_act" == "1" || "$f_act" == "2" ]]; then
            [[ "$f_act" == "1" ]] && rm -rf "${R_DIR:?}"/*
            tar -xzf "$B_DEST/$F_FILE" -C "$R_DIR"
            send_reports "🔄 ВОССТАНОВЛЕНЫ ФАЙЛЫ на $HOSTNAME в $R_DIR" "" "Restore OK"
        fi
    fi
}

# --- 8. МЕНЮ ---
while true; do
    echo -e "\n${BLUE}=== УПРАВЛЕНИЕ БЭКАПАМИ ===${NC}"
    echo "1) Создать бэкап"
    echo "2) Восстановить из бэкапа"
    echo "3) Настроить уведомления (сейчас: $CURRENT_NOTIFY_MODE)"
    echo "4) Выход"
    read -p "Выберите действие: " choice
    case $choice in
        1) do_backup ;;
        2) do_restore ;;
        3) choose_notify_mode ;;
        4) exit 0 ;;
    esac
done
