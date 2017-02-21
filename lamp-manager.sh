#!/bin/bash

#DOMAIN=$1


export WEBDIR=/opt/backup/web
export APACHEWEBDIR=/var/www/html
export MYSQLDIR=/opt/backup/mysql

export MSQL="mysql -uroot -p$MYSQL_ROOT_PASSWORD -h$MYSQL_HOST -e"
export WP="wp --allow-root --path=$WEBDIR"

function init_from_backup
{
	mkdir -p $WEBDIR $MYSQLDIR
	cd /opt/backup

	download_backup

	echo "Unzipping backup to $WEBDIR"
	unzip *.zip -d $WEBDIR

	cd $WEBDIR

	echo "Removing cache and uploads directory"
	rm -r wp-content/uploads/ wp-content/cache/

	echo "Getting sql file"
	if ! [  1 == "$(find iwp_db/ -name '*.sql' | grep -c sql)" ]; then 
		find . -name "*.sql" | awk '{print substr( $0, length($0) - 8, length($0) ),$0}' | sort -n  | cut -f2- -d' ' | xargs cat >  $MYSQLDIR/backup.sql
	else
		mv iwp_db/*sql $MYSQLDIR
	fi

	echo "Replacing strings in config files"
	sed -i s/localhost/$MYSQL_HOST/g wp-config.php
	sed -i s/^.*WPCACHEHOME.*$/define\(\'WPCACHEHOME\',\'\\/var\\/www\\/html\\/wp-content\\/plugins\\/wp-super-cache\\/\'\)\;/g wp-config.php
	sed -i s/^\$cache_path.*$/\$cache_path=\'\\/var\\/www\\/html\\/wp-content\\/cache\'\;/g wp-content/wp-cache-config.php

	echo "Linking uploads direcorty to live site"
	(echo "#route all access to downloads directory to real site
RewriteRule ^wp-content/uploads/(.*)$ http://www.$DOMAIN/wp-content/uploads/\$1 [R=302,L]

" && cat .htaccess) > .htaccess.tmp
	mv .htaccess.tmp .htaccess
}

function download_backup_dummy
{
	cp /root/.gdrive/*.zip .
}

function download_backup
{
	FOLDERID="$(gdrive list -q " '0B2N6Wd7gFxkvU21oVUtBaHQzbDA' in parents and name='$DOMAIN'" --no-header | head -n1 | awk '{print $1;}')"
	FILEINFO="$(gdrive list -q " '$FOLDERID' in parents" --no-header | head -n1)"
#	FILEDATE=$(echo $FILEINFO | awk '{print $5;}')
	FILEID=$(echo $FILEINFO | awk '{print $1;}')
	
	echo "Downloading: $FILEINFO"

	gdrive download $FILEID

	if ! [ "$?" -eq 0 ]; then
		echo "Failed to download backup file from gdrive, exiting..." 
		exit_clean
	fi
}

function create_backup
{
	$WP db export "$MYSQLDIR/dbbackup_$(date +%F_%s).sql"
}

function exit_clean
{
	exit 1
}

function init_mysql
{
	name="$(grep DB_ $WEBDIR/wp-config.php)"

	re="define ?\( ?'DB_NAME' ?, ?'([^']+)' ?\);"    
	if [[ $name =~ $re ]]; then 
		MSQL_DB=${BASH_REMATCH[1]}; 
	else
		echo "Could not get DB Name from wp-config.php. Aborting."
		exit_clean
	fi

	re="define ?\( ?'DB_USER' ?, ?'([^']+)' ?\);"
	if [[ $name =~ $re ]]; then 
		MSQL_USER=${BASH_REMATCH[1]}; 
	else
		echo "Could not get DB User from wp-config.php. Aborting."
		exit_clean
	fi
	
	re="define ?\( ?'DB_PASSWORD' ?, ?'([^']+)' ?\);"
	if [[ $name =~ $re ]]; then 
		MSQL_PASS=${BASH_REMATCH[1]}; 
	else
		echo "Could not get DB Password from wp-config.php. Aborting."
		exit_clean
	fi
	
	until $MSQL ";"
	do
		echo "Can't connect to mysql, retrying in 30 seconds."
		sleep 30
	done
	
	USER_EXISTS="$($MSQL "SELECT user FROM mysql.user WHERE user = '$MSQL_USER';")"
	if [ -z "$USER_EXISTS" ];  then
		echo "Creating new user: $MSQL_USER"
		$MSQL "CREATE USER '$MSQL_USER'@'%' IDENTIFIED BY '$MSQL_PASS';"
		if ! [ "$?" -eq 0 ]; then
			echo "Could not create user, exiting..." 
			exit_clean
		fi
	fi
	
	DB_EXISTS="$($MSQL "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '$MSQL_DB';")"

	if [ -z "$DB_EXISTS" ];  then

		echo "Creating new database: $MSQL_DB"
		$MSQL "CREATE DATABASE $MSQL_DB;"
		$MSQL "GRANT ALL ON $MSQL_DB.* TO '$MSQL_USER'@'%';"
		LATEST_SQL="$(ls -t $MYSQLDIR/*.sql | head -n1)"

		echo "Importing DB: $LATEST_SQL"
		mysql -u"$MSQL_USER" -p"$MSQL_PASS" -h$MYSQL_HOST "$MSQL_DB" < "$LATEST_SQL"

		if ! [ "$?" -eq 0 ]; then
			echo "Could not import DB, exiting..." 
			exit_clean
		fi
	fi
}

function search-replace
{
	if ! [ -z "$DOMAIN" ] && ! [ -z "$TEST_DOMAIN" ];  then
		echo "Search replacing: https://$DOMAIN"
		$WP search-replace "https://$DOMAIN" "http://$DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
		echo "Search replacing: https://www.$DOMAIN"
		$WP search-replace "https://www.$DOMAIN" "http://www.$DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
		echo "Search replacing: $DOMAIN with $TEST_DOMAIN"
		$WP search-replace "$DOMAIN" "$TEST_DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
	fi
}

function old_loop
{
	trap "rm -f $pipe" EXIT
	
	if [[ ! -p $pipe ]]; then
	    mkfifo $pipe
	fi

	supervisorctl stop apache:apached

	if [ -e "/opt/php-ini/php.ini" ]; then
		cp /opt/php-ini/php.ini /opt/docker/etc/php/php.ini
		supervisorctl restart php-fpm:php-fpmd
	fi
	
	while true
	do
	    if read line <$pipe; then
		echo "Received command: $line"

		if [[ "$line" == 'SVNSYNCED' ]]; then
		    init_mysql
		    search-replace
		fi
	    fi
	done

	while true
	do
		if [ -e "$svndir/com/dbbackup" ]; then
			create_backup
			rm "$svndir/com/dbbackup"
		fi
		sleep 30
	done
	
	echo "rokk-ops script exiting"
}

init_from_backup
init_mysql
search-replace

while true
do
	sleep 30
done
