#! /bin/bash
help_text <<EOF
Private PHP7.2 fpm nginx mariadb setup.
 - args: colon separated docroots
EOF

include web private
include mailcatcher private
include php 7.2
include mariadb
include ssl

install nginx

if [ -e /etc/php/7.2/fpm/conf.d/10-opcache.ini ]; then
    rm /etc/php/7.2/fpm/conf.d/10-opcache.ini;
fi

rm /etc/nginx/sites-enabled/php7-php7.conf 2>/dev/null || true  # todo: remove once base image is cleaned up
rm /etc/nginx/sites-enabled/php7-seven.conf 2>/dev/null || true # todo: remove once base image is cleaned up
rm /etc/nginx/sites-enabled/default 2>/dev/null || true

for i in ${@:2}; do
    template "$1/nginx.conf" docroot="${docroot}/${i}/web" \
        host="${i}.${DOMAIN} ${DOMAIN}" \
        > /etc/nginx/sites-available/php7-${i}.conf

    ln -sf /etc/nginx/sites-available/php7-${i}.conf \
        /etc/nginx/sites-enabled/php7-${i}.conf

    ensure_dir "${docroot}/${i}/web"
done
fix_user_perms "${webuser}"

template "$1/pool.ini" user="www-main" mail_from="info@$DOMAIN" \
    > /etc/php/7.2/fpm/pool.d/www.conf

cat "$1/20-xdebug.ini" > /etc/php/7.2/fpm/conf.d/20-xdebug.ini

native_service nginx.service
native_service php7.2-fpm.service

