#!/usr/bin/env bash
# Kontejner běží pořád. cron uvnitř spustí probe v noci (viz crontab).
# Ručně kdykoli:  bash /app/probe.sh --limit 10

set -e

# cron nedědí env proměnné kontejneru — uložíme je do souboru,
# který si crontab i probe.sh načte přes `. /app/env.sh`.
{
  echo "export TORBOX_API_KEY='${TORBOX_API_KEY:-}'"
  echo "export INDEXER_USER='${INDEXER_USER:-}'"
  echo "export INDEXER_PASS='${INDEXER_PASS:-}'"
  echo "export INDEXER_URL='${INDEXER_URL:-http://indexer:3003}'"
  echo "export TORBOX_API='${TORBOX_API:-https://api.torbox.app/v1/api}'"
  echo "export PROBE_SLEEP='${PROBE_SLEEP:-20}'"
} > /app/env.sh
chmod 600 /app/env.sh

echo "[entrypoint] env uloženo, spouštím cron (noční běh 1:00)"
cron

echo "[entrypoint] kontejner běží. Ruční spuštění: bash /app/probe.sh --limit 10"
# drž kontejner naживу a zároveň ukazuj cron log, kdyby noční běh naběhl
touch /tmp/cron.log
tail -f /tmp/cron.log
