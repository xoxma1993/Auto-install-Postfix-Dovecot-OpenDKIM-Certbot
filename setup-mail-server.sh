#!/bin/bash

# Обновление системы
echo "Обновление системы..."
apt update && apt upgrade -y

# Ввод информации пользователя
echo "Введите доменное имя для сервера: "
read DOMAIN_NAME
echo "Введите пароль для root пользователя MySQL: "
read MYSQL_ROOT_PASSWORD
echo "Введите ваш Cloudflare API Key: "
read CLOUDFLARE_API_KEY
echo "Введите ваш Cloudflare Email: "
read CLOUDFLARE_EMAIL

# Настройка хостнейма
echo $DOMAIN_NAME > /etc/hostname
hostname -F /etc/hostname

# Установка Apache, MySQL и PHP (LAMP Stack)
echo "Установка Apache, MySQL и PHP..."
apt install apache2 mysql-server php libapache2-mod-php php-mysql -y

# Настройка MySQL
echo "Настройка MySQL..."
mysql -u root <<-EOF
UPDATE mysql.user SET Password = PASSWORD('$MYSQL_ROOT_PASSWORD') WHERE User = 'root';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
EOF

# Установка Postfix и Dovecot
echo "Установка Postfix и Dovecot..."
DEBIAN_FRONTEND=noninteractive apt install postfix dovecot-core dovecot-imapd -y

# Базовая настройка Postfix
postconf -e "myhostname = $DOMAIN_NAME"
postconf -e 'smtpd_tls_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem'
postconf -e 'smtpd_tls_key_file=/etc/ssl/private/ssl-cert-snakeoil.key'
postconf -e 'smtpd_use_tls=yes'

# Базовая настройка Dovecot
echo "Настройка Dovecot..."
echo "ssl = yes" >> /etc/dovecot/conf.d/10-ssl.conf

# Установка Roundcube
echo "Установка Roundcube..."
apt install roundcube roundcube-core roundcube-mysql roundcube-plugins -y
echo "Include /etc/roundcube/apache.conf" >> /etc/apache2/apache2.conf

# Установка phpMyAdmin
echo "Установка phpMyAdmin..."
apt install phpmyadmin -y
echo "Include /etc/phpmyadmin/apache.conf" >> /etc/apache2/apache2.conf

# Перезагрузка Apache
systemctl restart apache2

# Генерация DKIM ключа
echo "Генерация DKIM ключа..."
apt install opendkim opendkim-tools -y
opendkim-genkey -t -s mail -d $DOMAIN_NAME
chown opendkim:opendkim mail.private mail.txt
mv mail.private /etc/opendkim/
mv mail.txt /etc/opendkim/

# Создание рекомендуемых строк для SPF и DMARC записей
SPF_RECORD="v=spf1 mx ~all"
DMARC_RECORD="v=DMARC1; p=none"
DKIM_RECORD=$(cat /etc/opendkim/mail.txt | grep -o "p=.*" | cut -d '"' -f 2)

# Вывод информации для пользователя о DKIM
echo "DKIM запись: $DKIM_RECORD"

# Функция добавления DNS записи
add_dns_record() {
    RECORD_NAME=$1
    RECORD_TYPE=$2
    RECORD_CONTENT=$3
    curl -X POST "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID/dns_records" \
         -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
         -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"$RECORD_TYPE\",\"name\":\"$RECORD_NAME\",\"content\":\"$RECORD_CONTENT\"}"
}

# Получение ID зоны Cloudflare
CLOUDFLARE_ZONE_ID=$(curl -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN_NAME&status=active" \
                     -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
                     -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
                     -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*')

# Добавление DNS записей
add_dns_record "@" "SPF" "$SPF_RECORD"
add_dns_record "@" "DMARC" "$DMARC_RECORD"
add_dns_record "mail._domainkey" "TXT" "$DKIM_RECORD"

# Инструкции по настройке почтового клиента
echo "Инструкции по настройке почтового клиента:"
echo "Используйте следующие параметры:"
echo "IMAP сервер: $DOMAIN_NAME, порт 993, SSL/TLS"
echo "SMTP сервер: $DOMAIN_NAME, порт 465, SSL/TLS"
echo "Логин: ваш полный email адрес"
echo "Пароль: пароль вашей почтовой учетной записи"

# Завершение установки
echo "Установка почтового сервера и веб-интерфейсов завершена."
echo "SPF, DMARC и DKIM записи добавлены в DNS зону вашего домена через Cloudflare."
echo "Доступ к Roundcube и phpMyAdmin осуществляется через веб-браузер."
