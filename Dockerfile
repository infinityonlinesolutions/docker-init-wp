FROM lead4good/lamp-mysql

RUN apt-get update \
    && apt-get install -y vim wget subversion php5-cli php5-mysql php5-curl curl ca-certificates unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && rm -rf /usr/share/doc /usr/share/man /usr/share/locale /usr/share/info /usr/share/lintian

RUN curl -o /usr/local/bin/wp 'https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar' && chmod +x /usr/local/bin/wp
RUN curl -L -o /usr/local/bin/gdrive 'https://docs.google.com/uc?id=0B3X9GlR6EmbnQ0FtZmJJUXEyRTA&export=download' && chmod +x /usr/local/bin/gdrive

COPY lamp-manager.sh /

CMD ["bash", "lamp-manager.sh"]
