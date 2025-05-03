#!/bin/bash

CONFIG_FILE="/etc/git_auto_pull.conf"
LOG_FILE="/var/log/git_auto_pull.log"

check_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        local err="❌ [Git Auto Pull] Конфігураційний файл $CONFIG_FILE не знайдено. Завершуємо виконання."
        echo "$(date '+%F %T') [ERROR] $err" >> "$LOG_FILE"
        echo "$err"
        exit 1
    fi
}

parse_var_section() {
    local section=$(awk '/^\[var\]/ {flag=1; next} /^\[/ {flag=0} flag' "$CONFIG_FILE")
    while IFS='=' read -r key value; do
        key=$(echo "$key" | sed 's/^\$//; s/ //g')
        value=$(echo "$value" | sed 's/^\"\(.*\)\"$/\1/')
        export "$key=$value"
    done <<< "$section"
}

parse_projects_section() {
    local section=$(awk '/^\[projects\]/ {flag=1; next} /^\[/ {flag=0} flag' "$CONFIG_FILE")

    declare -gA project_paths
    declare -gA project_branches
    declare -ga project_ids

    while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | sed 's/^\"\(.*\)\"$/\1/')

        if [[ $key =~ ^project([0-9]+)_path$ ]]; then
            id=${BASH_REMATCH[1]}
            project_paths[$id]="$value"
            project_ids+=("$id")
        elif [[ $key =~ ^project([0-9]+)_branch$ ]]; then
            id=${BASH_REMATCH[1]}
            project_branches[$id]="$value"
        fi
    done <<< "$section"
}

handle_command_line() {
    if [[ "$1" == "--msg" || "$1" == "--telegram" ]]; then
        shift
        if [[ -z "$1" ]]; then
            echo "❌ Error: Message not sent."
            exit 1
        fi
        local msg="$*"
        echo "➡ Sending a message: $msg"
        send_message "$msg"
        echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
        exit 0
    fi

    # Если аргументов нет, но есть PAM-переменные, формируем сообщение
    if [[ -z "$1" && -n "$PAM_USER" && -n "$PAM_SERVICE" && -n "$PAM_TTY" ]]; then
        local msg="🔐 PAM login: user *$PAM_USER* via *$PAM_SERVICE* on *$PAM_TTY*"
        [[ -n "$PAM_RHOST" ]] && msg+=" from *$PAM_RHOST*"
        echo "➡ Sending PAM message: $msg"
        send_message "$msg"
        echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
        exit 0
    fi
}

process_projects() {
    for id in "${project_ids[@]}"; do
        local path="${project_paths[$id]}"
        local branch="${project_branches[$id]}"

        if [[ -n "$path" && -n "$branch" ]]; then
            if sudo -u "$USER" test -d "$path"; then
                project_name=$(sudo -u "$USER" bash -c "cd \"$path\" && basename \$(git rev-parse --show-toplevel)")
            else
                project_name="$path"
            fi

            echo "▶ Оновлюємо проект $id: $project_name ($branch)"
            update_project "$path" "$branch"
            status=$?

            handle_project_status "$status" "$project_name" "$branch"
        fi
    done
}

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
         -d chat_id="$CHAT_ID" \
         -d parse_mode="Markdown" \
         -d text="$1" > /dev/null
}

send_signal() {
    signal-cli -a $SIGNAL_SENDER send -m "$1" $SIGNAL_RECIPIENT > /dev/null
}

send_xmpp() {
    echo "$1" | sendxmpp -t $XMPP_RECIPIENT
#    -t \
#    -j $XMPP_JID \
#    -p $XMPP_PASSWORD \
#    $XMPP_RECIPIENT
}

send_message() {
    local base_message="$1"
    local date_message="$(date '+%F %T')"
    local message="[$date_message]"

    #if [[ -n "$PAM_USER" && -n "$PAM_RHOST" && -n "$PAM_TTY" ]]; then
    #    message+=" user=$PAM_USER from=$PAM_RHOST tty=$PAM_TTY 🔐 Login detected"
    #else
    #    message+=" $base_message"
    #fi
    message+=" $base_message"

    [[ "$SEND_TELEGRAM" == "1" ]] && send_telegram "$message"
    [[ "$SEND_SIGNAL" == "1" ]] && send_signal "$message"
    [[ "$SEND_XMPP" == "1" ]] && send_xmpp "$message"
}

# === Updating the project (old version) ===
old_update_project() {
    local path="$1"
    local branch="$2"

    # Checking directory availability
    if ! sudo -u "$USER" test -d "$path"; then
        echo "$(date '+%F %T') [ERROR] Каталог проектів недоступний: $path" >> "$LOG_FILE"
        send_message "❌ Помилка: каталог проекту *$path* недоступний або не існує."
echo 1  # Error: project directory *$path* is unavailable or does not exist
        return
    fi

    # Perform git operations inside sudo with access as user
    result=$(sudo -u "$USER" bash -c "
        cd \"$path\" || exit 1
        git fetch origin

        LOCAL_HEAD=\$(git rev-parse HEAD)
        REMOTE_HEAD=\$(git rev-parse origin/$branch)

        if [ \"\$LOCAL_HEAD\" != \"\$REMOTE_HEAD\" ]; then
            if git diff --exit-code origin/$branch > /dev/null; then
               # No changes
               echo 3
            else
                # There are changes, let's do a pull
                if git pull origin $branch > /dev/null 2>&1; then
                    # Successful update
                    echo 0
                else
                    # Error during update
                    echo 2
                fi
            fi
        else
            echo 3  # No changes
        fi
    ")
    #echo  "Result = $result"
    return "${result}"
}

# === Updating the project (30/04/2025 version) ===
update_project() {
    local path="$1"
    local branch="$2"

    # Checking directory availability
    if ! sudo -u "$USER" test -d "$path"; then
        echo "$(date '+%F %T') [ERROR] Каталог проекту недоступний: $path" >> "$LOG_FILE"
        send_message "❌ Помилка: каталог проекту *$path* недоступний або не існує."
        return 1
    fi

    # Get current and remote HEAD
    local HEADS
    HEADS=$(sudo -u "$USER" bash -c "
        cd \"$path\" || exit 1
        git fetch origin
        echo \$(git rev-parse HEAD) \$(git rev-parse origin/$branch)
    ") || { echo 1; return 1; }

    local LOCAL_HEAD REMOTE_HEAD
    read -r LOCAL_HEAD REMOTE_HEAD <<< "$HEADS"

    # If HEADs are the same - no changes
    if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
        return 3
    fi

    # Checking differences
    if sudo -u "$USER" bash -c "
        cd \"$path\" && git diff --exit-code origin/$branch > /dev/null
    "; then
        # There are no differences (only fast-forward is possible)
        return 3
    fi

    # === Sending a message ===
    project_name=$(sudo -u "$USER" bash -c "cd \"$path\" && basename \$(git rev-parse --show-toplevel)")
    msg="🔄 Виявлено зміни в репозиторії *$project_name*, що лежить у директорії $path . Оновлюємо..."
    echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
    send_message "$msg"

    # Let's try to update
    if sudo -u "$USER" bash -c "
        cd \"$path\" && git pull origin $branch > /dev/null 2>&1
    "; then
        return 0  # Successfully
    else
        return 2  # Error while pulling
    fi
}

handle_project_status() {
    local status="$1"
    local project_name="$2"
    local branch="$3"
    local msg

    case $status in
        0)
            msg="OK ✅ Оновлено проект *$project_name* на гілці *$branch*."
            echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
            send_message "$msg"
            ;;
        2)
            msg="FAIL ❌ Помилка при оновленні проекту *$project_name* на гілці *$branch*."
            echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
            send_message "$msg"
            ;;
        3)
            msg="SKIP 🔄 Без змін для *$project_name* ($branch)"
            echo "$(date '+%F %T') $msg"
            ;;
        1)
            msg="❌ Помилка: проектна директорія $project_name недоступна або не існує."
            echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
            send_message "$msg"
            exit 1
            ;;
        *)
            msg="❌ Невідома помилка при обробці проекту *$project_name* на гілці *$branch*."
            echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
            send_message "$msg"
            exit 1
            ;;
    esac
}

main() {
    check_config_file
    parse_var_section
    parse_projects_section
    handle_command_line "$@"
    process_projects
}

main "$@"
