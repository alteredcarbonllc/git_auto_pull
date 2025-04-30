#!/bin/bash

CONFIG_FILE="/etc/git_auto_pull.conf"

# Checking if a configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    ERR_MSG="❌ [Git Auto Pull] Конфігураційний файл $CONFIG_FILE не знайдено. Завершуємо виконання."
    echo "$(date '+%F %T') [ERROR] ${ERR_MSG}" >> "$LOG_FILE"
    echo "${ERR_MSG}"
    exit 1
fi

# --- 1. Parse the [var] section ---
var_section=$(awk '/^\[var\]/ {flag=1; next} /^\[/ {flag=0} flag' "$CONFIG_FILE")

while IFS='=' read -r key value; do
    key=$(echo "$key" | sed 's/^\$//; s/ //g')
    value=$(echo "$value" | sed 's/^"\(.*\)"$/\1/')
    export "$key=$value"
done <<< "$var_section"

# Get all rows from the [projects] section
project_lines=$(awk '/^\[projects\]/ {flag=1; next} /^\[/ {flag=0} flag' ${CONFIG_FILE})

while IFS='=' read -r key value; do
    # Skip blank lines and comments
    [[ -z "$key" || "$key" =~ ^# ]] && continue

    # Remove spaces around
    key="$(echo "$key" | xargs)"
    value="$(echo "$value" | xargs)"

    # Remove quotes if there are any
    #value="${value%\"}"
    #value="${value#\"}"
    value=$(sed 's/^"\(.*\)"$/\1/' <<< "$value")

    # Skipping empty keys/values
    [[ -z "$key" || -z "$value" ]] && continue

    # Save to associative array (if bash >= 4) or export as variables
    export "$key=$value"
done <<< "$project_lines"

# --- 2. Parse the [projects] section ---
projects_section=$(awk '/^\[projects\]/ {flag=1; next} /^\[/ {flag=0} flag' "$CONFIG_FILE")

declare -A project_paths
declare -A project_branches
project_ids=()

while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | sed 's/^"\(.*\)"$/\1/')

    if [[ $key =~ ^project([0-9]+)_path$ ]]; then
        id=${BASH_REMATCH[1]}
        project_paths[$id]="$value"
        project_ids+=("$id")
    elif [[ $key =~ ^project([0-9]+)_branch$ ]]; then
        id=${BASH_REMATCH[1]}
        project_branches[$id]="$value"
    fi
done <<< "$projects_section"

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
    local message="$1"
    local date_message="$(date '+%F %T')"
    message="[$date_message] $message"


    [[ "$SEND_TELEGRAM" == "1" ]] && send_telegram "$message"
    [[ "$SEND_SIGNAL" == "1" ]] && send_signal "$message"
    [[ "$SEND_XMPP" == "1" ]] && send_xmpp "$message"
}

# === Updating the project ===
update_project() {
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

# Handling command line switches
if [[ "$1" == "--msg" || "$1" == "--telegram" ]]; then
    shift
    if [[ -z "$1" ]]; then
        echo "❌ Error: Message not sent."
        exit 1
    fi
    msg="$*"
    echo "➡ Sending a message: $msg"
    send_message "$msg"
    echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
    exit 0
fi

# --- 3. Обрабатываем проекты ---
for id in "${project_ids[@]}"; do
    path="${project_paths[$id]}"
    branch="${project_branches[$id]}"

    if [[ -n "$path" && -n "$branch" ]]; then
        # Получаем имя проекта
        if sudo -u "$USER" test -d "$path"; then
            project_name=$(sudo -u "$USER" bash -c "cd \"$path\" && basename \$(git rev-parse --show-toplevel)")
        else
            project_name="$path"  # If the directory is unavailable - fallback
        fi

        #msg="🔄 Оновляємо проект *$project_name* на гілці *$branch*."
        #echo "$(date '+%F %T') [INFO] 🔄 Оновляємо проект $msg" >> "$LOG_FILE"
        #send_message "$msg"
        echo "▶ Оновляємо проект $id: $project_name ($branch)"
        update_project "$path" "$branch"
        status=$?

        # Handling statuses via the case construct
        case $status in
            0)
                # Successful update
                msg="OK ✅ Оновлено проект *$project_name* на гілці *$branch*."
                echo "$(date '+%F %T') [INFO] $msg" >> "$LOG_FILE"
                send_message "$msg"
                ;;
            2)
                # Error during update
                msg="FAIL ❌ Помилка при оновленні проекту *$project_name* на гілці *$branch*."
                echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
                send_message "$msg"
                ;;
            3)
                # No changes
                msg="SKIP 🔄 Без змін для *$project_name* ($branch)"
                # Logging and sending a message is not required for status 3
                echo "$(date '+%F %T') $msg"
                ;;
            1)
                # Error with directories
                msg="❌ Помилка: проектна директорія $project_name недоступна або не існує.."
                echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
                send_message "$msg"
                exit 1  # We end the script in case of an error with the directory
                ;;
            *)
                # Unknown exit code
                msg="❌ Невідома помилка при обробці проекту *$project_name* на гілці *$branch*."
                echo "$(date '+%F %T') [ERROR] $msg" >> "$LOG_FILE"
                send_message "$msg"
                exit 1
                ;;
        esac
        # There is no error in the fact that the project has not been updated.
        #if [ $status -ne 0 ]; then
        #    echo "$(date '+%F %T') [ERROR] Проект $path не оновлено." >> "$LOG_FILE"
        #    exit 1
        #fi
    fi
done
