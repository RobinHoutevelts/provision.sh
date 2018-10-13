#! /bin/bash
help_text <<EOF
Elasticsearch 5.1.1

if arg 1 is 'public' elastic will be reachable on 9200
EOF

if ! dpkg --status "oracle-java8-installer" >/dev/null 2>&1; then
    add-apt-repository ppa:webupd8team/java
    apt-get update
    install oracle-java8-installer
fi

if ! dpkg --status "elasticsearch" >/dev/null 2>&1; then
    wget -O /tmp/elastic.deb 'https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-5.5.2.deb'
    dpkg -i /tmp/elastic.deb
fi

cp "$1/elasticsearch.yml" /etc/elasticsearch/
cp "$1/jvm.options" /etc/elasticsearch/

if [ "$2" == "public" ]; then
    ufw allow 9200
    replace_line \
        /etc/elasticsearch/elasticsearch.yml \
        '^network.host.*$' \
        'network.host: 0.0.0.0'
fi

systemctl restart elasticsearch.service
