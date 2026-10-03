# Debian 13 (trixie) development image with Apache and PHP.
# MySQL runs in the separate "db" service defined in compose.yaml.
FROM debian:trixie

ARG PHP_VERSION=__PHP_VERSION__
ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=${USER_UID}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PHP_VERSION=${PHP_VERSION} \
    APACHE_DOCUMENT_ROOT=/workspace

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Base development tools and libraries.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-utils bash-completion build-essential bzip2 ca-certificates curl \
        default-mysql-client dnsutils git gnupg htop iproute2 iputils-ping jq \
        less locales lsof make man-db nano netcat-openbsd openssh-client \
        procps psmisc rsync sudo tar tzdata unzip vim-tiny wget xz-utils zip \
    && rm -rf /var/lib/apt/lists/*

# Latest PHP from the packages.sury.org repository (Debian's maintainer for PHP).
RUN curl -fsSLo /tmp/debsuryorg-archive-keyring.deb https://packages.sury.org/debsuryorg-archive-keyring.deb \
    && dpkg -i /tmp/debsuryorg-archive-keyring.deb \
    && rm /tmp/debsuryorg-archive-keyring.deb \
    && . /etc/os-release \
    && printf 'Types: deb\nURIs: https://packages.sury.org/php/\nSuites: %s\nComponents: main\nSigned-By: /usr/share/keyrings/debsuryorg-archive-keyring.gpg\n' \
        "${VERSION_CODENAME}" > /etc/apt/sources.list.d/php.sources \
    && apt-get update \
    && extra="" \
    && if apt-cache show "php${PHP_VERSION}-opcache" >/dev/null 2>&1; then extra="php${PHP_VERSION}-opcache"; fi \
    && apt-get install -y --no-install-recommends \
        apache2 \
        "libapache2-mod-php${PHP_VERSION}" \
        "php${PHP_VERSION}-cli" \
        "php${PHP_VERSION}-common" \
        "php${PHP_VERSION}-bcmath" \
        "php${PHP_VERSION}-curl" \
        "php${PHP_VERSION}-gd" \
        "php${PHP_VERSION}-intl" \
        "php${PHP_VERSION}-mbstring" \
        "php${PHP_VERSION}-mysql" \
        "php${PHP_VERSION}-readline" \
        "php${PHP_VERSION}-sqlite3" \
        "php${PHP_VERSION}-xdebug" \
        "php${PHP_VERSION}-xml" \
        "php${PHP_VERSION}-zip" \
        ${extra} \
    && update-alternatives --set php "/usr/bin/php${PHP_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Composer (latest 2.x).
COPY --from=composer/composer:latest-bin /composer /usr/bin/composer

# Non-root user for VS Code, with passwordless sudo.
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash \
        --groups adm,www-data "${USERNAME}" \
    && echo "${USERNAME} ALL=(root) NOPASSWD:ALL" > "/etc/sudoers.d/${USERNAME}" \
    && chmod 0440 "/etc/sudoers.d/${USERNAME}"

# Apache: run as the dev user so the app can write to the workspace.
COPY apache-vhost.conf /etc/apache2/sites-available/000-default.conf
COPY php-dev.ini /tmp/99-devcontainer.ini
COPY mysql-client.cnf /etc/mysql/conf.d/devcontainer.cnf
RUN sed -i \
        -e "s/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=${USERNAME}/" \
        -e "s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=${USERNAME}/" \
        /etc/apache2/envvars \
    && echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf \
    && a2enconf servername \
    && a2enmod rewrite headers expires \
    && for sapi in apache2 cli; do \
        cp /tmp/99-devcontainer.ini "/etc/php/${PHP_VERSION}/${sapi}/conf.d/99-devcontainer.ini"; \
    done \
    && rm /tmp/99-devcontainer.ini

COPY --chmod=0755 entrypoint.sh /usr/local/bin/devcontainer-entrypoint

EXPOSE 80
ENTRYPOINT ["/usr/local/bin/devcontainer-entrypoint"]
CMD ["sleep", "infinity"]
