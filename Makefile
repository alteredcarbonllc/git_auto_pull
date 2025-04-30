SHELL := /bin/bash
.ONESHELL:

# Destination routes
LOGS_DIR := /var/log
BIN_DIR := /usr/bin
SERVICE_DIR := /etc/systemd/system
ETC_DIR := /etc
CRON_DIR := /etc/cron.d

INSTALL_LOG_FILE := install.log

# What to copy where
LOGS_FILES := git_auto_pull.log
BIN_FILES := git_auto_pull.sh
SERVICE_FILES :=
CONFIG_FILES := git_auto_pull.conf
CRON_FILES := git_auto_pull

REINSTALL ?= false

define print-notify
	@bash -c 'msg="$(1)"; \
	if [ -x /usr/bin/git_auto_pull.sh ]; then \
		echo -e "\033[1;32m $$msg \033[0m" | tee -a $(INSTALL_LOG_FILE); \
		/usr/bin/git_auto_pull.sh --msg "$$msg"; \
	else \
		echo -e "\033[1;32m $$msg \033[0m" | tee -a $(INSTALL_LOG_FILE); \
	fi'
endef

.PHONY: install check-root copy-bin copy-systemd copy-conf copy-cron updating-systemd launch-timers restart-cron ensure-logs
install: check-root
	# Enabling exit on error
	@set -e

	# Starting line
	@echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	$(call print-notify, [git_auto_pull] 🔧 Starting installation...)
	@echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"

	@$(MAKE) copy-bin
	@$(MAKE) copy-systemd
	@$(MAKE) copy-conf
	@$(MAKE) copy-cron
	@$(MAKE) updating-systemd
	@$(MAKE) launch-timers
	@$(MAKE) restart-cron

	# Finishing line
	@echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	$(call print-notify, [git_auto_pull] ✔️ Installation completed successfully!)
	@echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"

# Check if running as root
check-root:
	@echo "UID = $$(id -u)"
	@if [[ "$$(id -u)" -ne 0 ]]; then \
		echo -e "\033[1;31m❌ Error: This script must be run as root!❌\033[0m" >&2; \
		exit 1; \
	fi

# Copy binaries
copy-bin:
	@if [ -n "$(BIN_FILES)" ]; then
		for file in $(BIN_FILES); do \
			dest="$(BIN_DIR)/$$(basename $$file)"; \
			echo -e "\033[1;32m📂 Copying $$file -> $(BIN_DIR)\033[0m"; \
			cp "$$file" "$$dest" || { echo -e "\033[1;31m❌ Error copying $$file to $$dest\033[0m"; exit 1; }
			chown root:root "$$dest"; \
			if [[ "$$file" == *.sh ]]; then chmod +x "$$dest"; fi; \
		done
	else
		echo -e "\033[1;33m⚠️ No binary files to copy, skipping...\033[0m"; \
	fi

# Copy systemd services and timers
copy-systemd:
	@if [ -n "$(SERVICE_FILES)" ]; then
		for file in $(SERVICE_FILES); do \
			dest="$(SERVICE_DIR)/$$(basename $$file)"; \
			if [[ ! -f "$$file" ]]; then \
				echo -e "\033[1;31m❌ Error: $$file does not exist! Skipping...\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📂 Copying $$file -> $(SERVICE_DIR)\033[0m"; \
			cp "$$file" "$$dest" || { echo -e "\033[1;31m❌ Error copying $$file to $$dest\033[0m"; exit 1; }
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No service files to copy, skipping...\033[0m"
	fi

# Copy configs
copy-conf:
	@if [ -n "$(CONFIG_FILES)" ]; then
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
			cp "$$file" "$$dest" || { echo -e "\033[1;31m❌ Error copying $$file to $$dest\033[0m"; exit 1; }
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No config files to copy, skipping...\033[0m"
	fi

# Ensure log files exist
ensure-logs:
	@if [ -n "$(LOGS_FILES)" ]; then \
		for file in $(LOGS_FILES); do \
			dest="$(LOGS_DIR)/$$(basename $$file)"; \
			if [[ -f "$$dest" ]]; then \
				echo -e "\033[1;33m⏩ Skipping $$dest: already exists.\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📝 Creating empty log file: $$dest\033[0m"; \
			touch "$$dest" || { echo -e "\033[1;31m❌ Error creating $$dest\033[0m"; exit 1; }; \
			chown root:root "$$dest"; \
		done \
	else \
		echo -e "\033[1;33m⚠️ No log files specified, skipping...\033[0m"; \
	fi

# Copy cron files
copy-cron:
	@if [ -n "$(CRON_FILES)" ]; then
		for file in $(CRON_FILES); do \
			dest="$(CRON_DIR)/$$(basename $$file)"; \
			if [[ ! -f "$$file" ]]; then \
				echo -e "\033[1;31m❌ Error: $$file does not exist! Skipping...\033[0m"; \
				continue; \
			fi; \
			echo -e "\033[1;32m📂 Copying $$file -> $(CRON_DIR)\033[0m"; \
			cp "$$file" "$$dest" || { echo -e "\033[1;31m❌ Error copying $$file to $$dest\033[0m"; exit 1; }
			chown root:root "$$dest"; \
		done
	else
		echo -e "\033[1;33m⚠️ No cron files to copy, skipping...\033[0m"
	fi

# Launch timers from the list of services
launch-timers:
	@if [ -n "$(SERVICE_FILES)" ]; then
		for file in $(SERVICE_FILES); do \
			if [[ "$$file" == *.timer ]]; then \
				echo -e "\033[1;32m⏳ Enabling and starting $$file...\033[0m"; \
				systemctl enable "$(SERVICE_DIR)/$$file" || { echo -e "\033[1;31m❌ Error enabling $$file\033[0m"; exit 1; }
				systemctl start "$(SERVICE_DIR)/$$file" || { echo -e "\033[1;31m❌ Error starting $$file\033[0m"; exit 1; }
			fi; \
		done
	fi


# Updating systemd
updating-systemd:
	@echo -e "\033[1;34m🔄 Reloading systemd...\033[0m"
	@systemctl daemon-reload

# Restart cron
restart-cron:
	@if [[ "$(CRON_FILES)" != "" ]]; then \
		echo -e "\033[1;34m🔄 Restarting cron service...\033[0m"; \
		systemctl restart cron || systemctl restart crond; \
	fi

