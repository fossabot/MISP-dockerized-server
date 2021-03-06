#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

STARTMSG="[ENTRYPOINT_APACHE]"

MISP_BASE_PATH=/var/www/MISP
MISP_APP_PATH=/var/www/MISP/app
MISP_APP_CONFIG_PATH=$MISP_APP_PATH/Config
MISP_CONFIG=$MISP_APP_CONFIG_PATH/config.php
DATABASE_CONFIG=$MISP_APP_CONFIG_PATH/database.php
EMAIL_CONFIG=$MISP_APP_CONFIG_PATH/email.php
SSL_CERT="/etc/apache2/ssl/cert.pem"
SSL_KEY="/etc/apache2/ssl/key.pem"
SSL_DH_FILE="/etc/apache2/ssl/dhparams.pem"
FOLDER_with_VERSIONS="/var/www/MISP/app/tmp /var/www/MISP/app/files /var/www/MISP/app/Plugin/CakeResque/Config /var/www/MISP/app/Config /var/www/MISP/.gnupg /var/www/MISP/.smime /etc/apache2/ssl"
PID_CERT_CREATER="/etc/apache2/ssl/SSL_create.pid"

# defaults

[ -z $MISP_URL -a -z $MISP_FQDN ] && echo "Please set 'MISP_FQDN' or 'MISP_URL' environment variable in docker-compose.override.yml file for misp-server!!!" && exit
[ -z $MISP_URL -a ! -z $MISP_FQDN ] && export MISP_URL="https://$(echo $MISP_FQDN|cut -d '/' -f 3)"
[ -z $PGP_ENABLE ] && export PGP_ENABLE=0
[ -z $SMIME_ENABLE ] && export SMIME_ENABLE=0
[ -z $MYSQL_HOST ] && export MYSQL_HOST=localhost
[ -z $MYSQL_USER ] && export MYSQL_USER=misp
[ -z $SENDER_ADDRESS ] && export SENDER_ADDRESS="no-reply@$MISP_FQDN"
[ -z $MISP_SALT ] && export MISP_SALT="$(</dev/urandom tr -dc A-Za-z0-9 | head -c 50)"
[ -z $CAKE ] && export CAKE="$MISP_APP_PATH/Console/cake"




function init_pgp(){
    echo "$STARTMSG ###### PGP Key exists and copy it to MISP webroot #######"

    # Copy public key to the right place
    [ -f /var/www/MISP/.gnupg/public.key ] || echo "GNU PGP Key isn't existing. Please add them." && return
    [ -f /var/www/MISP/.gnupg/public.key ] && sudo -u www-data sh -c "cp /var/www/MISP/.gnupg/public.key /var/www/MISP/app/webroot/gpg.asc"

    #sudo -u www-data sh -c "gpg --homedir /var/www/MISP/.gnupg --export --armor $SENDER_ADDRESS > /var/www/MISP/app/webroot/gpg.asc"
}

function init_smime(){
    echo "$STARTMSG ###### S/MIME Cert exists and copy it to MISP webroot #######" 
    ### Set permissions
    chown www-data:www-data /var/www/MISP/.smime
    chmod 500 /var/www/MISP/.smime
    ## Export the public certificate (for Encipherment) to the webroot
    sudo -u www-data sh -c "cp /var/www/MISP/.smime/cert.pem /var/www/MISP/app/webroot/public_certificate.pem"
    #Due to this action, the MISP users will be able to download your public certificate (for Encipherment) by clicking on the footer
    ### Set permissions
    #chown www-data:www-data /var/www/MISP/app/webroot/public_certificate.pem
    sudo -u www-data sh -c "chmod 440 /var/www/MISP/app/webroot/public_certificate.pem"
}

function start_workers(){
    # start Workers for MISP
    su -s /bin/bash -c "/var/www/MISP/app/Console/worker/start.sh" www-data
}

function init_apache() {
    # Apache gets grumpy about PID files pre-existing
    rm -f /run/apache2/apache2.pid
    # execute APACHE2
    /usr/sbin/apache2ctl -DFOREGROUND $1
}

function add_analyze_column(){
    ORIG_FILE="/var/www/MISP/app/View/Elements/Events/eventIndexTable.ctp"
    PATCH_FILE="/eventIndexTable.patch"

    # Backup Orig File
    cp $ORIG_FILE ${ORIG_FILE}.bak
    # Patch file
    patch $ORIG_FILE < $PATCH_FILE
}

function change_php_vars(){
    [ -z ${PHP_MEMORY} ] && PHP_MEMORY=512
    for FILE in $(ls /etc/php/*/apache2/php.ini)
    do
        sed -i "s/memory_limit = .*/memory_limit = ${PHP_MEMORY}M/" $FILE
        sed -i "s/max_execution_time = .*/max_execution_time = 300/" $FILE
        sed -i "s/upload_max_filesize = .*/upload_max_filesize = 50M/" $FILE
        sed -i "s/post_max_size = .*/post_max_size = 50M/" $FILE
    done
}

function init_misp_config(){
    echo "$STARTMSG Configure MISP | Copy MISP default configuration files"
    
    [ -f $MISP_APP_CONFIG_PATH/bootstrap.php ] || cp $MISP_APP_CONFIG_PATH/bootstrap.default.php $MISP_APP_CONFIG_PATH/bootstrap.php
    [ -f $DATABASE_CONFIG ] || cp $MISP_APP_CONFIG_PATH/database.default.php $DATABASE_CONFIG
    [ -f $MISP_APP_CONFIG_PATH/core.php ] || cp $MISP_APP_CONFIG_PATH/core.default.php $MISP_APP_CONFIG_PATH/core.php
    [ -f $MISP_CONFIG ] || cp $MISP_APP_CONFIG_PATH/config.default.php $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Set DB User, Password and Host in database.php"
    sed -i "s/localhost/$MYSQL_HOST/" $DATABASE_CONFIG
    sed -i "s/db\s*login/$MYSQL_USER/" $DATABASE_CONFIG
    sed -i "s/8889/3306/" $DATABASE_CONFIG
    sed -i "s/db\s*password/$MYSQL_PASSWORD/" $DATABASE_CONFIG

    echo "$STARTMSG Configure MISP | Set MISP-Url in config.php"
    sed -i "s_.*baseurl.*=>.*_    \'baseurl\' => \'$MISP_URL\',_" $MISP_CONFIG
    sudo $CAKE baseurl "$MISP_URL"

    echo "$STARTMSG Configure MISP | Set Email in config.php"
    sed -i "s/email@address.com/$SENDER_ADDRESS/" $MISP_CONFIG
    
    echo "$STARTMSG Configure MISP | Set Admin Email in config.php"
    sed -i "s/admin@misp.example.com/$SENDER_ADDRESS/" $MISP_CONFIG

    # echo "Configure MISP | Set GNUPG Homedir in config.php"
    # sed -i "s,'homedir' => '/',homedir'                        => '/var/www/MISP/.gnupg'," $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Change Salt in config.php"
    sed -i "s/'salt'\\s*=>\\s*''/'salt'                        => '$MISP_SALT'/" $MISP_CONFIG

    echo "$STARTMSG Configure MISP | Change Mail type from phpmailer to smtp"
    sed -i "s/'transport'\\s*=>\\s*''/'transport'                        => 'Smtp'/" $EMAIL_CONFIG
    
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

function setup_via_cake_cli(){
    # Initialize user and fetch Auth Key
    #sudo -E $CAKE userInit -q
    #AUTH_KEY=$(mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -h $MYSQL_HOST $MYSQL_DATABASE -e "SELECT authkey FROM users;" | head -2| tail -1)
    # Setup some more MISP default via cake CLI
    sudo $CAKE baseurl "$MISP_URL"
    # Tune global time outs
    sudo $CAKE Admin setSetting "Session.autoRegenerate" 0
    sudo $CAKE Admin setSetting "Session.timeout" 600
    sudo $CAKE Admin setSetting "Session.cookie_timeout" 3600
    # Enable GnuPG
    sudo $CAKE Admin setSetting "GnuPG.email" "$SENDER_ADDRESS"
    sudo $CAKE Admin setSetting "GnuPG.homedir" "$MISP_BASE_PATH/.gnupg"
    #sudo $CAKE Admin setSetting "GnuPG.password" ""
    # Enable Enrichment set better timeouts
    sudo $CAKE Admin setSetting "Plugin.Enrichment_services_enable" true
    sudo $CAKE Admin setSetting "Plugin.Enrichment_hover_enable" true
    sudo $CAKE Admin setSetting "Plugin.Enrichment_timeout" 300
    sudo $CAKE Admin setSetting "Plugin.Enrichment_hover_timeout" 150
    sudo $CAKE Admin setSetting "Plugin.Enrichment_cve_enabled" true
    sudo $CAKE Admin setSetting "Plugin.Enrichment_dns_enabled" true
    sudo $CAKE Admin setSetting "Plugin.Enrichment_services_url" "http://misp-modules"
    sudo $CAKE Admin setSetting "Plugin.Enrichment_services_port" 6666
    # Enable Import modules set better timout
    sudo $CAKE Admin setSetting "Plugin.Import_services_enable" true
    sudo $CAKE Admin setSetting "Plugin.Import_services_url" "http://misp-modules"
    sudo $CAKE Admin setSetting "Plugin.Import_services_port" 6666
    sudo $CAKE Admin setSetting "Plugin.Import_timeout" 300
    sudo $CAKE Admin setSetting "Plugin.Import_ocr_enabled" true
    sudo $CAKE Admin setSetting "Plugin.Import_csvimport_enabled" true
    # Enable Export modules set better timout
    sudo $CAKE Admin setSetting "Plugin.Export_services_enable" true
    sudo $CAKE Admin setSetting "Plugin.Export_services_url" "http://misp-modules"
    sudo $CAKE Admin setSetting "Plugin.Export_services_port" 6666
    sudo $CAKE Admin setSetting "Plugin.Export_timeout" 300
    sudo $CAKE Admin setSetting "Plugin.Export_pdfexport_enabled" true
    # Enable installer org and tune some configurables
    sudo $CAKE Admin setSetting "MISP.host_org_id" 1
    sudo $CAKE Admin setSetting "MISP.email" "$SENDER_ADDRESS"
    sudo $CAKE Admin setSetting "MISP.disable_emailing" true
    sudo $CAKE Admin setSetting "MISP.contact" "$SENDER_ADDRESS"
    # sudo $CAKE Admin setSetting "MISP.disablerestalert" true
    # sudo $CAKE Admin setSetting "MISP.showCorrelationsOnIndex" true
    # Provisional Cortex tunes
    sudo $CAKE Admin setSetting "Plugin.Cortex_services_enable" false
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_port" 9000
    # sudo $CAKE Admin setSetting "Plugin.Cortex_timeout" 120
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_url" "http://127.0.0.1"
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_port" 9000
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_timeout" 120
    # sudo $CAKE Admin setSetting "Plugin.Cortex_services_authkey" ""
    # sudo $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_peer" false
    # sudo $CAKE Admin setSetting "Plugin.Cortex_ssl_verify_host" false
    # sudo $CAKE Admin setSetting "Plugin.Cortex_ssl_allow_self_signed" true
    # Various plugin sightings settings
    # sudo $CAKE Admin setSetting "Plugin.Sightings_policy" 0
    # sudo $CAKE Admin setSetting "Plugin.Sightings_anonymise" false
    # sudo $CAKE Admin setSetting "Plugin.Sightings_range" 365
    # Plugin CustomAuth tuneable
    # sudo $CAKE Admin setSetting "Plugin.CustomAuth_disable_logout" false
    # RPZ Plugin settings
    # sudo $CAKE Admin setSetting "Plugin.RPZ_policy" "DROP"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_walled_garden" "127.0.0.1"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_serial" "\$date00"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_refresh" "2h"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_retry" "30m"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_expiry" "30d"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_minimum_ttl" "1h"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_ttl" "1w"
    # sudo $CAKE Admin setSetting "Plugin.RPZ_ns" "localhost."
    # sudo $CAKE Admin setSetting "Plugin.RPZ_ns_alt" ""
    # sudo $CAKE Admin setSetting "Plugin.RPZ_email" "$SENDER_ADDRESS"
    # Force defaults to make MISP Server Settings less RED
    sudo $CAKE Admin setSetting "MISP.language" "eng"
    #sudo $CAKE Admin setSetting "MISP.proposals_block_attributes" false
    # Redis block
    sudo $CAKE Admin setSetting "MISP.redis_host" "127.0.0.1"
    sudo $CAKE Admin setSetting "MISP.redis_port" 6379
    sudo $CAKE Admin setSetting "MISP.redis_database" 13
    sudo $CAKE Admin setSetting "MISP.redis_password" ""
    # Force defaults to make MISP Server Settings less YELLOW
    # sudo $CAKE Admin setSetting "MISP.ssdeep_correlation_threshold" 40
    # sudo $CAKE Admin setSetting "MISP.extended_alert_subject" false
    # sudo $CAKE Admin setSetting "MISP.default_event_threat_level" 4
    # sudo $CAKE Admin setSetting "MISP.newUserText" "Dear new MISP user,\\n\\nWe would hereby like to welcome you to the \$org MISP community.\\n\\n Use the credentials below to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nPassword: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    # sudo $CAKE Admin setSetting "MISP.passwordResetText" "Dear MISP user,\\n\\nA password reset has been triggered for your account. Use the below provided temporary password to log into MISP at \$misp, where you will be prompted to manually change your password to something of your own choice.\\n\\nUsername: \$username\\nYour temporary password: \$password\\n\\nIf you have any questions, don't hesitate to contact us at: \$contact.\\n\\nBest regards,\\nYour \$org MISP support team"
    # sudo $CAKE Admin setSetting "MISP.enableEventBlacklisting" true
    # sudo $CAKE Admin setSetting "MISP.enableOrgBlacklisting" true
    # sudo $CAKE Admin setSetting "MISP.log_client_ip" false
    # sudo $CAKE Admin setSetting "MISP.log_auth" false
    # sudo $CAKE Admin setSetting "MISP.disableUserSelfManagement" false
    # sudo $CAKE Admin setSetting "MISP.block_event_alert" false
    # sudo $CAKE Admin setSetting "MISP.block_event_alert_tag" "no-alerts=\"true\""
    # sudo $CAKE Admin setSetting "MISP.block_old_event_alert" false
    # sudo $CAKE Admin setSetting "MISP.block_old_event_alert_age" ""
    # sudo $CAKE Admin setSetting "MISP.incoming_tags_disabled_by_default" false
    # sudo $CAKE Admin setSetting "MISP.footermidleft" "This is an initial install"
    # sudo $CAKE Admin setSetting "MISP.footermidright" "Please configure and harden accordingly"
    # sudo $CAKE Admin setSetting "MISP.welcome_text_top" "Initial Install, please configure"
    # sudo $CAKE Admin setSetting "MISP.welcome_text_bottom" "Welcome to MISP, change this message in MISP Settings"
    
    # Force defaults to make MISP Server Settings less GREEN
    # sudo $CAKE Admin setSetting "Security.password_policy_length" 16
    # sudo $CAKE Admin setSetting "Security.password_policy_complexity" '/^((?=.*\d)|(?=.*\W+))(?![\n])(?=.*[A-Z])(?=.*[a-z]).*$|.{16,}/'
    # Tune global time outs
    sudo $CAKE Admin setSetting "Session.autoRegenerate" 0
    sudo $CAKE Admin setSetting "Session.timeout" 600
    sudo $CAKE Admin setSetting "Session.cookie_timeout" 3600
    # Set MISP Live
    # sudo $CAKE Live 1
    # Update the galaxies…
    #sudo $CAKE Admin updateGalaxies
    # Updating the taxonomies…
    #sudo $CAKE Admin updateTaxonomies
    # Updating the warning lists…
    #sudo $CAKE Admin updateWarningLists
    # Updating the notice lists…
    # sudo $CAKE Admin updateNoticeLists
    #curl --header "Authorization: $AUTH_KEY" --header "Accept: application/json" --header "Content-Type: application/json" -k -X POST https://127.0.0.1/noticelists/update
    
    # Updating the object templates…
    # sudo $CAKE Admin updateObjectTemplates
    #curl --header "Authorization: $AUTH_KEY" --header "Accept: application/json" --header "Content-Type: application/json" -k -X POST https://127.0.0.1/objectTemplates/update
}

function create_ssl_cert(){
    # If a valid SSL certificate is not already created for the server, create a self-signed certificate:
    while [ -f $PID_CERT_CREATER.proxy ]
    do
        echo "$STARTMSG `date +%T` -  misp-proxy container create currently the certificate. misp-server wait until misp-proxy is finish."
        sleep 2
    done
    [ ! -f $SSL_CERT -a ! -f $SSL_KEY ] && touch ${PID_CERT_CREATER}.server && echo "$STARTMSG Create SSL Certificate..." && openssl req -x509 -newkey rsa:4096 -keyout $SSL_KEY -out $SSL_CERT -days 365 -sha256 -subj "/CN=${HOSTNAME}" -nodes && rm ${PID_CERT_CREATER}.server
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

function SSL_generate_DH(){
    while [ -f $PID_CERT_CREATER.proxy ]
    do
        echo "$STARTMSG `date +%T` -  misp-proxy container create currently the certificate. misp-server wait until misp-proxy is finish."
        sleep 2
    done
    [ ! -f $SSL_DH_FILE ] && touch ${PID_CERT_CREATER}.server  && echo "$STARTMSG Create DH params - This can take a long time, so take a break and enjoy a cup of tea or coffee." && openssl dhparam -out $SSL_DH_FILE 2048 && rm ${PID_CERT_CREATER}.server
    echo # add an echo command because if no command is done busybox (alpine sh) won't continue the script
}

function check_mysql(){
    # Test when MySQL is ready

    while (true)
    do
        [ -z "$(mysql -u $MYSQL_USER -p$MYSQL_PASSWORD -h $MYSQL_HOST -e 'select 1;'|tail -1|grep ERROR)" ] && break;
        echo "$STARTMSG Wait for MySQL..."
        sleep 2
    done
}

function check_redis(){
    # Test when Redis is ready

    # if no host is give default localhost
    [ -z $REDIS_HOST ] && REDIS_HOST=localhost
    while (true)
    do
        [ "$(redis-cli -h $REDIS_HOST ping)" == "PONG" ] && break;
        echo "$STARTMSG Wait for Redis..."
        sleep 2
    done
}

function upgrade(){
    for i in $FOLDER_with_VERSIONS
    do
        if [ ! -f $i/${NAME} ] 
        then
            # File not exist and now it will be created
            echo ${VERSION} > $i/${NAME}
        elif [ ! -f $i/${NAME} -a -z "$(cat $i/${NAME})" ]
        then
            # File exists, but is empty
            echo ${VERSION} > $i/${NAME}
        elif [ "$VERSION" == "$(cat $i/${NAME})" ]
        then
            # File exists and the volume is the current version
            echo "$STARTMSG Folder $i is on the newest version."
        else
            # upgrade
            echo "$STARTMSG Folder $i should be updated."
            case $(echo $i/$NAME) in
            2.4.92)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.92 ####"
                ;;
            2.4.93)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.93 ####"
                ;;
            2.4.94)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.94 ####"
                ;;
            2.4.95)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.95 ####"
                ;;
            2.4.96)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.96 ####"
                ;;
            2.4.97)
                # Tasks todo in 2.4.92
                echo "$STARTMSG #### Upgrade Volumes from 2.4.97 ####"
                ;;
            *)
                echo "$STARTMSG Unknown Version, upgrade not possible."
                exit
                ;;
            esac
            ############ DO ANY!!!
        fi
    done
}

##############   MAIN   #################
echo "$STARTMSG wait 30 seconds for DB" && sleep 30


# If a customer needs a analze column in misp
echo "$STARTMSG check if analyze column should be added..."
    [ "$ADD_ANALYZE_COLUMN" == "yes" ] && add_analyze_column

# Change PHP VARS
echo "$STARTMSG check if PHP values should be changed..."
    change_php_vars

##### PGP configs #####
echo "$STARTMSG check if PGP should be enabled...."
    [ -z $PGP_ENABLE ] && PGP_ENABLE=0 # false
    [ $PGP_ENABLE == "y" ] && PGP_ENABLE=1 && init_pgp
    # if secring.pgp exists execute init_pgp
    [ -f "/var/www/MISP/.gnupgp/public.key" ] && init_pgp

echo "$STARTMSG check if SMIME should be enabled..."
    [ -z $SMIME_ENABLE ] && SMIME_ENABLE=0 # false 
    [ $SMIME_ENABLE == "y" ] && SMIME_ENABLE=1 && init_smime
    # If certificate exists execute init_smime
    [ -f "/var/www/MISP/.smime/cert.pem" ] && init_smime

##### create a cert if it is required
echo "$STARTMSG check if a cert is required..."
    create_ssl_cert

# check if DH file is required to generate
echo "$STARTMSG check if a dh file is required"
    SSL_generate_DH

##### enable https config and disable http config ####
echo "$STARTMSG check if HTTPS MISP config should be enabled..."
    [ -f /etc/apache2/ssl/cert.pem -a ! -f /etc/apache2/sites-enabled/misp.ssl.conf ] && mv /etc/apache2/sites-enabled/misp.ssl /etc/apache2/sites-enabled/misp.ssl.conf

echo "$STARTMSG check if HTTP MISP config should be disabled..."
    [ -f /etc/apache2/ssl/cert.pem -a ! -f /etc/apache2/sites-enabled/misp.http ] && mv /etc/apache2/sites-enabled/misp.conf /etc/apache2/sites-enabled/misp.http

##### check MySQL
echo "$STARTMSG check if MySQL is ready..." && check_mysql

##### check MySQL
echo "$STARTMSG check if Redis is ready..." && check_redis


##### initialize MISP-SERVER
echo "$STARTMSG initialize misp base config..."
    init_misp_config

##### check if setup is new: - in the dockerfile i create on this path a empty file to decide is the configuration completely new or not
echo "$STARTMSG check if cake setup should be initialized..."
    [ -f "/var/www/MISP/app/Config/NOT_CONFIGURED" -a -f "/var/www/MISP/app/Config/database.php"  ] && setup_via_cake_cli

##### Delete the initial decision file & reboot misp-server
echo "$STARTMSG check if misp-server is configured and file /var/www/MISP/app/Config/NOT_CONFIGURED exist"
    [ -f /var/www/MISP/app/Config/NOT_CONFIGURED ] && echo "$STARTMSG delete init config file and reboot" && rm "/var/www/MISP/app/Config/NOT_CONFIGURED"

########################################################
# check volumes and upgrade if it is required
echo "$STARTMSG upgrade if it is required..." && upgrade

##### Check permissions #####
    echo "$STARTMSG Configure MISP | Check permissions"
    chown -R www-data.www-data /var/www/MISP
    chmod -R 0750 /var/www/MISP
    chmod -R g+ws /var/www/MISP/app/tmp
    chmod -R g+ws /var/www/MISP/app/files
    chmod -R g+ws /var/www/MISP/app/files/scripts/tmp

# start workers
start_workers





# START APACHE2
echo "$STARTMSG ####################################  started Apache2 with cmd: '$CMD_APACHE' ####################################"

##### Display tips
echo
echo
cat <<__WELCOME__
" ###########	MISP environment is ready	###########"
" Please go to: ${MYSQL_HOST}"
" Login credentials:"
"      Username: admin@admin.test"
"      Password: admin"
	
" Do not forget to change your SSL certificate with:    make change-ssl"
" ##########################################################"
Congratulations!
Your MISP-dockerized server has been successfully booted.
__WELCOME__


##### execute apache
[ "$CMD_APACHE" != "none" ] && init_apache $CMD_APACHE
[ "$CMD_APACHE" == "none" ] && init_apache
