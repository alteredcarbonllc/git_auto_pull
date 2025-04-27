SHELL := /bin/bash
.ONESHELL:

# Destination routes
BIN_DIR := /usr/bin
SERVICE_DIR := /etc/systemd/system
ETC_DIR := /etc
CRON_DIR := /etc/cron.d

# What to copy where
BIN_FILES := git_auto_pull.sh
SERVICE_FILES :=
CONFIG_FILES := git_auto_pull.conf
CRON_FILES := git_auto_pull

REINSTALL ?= false

.PHONY: install
install:
	# Enabling exit on error
	set -e

	# Checking root rights
	if [[ "$$(id -u)" -ne 0 ]]; then
		echo -e "\033[1;31m❌ Error: This script must be run as root!❌\033[0m" >&2; \
		exit 1
	fi

	# Starting line
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	echo -e "\033[1;32m🔧 Starting installation...\033[0m"
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"

	# Copy binaries
	if [ -n "$(BIN_FILES)" ]; then
		for file in $(BIN_FILES); do \
			dest="$(BIN_DIR)/$$(basename $$file)"; \
			echo -e "\033[1;32m📂 Copying $$file -> $(BIN_DIR)\033[0m"; \
			cp "$$file" "$$dest"; \
			chown root:root "$$dest"; \
			if [[ "$$file" == *.sh ]]; then chmod +x "$$dest"; fi; \
		done
	else
		echo -e "\033[1;33m⚠️ No binary files to copy, skipping...\033[0m"; \
	fi

	# Copy systemd services and timers
	if [ -n "$(SERVICE_FILES)" ]; then
		for file in $(SERVICE_FILES); do \
			dest="$(SERVICE_DIR)/$$(basename $$file)"; \
			if [[ ! -f "$$file" ]]; then \
				echo -e "\033[1;31m❌ Error: $$file does not exist! Skipping...\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📂 Copying $$file -> $(SERVICE_DIR)\033[0m"; \
			cp "$$file" "$$dest"; \
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No service files to copy, skipping...\033[0m"
	fi

	# Copy configs
	if [ -n "$(CONFIG_FILES)" ]; then
		for file in $(CONFIG_FILES); do \
			dest="$(ETC_DIR)/$$(basename $$file)"; \
			if [[ ! -f "$$file" ]]; then \
				echo -e "\033[1;31m❌ Error: $$file does not exist! Skipping...\033[0m"; \
				continue; \
			fi; \
			if [[ "$$file" == *.conf && -f "$$dest" && "$(REINSTALL)" == "false" ]]; then \
				echo -e "\033[1;33m⏩ Skipping $$file: already exists.\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📂 Copying $$file -> $(ETC_DIR)\033[0m"; \
			cp "$$file" "$$dest"; \
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No config files to copy, skipping...\033[0m"
	fi

	# Copy cron files
	if [ -n "$(CRON_FILES)" ]; then
		for file in $(CRON_FILES); do \
			dest="$(CRON_DIR)/$$(basename $$file)"; \
			if [[ ! -f "$$file" ]]; then \
				echo -e "\033[1;31m❌ Error: $$file does not exist! Skipping...\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📂 Copying $$file -> $(CRON_DIR)\033[0m"; \
			cp "$$file" "$$dest"; \
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No cron files to copy, skipping...\033[0m"
	fi

	# Updating systemd
	echo -e "\033[1;34m🔄 Reloading systemd...\033[0m"
	systemctl daemon-reload

	# Launch timers from the list of services
	if [ -n "$(SERVICE_FILES)" ]; then
		for file in $(SERVICE_FILES); do \
			if [[ "$$file" == *.timer ]]; then \
				echo -e "\033[1;32m⏳ Enabling and starting $$file...\033[0m"; \
				systemctl enable "$(SERVICE_DIR)/$$file"; \
				systemctl start "$(SERVICE_DIR)/$$file"; \
			fi; \
		done
	fi

	# Restart cron
	if [[ "$(CRON_FILES)" != "" ]]; then \
		echo -e "\033[1;34m🔄 Restarting cron service...\033[0m"; \
		systemctl restart cron || systemctl restart crond; \
	fi

	# Finishing line
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	echo -e "\033[1;32m✔️ Installation completed successfully!\033[0m"
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"


