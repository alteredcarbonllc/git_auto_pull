SHELL := /bin/bash
.ONESHELL:

# Пути назначения
BIN_DIR := /usr/bin
SERVICE_DIR := /etc/systemd/system
ETC_DIR := /etc
CRON_DIR := /etc/cron.d

# Что копировать куда
BIN_FILES := git_auto_pull.sh
SERVICE_FILES := git_auto_pull.timer
CONFIG_FILES := git_auto_pull.conf
CRON_FILES := git_auto_pull

# Таймеры для активации
TIMER_FILES := git_auto_pull.timer

REINSTALL ?= false

.PHONY: install
install:
	# Проверка root-прав
	if [[ "$$(id -u)" -ne 0 ]]; then
		echo -e "\033[1;31m❌ Error: This script must be run as root!❌\033[0m" >&2; \
		exit 1
	fi

	# Стартовая линия
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	echo -e "\033[1;32m🔧 Starting installation...\033[0m"
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"

	# Копируем бинарники
	for file in $(BIN_FILES); do \
		dest="$(BIN_DIR)/$$(basename $$file)"; \
		echo -e "\033[1;32m📂 Copying $$file -> $(BIN_DIR)\033[0m"; \
		cp "$$file" "$$dest"; \
		chown root:root "$$dest"; \
		if [[ "$$file" == *.sh ]]; then chmod +x "$$dest"; fi; \
	done

	# Копируем systemd сервисы и таймеры
	for file in $(SERVICE_FILES); do \
		dest="$(SERVICE_DIR)/$$(basename $$file)"; \
		echo -e "\033[1;32m📂 Copying $$file -> $(SERVICE_DIR)\033[0m"; \
		cp "$$file" "$$dest"; \
		chown root:root "$$dest"; \
	done

	# Копируем конфиги
	for file in $(CONFIG_FILES); do \
		dest="$(ETC_DIR)/$$(basename $$file)"; \
		if [[ "$$file" == *.conf && -f "$$dest" && "$(REINSTALL)" == "false" ]]; then \
			echo -e "\033[1;33m⏩ Skipping $$file: already exists.\033[0m"; \
			continue; \
		fi; \
		echo -e "\033[1;32m📂 Copying $$file -> $(ETC_DIR)\033[0m"; \
		cp "$$file" "$$dest"; \
		chown root:root "$$dest"; \
	done

	# Копируем cron-файлы
	for file in $(CRON_FILES); do \
		dest="$(CRON_DIR)/$$(basename $$file)"; \
		echo -e "\033[1;32m📂 Copying $$file -> $(CRON_DIR)\033[0m"; \
		cp "$$file" "$$dest"; \
		chown root:root "$$dest"; \
	done

	# Обновляем systemd
	echo -e "\033[1;34m🔄 Reloading systemd...\033[0m"
	systemctl daemon-reload

	# Запускаем таймеры
	for timer in $(TIMER_FILES); do \
		echo -e "\033[1;32m⏳ Enabling and starting $$timer...\033[0m"; \
		systemctl enable "$$timer"; \
		systemctl start "$$timer"; \
	done

	# Перезапуск cron
	if [[ "$(CRON_FILES)" != "" ]]; then \
		echo -e "\033[1;34m🔄 Restarting cron service...\033[0m"; \
		systemctl restart cron || systemctl restart crond; \
	fi

	# Завершающая линия
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"
	echo -e "\033[1;32m✔️ Installation completed successfully!\033[0m"
	echo -e "\033[1;34m═══════════════════════════════════════════════════════════════════\033[0m"


