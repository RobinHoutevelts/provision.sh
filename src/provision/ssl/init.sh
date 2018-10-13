#! /bin/bash

help_text <<EOF
Copy SSL cert
EOF

if [ ! -d "$1/drp" ]; then
  echo "$1: No drp directory found."
  exit 1;
fi

mkdir -p /etc/nginx/ssl

rm -rf /etc/nginx/ssl/drp
cp -R "$1/drp" /etc/nginx/ssl/drp