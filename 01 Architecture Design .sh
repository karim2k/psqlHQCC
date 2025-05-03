#!/bin/bash
# Check PostgreSQL status
if ! pg_isready -q -h localhost; then
  echo "ALERT: PostgreSQL down on $(hostname)" | mail -s "PostgreSQL Down" admin@example.com
fi

# Check replication lag (on replicas)
if [ "$(whoami)" = "postgres" ]; then
  lag=$(psql -c "SELECT EXTRACT(SECOND FROM (now() - pg_last_xact_replay_timestamp())) AS lag;" -t)
  if [ "${lag%.*}" -gt 5 ]; then
    echo "ALERT: Replication lag ${lag}s on $(hostname)" | mail -s "Replication Lag" admin@example.com
  fi
fi