ARG FREESCOUT_IMAGE=ghcr.io/nfrastack/container-freescout:2.2.21-php8.5-alpine_3.24@sha256:5a1bc12791842f4b060adc524d97be206a2b057c2fadfc643dc9dfcd9b63bbf0

FROM ${FREESCOUT_IMAGE} AS source

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

LABEL org.opencontainers.image.source="https://github.com/TelesCoop/freescout-lasuite"

ARG PHP_PKG=php85
ARG UID=1000
ARG GID=1000

RUN addgroup -g ${GID} freescout \
    && adduser -u ${UID} -G freescout -s /bin/sh -D freescout

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        nginx \
        procps-ng \
        supervisor \
        ${PHP_PKG} \
        ${PHP_PKG}-fpm \
        ${PHP_PKG}-bcmath \
        ${PHP_PKG}-ctype \
        ${PHP_PKG}-curl \
        ${PHP_PKG}-dom \
        ${PHP_PKG}-fileinfo \
        ${PHP_PKG}-gd \
        ${PHP_PKG}-iconv \
        ${PHP_PKG}-imap \
        ${PHP_PKG}-intl \
        ${PHP_PKG}-mbstring \
        ${PHP_PKG}-openssl \
        ${PHP_PKG}-pcntl \
        ${PHP_PKG}-pdo \
        ${PHP_PKG}-pdo_mysql \
        ${PHP_PKG}-pdo_pgsql \
        ${PHP_PKG}-phar \
        ${PHP_PKG}-session \
        ${PHP_PKG}-simplexml \
        ${PHP_PKG}-sodium \
        ${PHP_PKG}-tokenizer \
        ${PHP_PKG}-xml \
        ${PHP_PKG}-xmlwriter \
        ${PHP_PKG}-zip \
    && ln -sf /usr/bin/${PHP_PKG} /usr/bin/php \
    && ln -sf /usr/sbin/php-fpm${PHP_PKG#php} /usr/sbin/php-fpm \
    && php -v \
    && php-fpm -v \
    && sed -E -i 's|^;?error_log = .*|error_log = /proc/self/fd/2|' /etc/${PHP_PKG}/php-fpm.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && mkdir -p \
        /data \
        /var/run/nginx \
        /var/run/php-fpm \
        /var/run/supervisord \
        /var/lib/nginx/tmp \
    && chown -R ${UID}:${GID} \
        /data \
        /var/run/nginx \
        /var/run/php-fpm \
        /var/run/supervisord \
        /var/lib/nginx

# The code stays owned by root: the runtime user only writes Laravel's caches, the generated JS/CSS and /data.
COPY --from=source /container/data/freescout/install /var/www/html
COPY modules/ /var/www/html/Modules/
RUN mkdir -p /usr/src \
    && mv /var/www/html/storage /usr/src/freescout-storage \
    && ln -s /data/storage /var/www/html/storage \
    && ln -s /data/.env /var/www/html/.env \
    && rm -rf /var/www/html/public/storage \
    && ln -s /var/www/html/storage/app/public /var/www/html/public/storage \
    && mkdir -p /var/www/html/public/modules \
    && for module_manifest in /var/www/html/Modules/*/module.json; do \
           [ -f "${module_manifest}" ] || { echo "No module in modules/: run git submodule update --init" >&2; exit 1; }; \
           module_dir=$(dirname "${module_manifest}"); \
           module_alias=$(php -r 'echo json_decode(file_get_contents($argv[1]))->alias;' -- "${module_manifest}"); \
           ln -s "${module_dir}/Public" "/var/www/html/public/modules/${module_alias}"; \
       done \
    && chown -R ${UID}:${GID} \
        /var/www/html/bootstrap/cache \
        /var/www/html/public/js/builds \
        /var/www/html/public/css/builds

COPY docker/nginx/nginx.conf     /etc/nginx/nginx.conf
COPY docker/nginx/freescout.conf /etc/nginx/http.d/default.conf
COPY docker/nginx/health.conf    /etc/nginx/http.d/health.conf
COPY docker/php/www.conf         /etc/${PHP_PKG}/php-fpm.d/www.conf
COPY docker/php/php.ini          /etc/${PHP_PKG}/conf.d/99-freescout.ini
COPY docker/supervisord.conf     /etc/supervisord.conf
COPY --chmod=755 docker/entrypoint.sh    /entrypoint.sh
COPY --chmod=755 docker/worker.sh        /usr/local/bin/worker.sh
COPY --chmod=755 docker/scheduler.sh     /usr/local/bin/scheduler.sh
COPY --chmod=755 docker/exit-on-fatal.sh /usr/local/bin/exit-on-fatal.sh

WORKDIR /var/www/html
EXPOSE 8080
USER ${UID}:${GID}

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-n", "-c", "/etc/supervisord.conf"]
