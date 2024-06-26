FROM mysql:8.4.0

RUN apt-get update \
    && apt-get install -y php-cli php-mysql php-curl curl ca-certificates unzip libmysqlcppconn-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/locale /usr/share/info /usr/share/lintian

RUN curl -o /usr/local/bin/wp 'https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar' && chmod +x /usr/local/bin/wp
RUN curl -L -o /usr/local/bin/gdrive 'https://docs.google.com/uc?id=0B3X9GlR6EmbnQ0FtZmJJUXEyRTA&export=download' && chmod +x /usr/local/bin/gdrive
