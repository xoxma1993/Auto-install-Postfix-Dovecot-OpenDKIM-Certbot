#!/bin/bash

# Функция для логирования
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

# Функция для отката изменений
rollback() {
    local domain="$1"
    log "Ошибка! Восстановление исходных файлов для домена $domain..."
    sudo cp -f "/etc/postfix/main.cf.bak.$domain" "/etc/postfix/main.cf"
    sudo cp -f "/etc/dovecot/conf.d/10-mail.conf.bak.$domain" "/etc/dovecot/conf.d/10-mail.conf"
    sudo rm -f "/etc/dovecot/dovecot-users.$domain"
    sudo rm -rf "/etc/opendkim/keys/$domain"
    log "Исходные файлы восстановлены для домена $domain."
}

# Проверка наличия прав суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    log "Этот скрипт должен быть запущен с правами суперпользователя (root)."
    exit 1
fi

# Запрос доменного имени
read -p "Введите доменное имя (например, example.com): " DOMAIN

# Запрос пароля от аккаунта
read -s -p "Введите пароль от аккаунта для домена $DOMAIN: " PASSWORD

# Обработка ошибок и откат изменений при ошибке
trap 'rollback $DOMAIN' ERR

EMAIL="admin@$DOMAIN"
WEBMAIL_SUBDOMAIN="webmail.$DOMAIN"
IMAP_SUBDOMAIN="imap.$DOMAIN"
SMTP_SUBDOMAIN="smtp.$DOMAIN"

# Создание резервных копий файлов конфигурации
POSTFIX_MAIN_CF_BAK="/etc/postfix/main.cf.bak.$DOMAIN"
DOVECOT_10_MAIL_CONF_BAK="/etc/dovecot/conf.d/10-mail.conf.bak.$DOMAIN"

if [ -f "$POSTFIX_MAIN_CF_BAK" ] || [ -f "$DOVECOT_10_MAIL_CONF_BAK" ]; then
    log "Резервные копии файлов конфигурации для домена $DOMAIN уже существуют. Продолжаем..."
else
    sudo cp -f "/etc/postfix/main.cf" "$POSTFIX_MAIN_CF_BAK"
    sudo cp -f "/etc/dovecot/conf.d/10-mail.conf" "$DOVECOT_10_MAIL_CONF_BAK"
    log "Созданы резервные копии файлов конфигурации для домена $DOMAIN."
fi

# Установка необходимых компонентов, если их нет
log "Установка необходимых компонентов..."
sudo apt update

for pkg in apache2 postfix dovecot-core dovecot-imapd dovecot-pop3d opendkim-tools roundcube roundcube-mysql certbot; do
    if ! dpkg -l | grep -q $pkg; then
        sudo apt install -y $pkg
    fi
done

# Генерация DKIM записи
DKIM_RECORD=$(sudo opendkim-genkey -b 2048 -t -D "/etc/opendkim/keys/$DOMAIN" -d "$DOMAIN" -s mail | grep -o -P '(?<=p=).*(?=")')

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

# Дополнительные настройки для отправки от этого домена
smtp_generic_maps = hash:/etc/postfix/generic/$DOMAIN
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

# Дополнительные настройки для этого домена
default_internal_user = vmail
default_internal_group = vmail
EOL

# Настройка OpenDKIM
log "Настройка OpenDKIM для домена $DOMAIN..."
cat <<EOL | sudo tee "/etc/opendkim.conf.$DOMAIN"
Domain                  $DOMAIN
KeyFile                 /etc/opendkim/keys/$DOMAIN/mail.private
Selector                mail

# Дополнительные настройки для этого домена
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

# Создание виртуального хоста для поддомена imap
log "Создание виртуального хоста для поддомена $IMAP_SUBDOMAIN..."
cat <<EOL | sudo tee "/etc/apache2/sites-available/$IMAP_SUBDOMAIN.conf"
<VirtualHost *:80>
    ServerAdmin webmaster@$DOMAIN
    ServerName $IMAP_SUBDOMAIN
    DocumentRoot /var/www/imap

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOL

# Создание виртуального хоста для поддомена smtp
log "Создание виртуального хоста для поддомена $SMTP_SUBDOMAIN..."
cat <<EOL | sudo tee "/etc/apache2/sites-available/$SMTP_SUBDOMAIN.conf"
<VirtualHost *:80>
    ServerAdmin webmaster@$DOMAIN
    ServerName $SMTP_SUBDOMAIN
    DocumentRoot /var/www/smtp

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOL

# Создание страницы приветствия на основном домене
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
    <ul>
        <li><a href="http://$WEBMAIL_SUBDOMAIN">Веб-панель почты</a></li>
        <li><a href="http://$IMAP_SUBDOMAIN">IMAP сервер</a></li>
        <li><a href="http://$SMTP_SUBDOMAIN">SMTP сервер</a></li>
    </ul>
    <p>Информация о настройках:</p>
    <ul>
        <li>DKIM: mail._domainkey IN TXT "v=DKIM1; k=rsa; p=$DKIM_RECORD"</li>
        <li>SPF: @ IN TXT "v=spf1 mx -all"</li>
        <li>Логин: $EMAIL</li>
        <li>Пароль: $PASSWORD</li>  # Используйте введенный пароль
    </ul>
</body>
</html>
EOL

# Активация виртуальных хостов и перезагрузка Apache
sudo a2ensite "$WEBMAIL_SUBDOMAIN.conf"
sudo a2ensite "$IMAP_SUBDOMAIN.conf"
sudo a2ensite "$SMTP_SUBDOMAIN.conf"
sudo service apache2 reload

# Вывод информации о настройках
log "Информация о настройках для домена $DOMAIN:"
echo "--------------------------------------------------"
echo "|      Тип записи      |               Значение              |"
echo "--------------------------------------------------"
echo "|        DKIM           | mail._domainkey IN TXT \"v=DKIM1; k=rsa; p=$DKIM_RECORD\" |"
echo "--------------------------------------------------"
echo "|         SPF           |       @ IN TXT \"v=spf1 mx -all\"     |"
echo "--------------------------------------------------"
echo ""
log "Используйте следующие порты для подключения для домена $DOMAIN:"
echo "--------------------------------"
echo "| Порт |     Протокол     |     Хост     |"
echo "--------------------------------"
echo "|  143 | IMAP (без SSL)   | $IMAP_SUBDOMAIN |"
echo "--------------------------------"
echo "|  993 |   IMAP (с SSL)   | $IMAP_SUBDOMAIN |"
echo "--------------------------------"
echo "|   25 | SMTP (без SSL)   | $SMTP_SUBDOMAIN |"
echo "--------------------------------"
echo "|  587 | SMTP (с SSL/TLS) | $SMTP_SUBDOMAIN |"
echo "--------------------------------"
echo ""
log "Информация для входа в почтовый ящик для домена $DOMAIN:"
echo "----------------------------------"
echo "|    Логин    |    Пароль    |"
echo "----------------------------------"
echo "| $EMAIL | $PASSWORD |"  # Используйте введенный пароль
echo "----------------------------------"

# Очистка ловушки
trap - ERR
