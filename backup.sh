#!/bin/bash

# Get hostname: try read from file, else get from env
[ -z "${MYSQL_HOST_FILE}" ] || { MYSQL_HOST=$(head -1 "${MYSQL_HOST_FILE}"); }
[ -z "${MYSQL_HOST}" ] && { echo "=> MYSQL_HOST cannot be empty" && exit 1; }
# Get username: try read from file, else get from env
[ -z "${MYSQL_USER_FILE}" ] || { MYSQL_USER=$(head -1 "${MYSQL_USER_FILE}"); }
[ -z "${MYSQL_USER}" ] && { echo "=> MYSQL_USER cannot be empty" && exit 1; }
# Get password: try read from file, else get from env, else get from MYSQL_PASSWORD env
[ -z "${MYSQL_PASS_FILE}" ] || { MYSQL_PASS=$(head -1 "${MYSQL_PASS_FILE}"); }
[ -z "${MYSQL_PASS:=$MYSQL_PASSWORD}" ] && { echo "=> MYSQL_PASS cannot be empty" && exit 1; }
# Get database name(s): try read from file, else get from env
# Note: when from file, there can be one database name per line in that file
[ -z "${MYSQL_DATABASE_FILE}" ] || { MYSQL_DATABASE=$(cat "${MYSQL_DATABASE_FILE}"); }
# Get level from env, else use 6
[ -z "${GZIP_LEVEL}" ] && { GZIP_LEVEL=6; }

DATE=$(date +%Y%m%d%H%M)
BEAUTIFUL_DATE=$(date "+%Y-%m-%d %H:%M:%S")
echo "$BEAUTIFUL_DATE  Backup starting..."

# Signal start to healthchecks.io
if [ ! -z "$HEALTHCHECK_URL" ]
then
  echo "INFO: sending start signal to healthchecks.io"
  wget -q $HEALTHCHECK_URL/start -O /dev/null
fi

DATABASES=${MYSQL_DATABASE:-${MYSQL_DB:-$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" $MYSQL_SSL_OPTS -e "SHOW DATABASES;" | tr -d "| " | grep -v Database)}}
ERROR_CODE=$?
ERROR_LOG="Can't connect to Database server."

for db in ${DATABASES}
do
  if  [[ "$db" != "information_schema" ]] \
      && [[ "$db" != "performance_schema" ]] \
      && [[ "$db" != "mysql" ]] \
      && [[ "$db" != "sys" ]] \
      && [[ "$db" != _* ]]
  then
    echo "INFO: Dumping database '$db'"
    if [ "$MAX_BACKUPS" -ne 1 ]
    then
      FILENAME=/backup/$DATE.$db.sql
      LATEST=/backup/latest.$db.sql
    else
      FILENAME=/backup/$db.sql
    fi
    
    if mysqldump --single-transaction $MYSQLDUMP_OPTS -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" $MYSQL_SSL_OPTS "$db" > "$FILENAME"
    then
      EXT=
      if [ -z "${USE_PLAIN_SQL}" ]
      then
        echo "INFO: Compressing $db with LEVEL $GZIP_LEVEL"
        gzip "-$GZIP_LEVEL" -f "$FILENAME"
        EXT=.gz
        FILENAME=$FILENAME$EXT
        LATEST=$LATEST$EXT
      fi

      if [ "$MAX_BACKUPS" -ne 1 ]
      then
        BASENAME=$(basename "$FILENAME")
        echo "INFO: Creating symlink to latest backup: $BASENAME"
        rm "$LATEST" 2> /dev/null
        cd /backup || exit && ln -s "$BASENAME" "$(basename "$LATEST")"
        if [ -n "$MAX_BACKUPS" ]
        then
          while [ "$(find /backup -maxdepth 1 -name "*.$db.sql$EXT" -type f | wc -l)" -gt "$MAX_BACKUPS" ]
          do
            TARGET=$(find /backup -maxdepth 1 -name "*.$db.sql$EXT" -type f | sort | head -n 1)
            echo "INFO: Max number of ($MAX_BACKUPS) backups reached. Deleting ${TARGET} ..."
            rm -rf "${TARGET}"
            echo "INFO: ${TARGET} deleted."
          done
        fi
      fi
    else
      ERROR_CODE=1
      ERROR_LOG="mysqldump got error, please check container logs for more details."
      rm -rf "$FILENAME"
    fi
  fi
done

# healthchecks.io call with complete or failure signal.
if [ ! -z "$HEALTHCHECK_URL" ]
then
  if [ "$ERROR_CODE" == 0 ]
  then
    echo "INFO: sending Success signal to healthchecks.io"
    wget -q "$HEALTHCHECK_URL" -O /dev/null --post-data="$BEAUTIFUL_DATE: SUCCESS"
  else
    echo "INFO: sending Failure signal to healthchecks.io"
    #Sending  signal to healthchecks.io"
    wget -q "$HEALTHCHECK_URL/fail" -O /dev/null --post-data="$BEAUTIFUL_DATE ERROR: $ERROR_LOG"
  fi
fi

echo "$BEAUTIFUL_DATE Backup process finished."