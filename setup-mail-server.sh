#!/bin/bash

# Функция для логирования
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

# Функция для отката изменений для одного домена
rollback_domain() {
    local domain="$1"
    log "Ошибка! Восстановление исходных файлов для домена $domain..."
    sudo cp -f "/etc/postfix/main.cf.bak.$domain" "/etc/postfix/main.cf"
    sudo cp -f "/etc/dovecot/conf.d/10-mail.conf.bak.$domain" "/etc/dovecot/conf.d/10-mail.conf"
    sudo rm -f "/etc/dovecot/dovecot-users.$domain"
    sudo rm -rf "/etc/opendkim/keys/$domain"
    log "Исходные файлы восстановлены для домена $domain."
}

# Функция для отката изменений для всех доменов при ошибке
rollback_all_domains() {
    log "Произошла ошибка! Откат изменений для всех доменов..."
    for DOMAIN in "${DOMAINS[@]}"; do
        rollback_domain "$DOMAIN"
    done
    exit 1
}

# Проверка наличия прав суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    log "Этот скрипт должен быть запущен с правами суперпользователя (root)."
    exit 1
fi

# Запрос списка доменов
read -p "Введите список доменов (разделенных пробелами): " DOMAINS
DOMAINS=($DOMAINS)

# Обработка ошибок и откат изменений при ошибке для всех доменов
trap 'rollback_all_domains' ERR

# Установка необходимых компонентов
log "Установка необходимых компонентов..."
sudo apt update

# Установка компонентов, если их нет
for pkg in apache2 postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim-tools roundcube roundcube-mysql certbot; do
    if ! dpkg -l | grep -q $pkg; then
        sudo apt install -y $pkg
    fi
done

# Цикл по всем доменам
for DOMAIN in "${DOMAINS[@]}"; do
    EMAIL="admin@$DOMAIN"
    WEBMAIL_SUBDOMAIN="webmail.$DOMAIN"

    # Генерация DKIM записи
    DKIM_RECORD=$(sudo opendkim-genkey -b 2048 -t -D "/etc/opendkim/keys/$DOMAIN" -d "$DOMAIN" -s mail | grep -o -P '(?<=p=).*(?=")')

    # Пути к резервным копиям файлов конфигурации
    POSTFIX_MAIN_CF_BAK="/etc/postfix/main.cf.bak.$DOMAIN"
    DOVECOT_10_MAIL_CONF_BAK="/etc/dovecot/conf.d/10-mail.conf.bak.$DOMAIN"

    # Создание резервных копий файлов конфигурации
    if [ -f "$POSTFIX_MAIN_CF_BAK" ] || [ -f "$DOVECOT_10_MAIL_CONF_BAK" ]; then
        log "Резервные копии файлов конфигурации для домена $DOMAIN уже существуют. Продолжаем..."
    else
        sudo cp -f "/etc/postfix/main.cf" "$POSTFIX_MAIN_CF_BAK"
        sudo cp -f "/etc/dovecot/conf.d/10-mail.conf" "$DOVECOT_10_MAIL_CONF_BAK"
        log "Созданы резервные копии файлов конфигурации для домена $DOMAIN."
    fi

    # Дополнительная настройка Postfix, Dovecot, OpenDKIM и других параметров для каждого домена

    # Конфигурация Postfix
    log "Настройка Postfix для домена $DOMAIN..."
    cat <<EOL | sudo tee "/etc/postfix/main.cf.$DOMAIN"
myhostname = $DOMAIN
mydestination = $DOMAIN, localhost.localdomain, localhost
mynetworks = 127.0.0.0/8, [::1]/128
inet_interfaces = all
smtpd_tls_cert_file = /etc/letsencrypt/live/$DOMAIN/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/$DOMAIN/privkey.pem
smtpd_use_tls = yes
EOL

    # Создание файла для мэппинга отправителей
    sudo mkdir -p "/etc/postfix/generic"
    echo "@$DOMAIN   $EMAIL" | sudo tee "/etc/postfix/generic/$DOMAIN"
    sudo postmap "/etc/postfix/generic/$DOMAIN"

    # Конфигурация Dovecot
    log "Настройка Dovecot для домена $DOMAIN..."
    cat <<EOL | sudo tee "/etc/dovecot/conf.d/10-mail.conf.$DOMAIN"
mail_location = mbox:~/mail:INBOX=/var/mail/%u
ssl_cert = </etc/letsencrypt/live/$DOMAIN/fullchain.pem
ssl_key = </etc/letsencrypt/live/$DOMAIN/privkey.pem
EOL

    # Создание пользователя и пароля для Dovecot
    log "Настройка аутентификации Dovecot для домена $DOMAIN..."
    PASSWORD=$(openssl rand -base64 12)
    ENCRYPTED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")
    echo "$EMAIL:$ENCRYPTED_PASS" | sudo tee "/etc/dovecot/dovecot-users.$DOMAIN"

    # Создание и настройка ключей DKIM
    log "Настройка DKIM для домена $DOMAIN..."
    DKIM_KEY_DIR="/etc/opendkim/keys/$DOMAIN"
    if [ ! -d "$DKIM_KEY_DIR" ]; then
        sudo mkdir -p "$DKIM_KEY_DIR"
        sudo opendkim-genkey -b 2048 -D "$DKIM_KEY_DIR" -d "$DOMAIN" -s mail
        sudo chown opendkim:opendkim "$DKIM_KEY_DIR"/*
        sudo chmod 600 "$DKIM_KEY_DIR"/*
        log "Созданы и настроены ключи DKIM для домена $DOMAIN."
    fi

    # Настройка OpenDKIM
    log "Настройка OpenDKIM для домена $DOMAIN..."
    cat <<EOL | sudo tee "/etc/opendkim.conf.$DOMAIN"
Domain                  $DOMAIN
KeyFile                 /etc/opendkim/keys/$DOMAIN/mail.private
Selector                mail
EOL

    # Интеграция OpenDKIM с Postfix
    log "Интеграция OpenDKIM с Postfix для домена $DOMAIN..."
    sudo postconf -e "milter_default_action = accept"
    sudo postconf -e "milter_protocol = 2"
    sudo postconf -e "smtpd_milters = inet:localhost:12301"
    sudo postconf -e "non_smtpd_milters = inet:localhost:12301"

    # Получение SSL сертификата Let's Encrypt
    log "Получение сертификата Let's Encrypt для домена $DOMAIN..."
    sudo certbot certonly --standalone --preferred-challenges http -d "$DOMAIN" --agree-tos --non-interactive --email "$EMAIL"

    # Создание виртуального хоста для поддомена webmail
    log "Создание виртуального хоста для поддомена $WEBMAIL_SUBDOMAIN..."
    cat <<EOL | sudo tee "/etc/apache2/sites-available/$WEBMAIL_SUBDOMAIN.conf"
<VirtualHost *:80>
    ServerAdmin webmaster@$DOMAIN
    ServerName $WEBMAIL_SUBDOMAIN
    DocumentRoot /var/www/webmail

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOL

    # Создание страницы приветствия на основном домене с ссылкой на веб-панель почты
    log "Создание страницы приветствия на основном домене $DOMAIN..."
    cat <<EOL | sudo tee "/var/www/html/index.html"
<!DOCTYPE html>
<html>
<head>
    <title>Добро пожаловать на $DOMAIN</title>
</head>
<body>
    <h1>Добро пожаловать на $DOMAIN</h1>
    <p>Вы можете перейти к веб-панели почты по ссылке:</p>
    <a href="http://$WEBMAIL_SUBDOMAIN">Веб-панель почты</a>
</body>
</html>
EOL

    # Активация виртуального хоста для поддомена и перезагрузка Apache
    sudo a2ensite "$WEBMAIL_SUBDOMAIN.conf"
    sudo service apache2 reload

    # Вывод информации о доступе к веб-панели почты
    log "Доступ к веб-панели почты (Roundcube) для домена $DOMAIN:"
    echo "--------------------------------"
    echo "|          URL           |"
    echo "--------------------------------"
    echo "| http://$WEBMAIL_SUBDOMAIN |"
    echo "--------------------------------"
done

# Очистка ловушки
trap - ERR
