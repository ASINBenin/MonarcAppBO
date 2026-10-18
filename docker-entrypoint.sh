#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting MONARC BackOffice setup...${NC}"

# Wait for database to be ready
echo -e "${YELLOW}Waiting for MariaDB to be ready...${NC}"
export MYSQL_PWD="${DBPASSWORD_MONARC}"
while ! mysqladmin ping -h"${DBHOST}" -u"${DBUSER_MONARC}" --silent 2>/dev/null; do
    echo "Waiting for MariaDB..."
    sleep 2
done
echo -e "${GREEN}MariaDB is ready!${NC}"

# Development (APP_ENV=development): sources are mounted, dependencies and frontend are built at first start.
# Any other environment uses the image prebuilt by the CI (vendor, node_modules, public resources): nothing is rebuilt.
IS_DEV_ENV=0
if [ "${APP_ENV:-production}" = "development" ]; then
    IS_DEV_ENV=1
fi
if [ "$IS_DEV_ENV" -eq 0 ] && [ ! -f "/var/www/html/monarc/vendor/autoload.php" ]; then
    echo -e "${RED}APP_ENV=${APP_ENV:-production} but the application is not prebuilt (vendor/autoload.php missing).${NC}"
    echo -e "${RED}Use an image built by the CI, or set APP_ENV=development to build at startup.${NC}"
    exit 1
fi

# Check if this is the first run
if [ ! -f "/var/www/html/monarc/.docker-initialized" ]; then
    echo -e "${GREEN}First run detected, initializing application...${NC}"

    cd /var/www/html/monarc

    if [ "$IS_DEV_ENV" -eq 1 ]; then
        # Install composer dependencies (always, to ensure binaries like Phinx are present)
        echo -e "${YELLOW}Installing Composer dependencies...${NC}"
        composer install --no-interaction

        # Create module symlinks
        echo -e "${YELLOW}Creating module symlinks...${NC}"
        mkdir -p module/Monarc
        cd module/Monarc
        # ln -sfn ./../../vendor/monarc/core Core
        # ln -sfn ./../../vendor/monarc/backoffice BackOffice

        # Link the sibling repositories only when they are not already mounted here
        # (linking over an existing directory would create a stray link inside that repository).
        if [ ! -e "Core" ] && [ -d "/var/www/html/zm-core" ]; then
            ln -s /var/www/html/zm-core Core
        fi
        if [ ! -e "BackOffice" ] && [ -d "/var/www/html/zm-backoffice" ]; then
            ln -s /var/www/html/zm-backoffice BackOffice
        fi
        cd /var/www/html/monarc

        # Clone frontend repositories
        echo -e "${YELLOW}Setting up frontend repositories...${NC}"
        mkdir -p node_modules
        cd node_modules

        if [ ! -e "ng_backoffice" ] && [ -d "/var/www/html/ng-backoffice" ]; then
            ln -s /var/www/html/ng-backoffice ng_backoffice
        fi
        if [ ! -e "ng_anr" ] && [ -d "/var/www/html/ng-anr" ]; then
            ln -s /var/www/html/ng-anr ng_anr
        fi

        # if [ ! -d "ng_backoffice" ]; then
        #     git clone --config core.fileMode=false https://github.com/monarc-project/ng-backoffice.git ng_backoffice
        # fi

        # if [ ! -d "ng_anr" ]; then
        #     git clone --config core.fileMode=false https://github.com/monarc-project/ng-anr.git ng_anr
        # fi

        cd /var/www/html/monarc
    else
        echo -e "${YELLOW}Prebuilt image: skipping Composer and frontend setup.${NC}"
    fi

    # Databases are created with the MONARC account, never root. In production they are created
    # beforehand by the database initialisation script; in development the account receives the
    # rights from docker/db-init/10-dev-grants.sh.
    echo -e "${YELLOW}Setting up databases...${NC}"
    for DB in "${DBNAME_MASTER}" "${DBNAME_COMMON}"; do
        if ! mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" -e "USE \`${DB}\`;" 2>/dev/null; then
            echo -e "${YELLOW}Creating database ${DB}...${NC}"
            if ! mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" -e "CREATE DATABASE IF NOT EXISTS \`${DB}\` DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci;"; then
                echo -e "${RED}Database ${DB} does not exist and ${DBUSER_MONARC} is not allowed to create it.${NC}"
                echo -e "${RED}Create it with the database initialisation script first.${NC}"
                exit 1
            fi
        fi
    done

    # Populate monarc_common based on its own state (table count): the database may have been
    # created empty beforehand by the initialisation script.
    COMMON_TABLE_COUNT=$(mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DBNAME_COMMON}';")
    if [ "$COMMON_TABLE_COUNT" -eq 0 ]; then
        echo -e "${YELLOW}Populating common database...${NC}"
        mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" ${DBNAME_COMMON} < db-bootstrap/monarc_structure.sql
        mysql -h"${DBHOST}" -u"${DBUSER_MONARC}" ${DBNAME_COMMON} < db-bootstrap/monarc_data.sql
    else
        echo -e "${YELLOW}Common database already populated, skipping.${NC}"
    fi

    # Scope the session cookie to the BackOffice path prefix, as the FrontOffice entities do,
    # to avoid cookie collisions when the BackOffice and the entities share one domain.
    if [ -n "${PATH_PREFIX:-}" ]; then
        echo "session.cookie_path = ${PATH_PREFIX}" > /etc/php/8.1/apache2/conf.d/session-path.ini
    fi

    TWO_FACTOR_AUTH_ENFORCED_PHP=false
    case "${TWO_FACTOR_AUTH_ENFORCED:-false}" in
        1|true|yes|on) TWO_FACTOR_AUTH_ENFORCED_PHP=true ;;
    esac

    # Emit smtpOptions only if SMTP_HOST is set (same block as the FrontOffice entrypoint).
    SMTP_CONFIG_BLOCK=""
    if [ -n "${SMTP_HOST:-}" ]; then
        SMTP_CONFIG_BLOCK="
    'smtpOptions' => [
        'name'              => '${DOMAIN_BO:-localhost}',
        'host'              => '${SMTP_HOST}',
        'port'              => ${SMTP_PORT:-587},
        'connection_class'  => 'login',
        'connection_config' => [
            'username' => '${SMTP_USER}',
            'password' => '${SMTP_PASSWORD}',
            'ssl'      => 'tls',
        ],
    ],"
    fi

    # Generate local config (always override to match container DB)
    echo -e "${YELLOW}Creating local configuration...${NC}"
    cat > config/autoload/local.php <<EOF
<?php
\$appdir = getenv('APP_DIR') ? getenv('APP_DIR') : '/var/www/html/monarc';
\$string = file_get_contents(\$appdir.'/package.json');
if(\$string === FALSE) {
    \$string = file_get_contents('./package.json');
}
\$package_json = json_decode(\$string, true);

return [
    'doctrine' => [
        'connection' => [
            'orm_default' => [
                'params' => [
                    'host' => '${DBHOST}',
                    'user' => '${DBUSER_MONARC}',
                    'password' => '${DBPASSWORD_MONARC}',
                    'dbname' => '${DBNAME_COMMON}',
                ],
            ],
            'orm_cli' => [
                'params' => [
                    'host' => '${DBHOST}',
                    'user' => '${DBUSER_MONARC}',
                    'password' => '${DBPASSWORD_MONARC}',
                    'dbname' => '${DBNAME_MASTER}',
                ],
            ],
        ],
    ],

    'defaultLanguageIndex' => 1,

     // Languages available for the analysis / DB data.
    'languages' => [
        'fr' => ['index' => 1, 'label' => 'Français'],
        'en' => ['index' => 2, 'label' => 'English'],
        'de' => ['index' => 3, 'label' => 'Deutsch'],
        'nl' => ['index' => 4, 'label' => 'Dutch'],
    ],

    // Languages available for the user interface.
    'activeLanguages' => ['fr', 'en', 'de', 'nl', 'es', 'ro', 'it', 'ja', 'pl', 'pt', 'zh'],

    'appVersion' => \$package_json['version'],

    'checkVersion' => false,
    'appCheckingURL' => 'https://version.monarc.lu/check/MONARC',

    // Settings of the official ansible-ubuntu BackOffice configuration
    'instanceName' => '${INSTANCE_NAME:-MONARC BackOffice}', // label of the 2FA QR code
    'twoFactorAuthEnforced' => ${TWO_FACTOR_AUTH_ENFORCED_PHP},

    'email' => [
        'name' => 'MONARC',
        'from' => '${EMAIL_FROM:-info@monarc.lu}',
    ],
${SMTP_CONFIG_BLOCK}

    'mospApiUrl' => 'https://objects.monarc.lu/api/',

    'monarc' => [
        'ttl' => 60, // timeout
    ],
];
EOF

    if [ "$IS_DEV_ENV" -eq 1 ]; then
        # Update and build frontend and run DB migrations
        echo -e "${YELLOW}Building frontend and running DB migrations...${NC}"
        ./scripts/update-all.sh
    else
        # Same database steps as update-all.sh (and ansible-ubuntu), without rebuilding the image content
        echo -e "${YELLOW}Running DB migrations...${NC}"
        php ./vendor/robmorgan/phinx/bin/phinx migrate -c ./module/Monarc/Core/migrations/phinx.php
        php ./vendor/robmorgan/phinx/bin/phinx migrate -c ./module/Monarc/BackOffice/migrations/phinx.php
        mkdir -p ./data/cache && touch ./data/cache/upgrade && chmod 777 ./data/cache/upgrade
    fi

    # Create initial user and client (seeds are idempotent)
    echo -e "${YELLOW}Creating initial user and client...${NC}"
    php ./vendor/robmorgan/phinx/bin/phinx seed:run -c ./module/Monarc/BackOffice/migrations/phinx.php

    # Set permissions
    echo -e "${YELLOW}Setting permissions...${NC}"
    chown -R www-data:www-data /var/www/html/monarc/data
    chmod -R 775 /var/www/html/monarc/data

    # Mark initialization as complete
    touch /var/www/html/monarc/.docker-initialized
    echo -e "${GREEN}Initialization complete!${NC}"
else
    echo -e "${GREEN}Application already initialized, starting services...${NC}"
fi

# PHP limits, applied at every start (defaults = official values of the ansible-ubuntu deployment)
cat > /etc/php/8.1/apache2/conf.d/99-monarc-limits.ini <<EOF
memory_limit = ${PHP_MEMORY_LIMIT:-4096M}
max_execution_time = ${PHP_MAX_EXECUTION_TIME:-520}
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE:-200M}
post_max_size = ${PHP_POST_MAX_SIZE:-200M}
EOF

# Apache prefork sized for one application per container (Ubuntu defaults allow 150 workers)
cat > /etc/apache2/conf-enabled/zz-monarc-prefork.conf <<EOF
<IfModule mpm_prefork_module>
    StartServers            ${APACHE_START_SERVERS:-2}
    MinSpareServers         ${APACHE_MIN_SPARE_SERVERS:-1}
    MaxSpareServers         ${APACHE_MAX_SPARE_SERVERS:-3}
    MaxRequestWorkers       ${APACHE_MAX_REQUEST_WORKERS:-20}
    MaxConnectionsPerChild  ${APACHE_MAX_CONNECTIONS_PER_CHILD:-500}
</IfModule>
EOF

# Execute the main command
exec "$@"
