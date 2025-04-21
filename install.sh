#!/bin/bash

# Checking root rights
if [[ $EUID -ne 0 ]]; then
  echo "This script must be executed with root privileges."
  exit 1
fi

# Check if the --reinstall flag is passed
REINSTALL=false
for arg in "$@"; do
    if [[ "$arg" == "--reinstall" ]]; then
        REINSTALL=true
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

# Checking for root privileges
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with root privileges."
  exit 1
fi

# Array for storing .timer files
TIMER_FILES=()

# We go through all environment variables with the COPY_ prefix
for var in $(echo "$NEW_ENV_VARS" | grep ^COPY_); do
    # Extract the file name and path variable
    file_name="${!var}"
    dir_var=$(echo "$var" | awk -F'_' '{print $(NF-1)"_"$NF}') # Take the last two parts

    # Check if such a path variable exists
    if [[ -z "${!dir_var}" ]]; then
        echo "Error: Destination variable $dir_var is not set!"
        continue
    fi

    dest_path="${!dir_var}"
    target_file="${dest_path}/$(basename "$file_name")"

    # If the file has the extension .conf and already exists, skip (if not --reinstall)
    if [[ "$file_name" == *.conf && -f "$target_file" && "$REINSTALL" == false ]]; then
        echo "Skipping $file_name: already exists in $dest_path."
        continue
    fi

    echo "Copying $file_name to $dest_path..."
    cp "$file_name" "${target_file}"
    chown root:root "${target_file}"

    if [[ "$file_name" == *.sh ]]; then
        chmod +x "${target_file}"
    fi

    # If the file ends with .timer, add it to the list
    if [[ "$file_name" == *.timer ]]; then
        TIMER_FILES+=("$file_name")
    fi
done

# Reloading the systemd configuration
echo "Reloading systemd..."
systemctl daemon-reload

# If there are files with the .timer extension, run the systemctl enable command
for timer_file in "${TIMER_FILES[@]}"; do
    echo "Enabling and starting the timer and service for $timer_file..."
    systemctl enable "$timer_file"
    systemctl start "$timer_file"
done

echo "Installation completed successfully!"
