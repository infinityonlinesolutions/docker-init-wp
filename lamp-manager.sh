#!/bin/bash

#DOMAIN=$1


export WEBDIR=/var/www/html
export APACHEWEBDIR=/var/www/html
export MYSQLDIR=/var/www/mysql

export MSQL="mysql -uroot -p$MYSQL_ROOT_PASSWORD -h$MYSQL_HOST -e"
export WP="wp --allow-root --path=$WEBDIR"

SQLHEADER=$(cat <<EOF
-- MySQL dump 10.13  Distrib 5.5.52, for debian-linux-gnu (i686)
--
-- Host: localhost    Database: xc218_db1
-- ------------------------------------------------------
-- Server version       5.5.52-0+deb7u1

/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;
/*!40103 SET @OLD_TIME_ZONE=@@TIME_ZONE */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET @OLD_SQL_NOTES=@@SQL_NOTES, SQL_NOTES=0 */;
EOF
)

function init_from_backup
{
	if [ "$SVN_ENABLED" -eq 1 ]; then
		export WEBDIR=/var/www/backup
	fi

	mkdir -p $WEBDIR $MYSQLDIR
	cd /var/www

	download_backup

	echo "Unzipping backup(s) to $WEBDIR"
	find . -name '*.zip' | xargs -l unzip -d $WEBDIR

	cd $WEBDIR

	echo "Removing cache and uploads directory"
	rm -r wp-content/uploads/ wp-content/cache/

	echo "Getting sql file"
	if ! [  1 == "$(find iwp_db/ -name '*.sql' | grep -c sql)" ]; then 
		find . -name "*.sql" | awk '{print substr( $0, length($0) - 8, length($0) ),$0}' | sort -n  | cut -f2- -d' ' | xargs cat >  $MYSQLDIR/backup.sql
	else
		mv iwp_db/*sql $MYSQLDIR
	fi

	rm -r iwp_db/

	echo "Replacing strings in config files"
	sed -i s/localhost/$MYSQL_HOST/g wp-config.php
	sed -i s/^.*WPCACHEHOME.*$/define\(\'WPCACHEHOME\',\'\\/var\\/www\\/html\\/wp-content\\/plugins\\/wp-super-cache\\/\'\)\;/g wp-config.php
	sed -i s/^\$cache_path.*$/\$cache_path=\'\\/var\\/www\\/html\\/wp-content\\/cache\'\;/g wp-content/wp-cache-config.php

	echo "Linking uploads direcorty to live site"
	(echo "#route all access to downloads directory to real site
RewriteRule ^wp-content/uploads/(.*)$ http://www.$WEB_DOMAIN/wp-content/uploads/\$1 [R=302,L]

" && cat .htaccess) > .htaccess.tmp
	mv .htaccess.tmp .htaccess
}

function download_backup
{
	FOLDERID="$(gdrive list -q " '0B2N6Wd7gFxkvU21oVUtBaHQzbDA' in parents and name='$WEB_DOMAIN'" --no-header | head -n1 | awk '{print $1;}')"
	FILELIST="$(gdrive list -q " '$FOLDERID' in parents" --no-header)"
	while read -r line; do
		
		FILEID=$(echo "$line" | awk '{print $1;}')
	
		echo "Downloading: $FILEINFO"

		gdrive download $FILEID

		if ! [ "$?" -eq 0 ]; then
			echo "Failed to download backup file from gdrive, exiting..." 
			exit_clean
		fi

		# quit if not part of backup
		if ! [[ "$line" == *"part_"* ]]; then
			break
		fi
	done <<< "$FILELIST"
}

function exit_clean
{
	while $DEBUGGING
	do
		sleep 30
	done
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

		grep "MySQL dump" "$LATEST_SQL"
		if [ "$?" -eq 1 ]; then
			echo "MySQL header missing, adding to sql file..."
			(echo "$SQLHEADER" && cat "$LATEST_SQL") > "$LATEST_SQL.tmp"
			mv "$LATEST_SQL.tmp" "$LATEST_SQL"
		fi

		mysql -u"$MSQL_USER" -p"$MSQL_PASS" -h$MYSQL_HOST "$MSQL_DB" < "$LATEST_SQL"

		if ! [ "$?" -eq 0 ]; then
			echo "Could not import DB, exiting..." 
			exit_clean
		fi
	fi
}

function search-replace
{
	if ! [ -z "$WEB_DOMAIN" ] && ! [ -z "$WEB_TEST_DOMAIN" ];  then
		echo "Search replacing: https://$WEB_DOMAIN"
		$WP search-replace "https://$WEB_DOMAIN" "http://$WEB_DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
		echo "Search replacing: https://www.$WEB_DOMAIN"
		$WP search-replace "https://www.$WEB_DOMAIN" "http://www.$WEB_DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
		echo "Search replacing: http://www.$WEB_DOMAIN with http://$WEB_DOMAIN"
		$WP search-replace "http://www.$WEB_DOMAIN" "http://$WEB_DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
		echo "Search replacing: $WEB_DOMAIN with $WEB_TEST_DOMAIN"
		$WP search-replace "$WEB_DOMAIN" "$WEB_TEST_DOMAIN"
		if ! [ "$?" -eq 0 ]; then
			echo "Search replace failed, exiting..." 
			exit_clean
		fi
	fi
}

init_from_backup
init_mysql
search-replace

while true
do
	sleep 30
done
