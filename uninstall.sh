#!/bin/bash

# Checking root rights
if [[ $EUID -ne 0 ]]; then
  echo "This script must be executed with root privileges."
  exit 1
fi

# Checking the --all flag
REMOVE_ALL=false
for arg in "$@"; do
    if [[ "$arg" == "--all" ]]; then
        REMOVE_ALL=true
        break
    fi
done

if [ ! -f .env ]; then
    echo "Error: .env file not found!" >&2
    exit 1
fi

BEFORE_ENV_VARS=$(compgen -e)

set -a
. .env
set +a

AFTER_ENV_VARS=$(compgen -e)
NEW_ENV_VARS=$(comm -13 <(echo "$BEFORE_ENV_VARS" | sort) <(echo "$AFTER_ENV_VARS" | sort))

TIMER_FILES=()
for var in $(echo "$NEW_ENV_VARS" | grep ^COPY_); do
    file_name="${!var}"
    dir_var=$(echo "$var" | awk -F'_' '{print $(NF-1)"_"$NF}')

    if [[ -z "${!dir_var}" ]]; then
        echo "Error: Destination variable $dir_var is not set!"
        continue
    fi

    dest_path="${!dir_var}"
    target_file="${dest_path}/$(basename "$file_name")"
    
    if [[ "$file_name" == *.timer ]]; then
        echo "Stopping and disabling $file_name..."
        systemctl stop "$file_name"
        systemctl disable "$file_name"
    fi

    # Skip .conf files unless --all flag is passed
    if [[ "$file_name" == *.conf && -f "$target_file" && "$REMOVE_ALL" == false ]]; then
        echo "Skipping $file_name: --all flag not set."
        continue
    fi

    echo "Deleting $target_file..."
    rm -f "$target_file"
done

# Reloading systemd
echo "Reloading systemd..."
#systemctl daemon-reload

echo "Removal completed!"
