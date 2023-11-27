#!/bin/bash

# Функция для логирования
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

# Функция для отката изменений
rollback() {
    log "Ошибка! Восстановление исходных файлов..."
    sudo cp -f "/etc/postfix/main.cf.bak" "/etc/postfix/main.cf"
    sudo cp -f "/etc/dovecot/conf.d/10-mail.conf.bak" "/etc/dovecot/conf.d/10-mail.conf"
    sudo rm -f "/etc/dovecot/dovecot-users"
    sudo rm -rf "/etc/opendkim/keys/$DOMAIN"
    log "Исходные файлы восстановлены."
    exit 1
}

# Проверка наличия прав суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    log "Этот скрипт должен быть запущен с правами суперпользователя (root)."
    exit 1
fi

# Запрос домена
read -p "Введите ваш домен (например, example.com): " DOMAIN
EMAIL="admin@$DOMAIN"

# Запрос пароля
read -sp "Введите ваш пароль: " PASSWORD
echo

# Пути к резервным копиям файлов конфигурации
POSTFIX_MAIN_CF_BAK="/etc/postfix/main.cf.bak"
DOVECOT_10_MAIL_CONF_BAK="/etc/dovecot/conf.d/10-mail.conf.bak"

# Создание резервных копий файлов конфигурации
if [ -f "$POSTFIX_MAIN_CF_BAK" ] || [ -f "$DOVECOT_10_MAIL_CONF_BAK" ]; then
    log "Резервные копии файлов конфигурации уже существуют. Продолжаем..."
else
    sudo cp -f "/etc/postfix/main.cf" "$POSTFIX_MAIN_CF_BAK"
    sudo cp -f "/etc/dovecot/conf.d/10-mail.conf" "$DOVECOT_10_MAIL_CONF_BAK"
    log "Созданы резервные копии файлов конфигурации."
fi

# Обработка ошибок и откат изменений при ошибке
trap 'rollback' ERR

# Обновление и установка необходимых пакетов
log "Обновление системы и установка необходимых пакетов..."
if ! sudo apt update || ! sudo apt install -y postfix dovecot-core dovecot-imapd opendkim opendkim-tools certbot apache2 php libapache2-mod-php; then
    log "Ошибка при установке пакетов. Проверьте наличие интернет-соединения и попробуйте еще раз."
    exit 1
fi

# Конфигурация Postfix
log "Настройка Postfix..."
if ! sudo postconf -e "myhostname = $DOMAIN" ||
   ! sudo postconf -e "mydestination = $DOMAIN, localhost.localdomain, localhost" ||
   ! sudo postconf -e "mynetworks = 127.0.0.0/8, [::1]/128" ||
   ! sudo postconf -e "inet_interfaces = all"; then
    log "Ошибка при настройке Postfix."
    exit 1
fi

# Конфигурация Dovecot
log "Настройка Dovecot..."
DOVECOT_CONF="/etc/dovecot/conf.d/10-mail.conf"
if ! echo "mail_location = mbox:~/mail:INBOX=/var/mail/%u" | sudo tee -a "$DOVECOT_CONF"; then
    log "Ошибка при настройке Dovecot."
    exit 1
fi

# Создание пользователя и пароля для Dovecot
log "Настройка аутентификации Dovecot..."
ENCRYPTED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")
if ! echo "$EMAIL:$ENCRYPTED_PASS" | sudo tee "/etc/dovecot/dovecot-users"; then
    log "Ошибка при создании пользователя Dovecot."
    exit 1
fi

# Создание и настройка ключей DKIM
log "Настройка DKIM..."
DKIM_KEY_DIR="/etc/opendkim/keys/$DOMAIN"
if [ -d "$DKIM_KEY_DIR" ]; then
    log "Ключи DKIM уже существуют. Продолжаем..."
else
    sudo mkdir -p "$DKIM_KEY_DIR" &&
    sudo opendkim-genkey -b 2048 -D "$DKIM_KEY_DIR" -d "$DOMAIN" -s mail &&
    sudo chown opendkim:opendkim "$DKIM_KEY_DIR"/* &&
    sudo chmod 600 "$DKIM_KEY_DIR"/*
    log "Созданы и настроены ключи DKIM."
fi

# Настройка OpenDKIM
OPENDKIM_CONF="/etc/opendkim.conf"
if ! echo "Domain                  $DOMAIN" | sudo tee -a "$OPENDKIM_CONF" ||
   ! echo "KeyFile                 /etc/opendkim/keys/$DOMAIN/mail.private" | sudo tee -a "$OPENDKIM_CONF" ||
   ! echo "Selector                mail" | sudo tee -a "$OPENDKIM_CONF"; then
    log "Ошибка при настройке OpenDKIM."
    exit 1
fi

# Интеграция OpenDKIM с Postfix
log "Интеграция OpenDKIM с Postfix..."
if ! sudo postconf -e "milter_default_action = accept" ||
   ! sudo postconf -e "milter_protocol = 2" ||
   ! sudo postconf -e "smtpd_milters = inet:localhost:12301" ||
   ! sudo postconf -e "non_smtpd_milters = inet:localhost:12301"; then
    log "Ошибка при интеграции OpenDKIM с Postfix."
    exit 1
fi

# Получение SSL сертификата Let's Encrypt
log "Получение сертификата Let's Encrypt..."
if ! sudo certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --email "$EMAIL"; then
    log "Ошибка при получении сертификата Let's Encrypt."
    exit 1
fi

# Настройка SSL для Postfix и Dovecot
log "Настройка SSL для Postfix и Dovecot..."
if ! sudo postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/$DOMAIN/fullchain.pem" ||
   ! sudo postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/$DOMAIN/privkey.pem" ||
   ! sudo postconf -e "smtpd_use_tls = yes"; then
    log "Ошибка при настройке SSL для Postfix и Dovecot."
    exit 1
fi

# Установка и настройка Roundcube
log "Установка и настройка Roundcube..."
if ! sudo apt install -y roundcube roundcube-mysql ||
   ! sudo ln -s /etc/roundcube/apache.conf /etc/apache2/conf-available/roundcube.conf ||
   ! sudo a2enconf roundcube ||
   ! sudo service apache2 reload; then
    log "Ошибка при установке и настройке Roundcube."
    exit 1
fi

if ! echo "ssl_cert = </etc/letsencrypt/live/$DOMAIN/fullchain.pem" | sudo tee -a "$DOVECOT_CONF" ||
   ! echo "ssl_key = </etc/letsencrypt/live/$DOMAIN/privkey.pem" | sudo tee -a "$DOVECOT_CONF"; then
    log "Ошибка при настройке SSL для Dovecot."
    exit 1
fi

# Перезапуск служб
log "Перезапуск служб..."
if ! sudo systemctl restart postfix ||
   ! sudo systemctl restart dovecot ||
   ! sudo systemctl restart opendkim; then
    log "Ошибка при перезапуске служб."
    exit 1
fi

# Очистка ловушки
trap - ERR

# Вывод информации
log "Информация для DNS-настройки:"
echo "--------------------------------------------------"
echo "|      Тип записи      |               Значение              |"
echo "--------------------------------------------------"
echo "|        DKIM           | mail._domainkey IN TXT \"v=DKIM1; k=rsa; p=$DKIM_RECORD\" |"
echo "--------------------------------------------------"
echo "|         SPF           |       @ IN TXT \"v=spf1 mx -all\"     |"
echo "--------------------------------------------------"
echo ""
log "Используйте следующие порты для подключения:"
echo "--------------------------------"
echo "| Порт |     Протокол     |"
echo "--------------------------------"
echo "|  143 | IMAP (без SSL)   |"
echo "--------------------------------"
echo "|  993 |   IMAP (с SSL)   |"
echo "--------------------------------"
echo "|   25 | SMTP (без SSL)   |"
echo "--------------------------------"
echo "|  587 | SMTP (с SSL/TLS) |"
echo "--------------------------------"
echo ""
log "Информация для входа:"
echo "----------------------------------"
echo "|    Логин    |    Пароль    |"
echo "----------------------------------"
echo "| $EMAIL | $PASSWORD |"
echo "----------------------------------"

# Вывод информации о веб-интерфейсе
log "Доступ к веб-панели почты (Roundcube):"
echo "--------------------------------"
echo "|          URL           |"
echo "--------------------------------"
echo "| http://$DOMAIN/roundcube |"
echo "--------------------------------"
