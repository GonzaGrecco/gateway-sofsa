#!/usr/bin/env bash
# Backup de las bases para cron: ./scripts/backup.sh gateway|langfuse [--env-file dev.env]
# Deja los archivos en BACKUP_DIR y los copia con rsync a BACKUP_DEST (fuera de la VM).
# Requiere: docker compose, jq, rsync.
#
# Restaurar:
#   Postgres:   pg_restore -U litellm -d litellm --clean < litellm-FECHA.dump (con LiteLLM detenido)
#   ClickHouse: copiar el .zip a /var/lib/clickhouse/backups/ (dueño 101) y correr
#               clickhouse-client --enable_full_text_index=1 --query "RESTORE DATABASE default FROM File('...')"
#               Sin enable_full_text_index falla, porque Langfuse usa índices de texto.
set -euo pipefail

STACK="${1:?uso: backup.sh gateway|langfuse [--env-file archivo]}"
shift
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:?falta BACKUP_DIR (carpeta local de los backups)}"
RETENCION_DIAS="${RETENCION_DIAS:-7}"
FECHA="$(date +%Y%m%d-%H%M)"

cd "${DEPLOY_DIR:-$RAIZ/deploy/$STACK}"
dc() { docker compose "$@"; }
PROYECTO="$(dc "$@" config --format json | jq -r .name)"
DESTINO="$BACKUP_DIR/$PROYECTO"
mkdir -p "$DESTINO"

case "$STACK" in
  gateway)
    dc "$@" exec -T postgres pg_dump -U litellm -Fc litellm > "$DESTINO/litellm-$FECHA.dump"
    ;;
  langfuse)
    dc "$@" exec -T postgres pg_dump -U langfuse -Fc langfuse > "$DESTINO/langfuse-pg-$FECHA.dump"
    CH_TMP="/var/lib/clickhouse/backups/ch-$FECHA.zip"
    dc "$@" exec -T clickhouse sh -c "clickhouse-client --user langfuse --password \"\$CLICKHOUSE_PASSWORD\" \
      --query \"BACKUP DATABASE default TO File('$CH_TMP')\"" >/dev/null
    dc "$@" cp "clickhouse:$CH_TMP" "$DESTINO/langfuse-ch-$FECHA.zip"
    dc "$@" exec -T clickhouse rm -f "$CH_TMP"
    ;;
  *) echo "stack desconocido: $STACK"; exit 1 ;;
esac

find "$DESTINO" -type f -mtime +"$RETENCION_DIAS" -delete
echo "$(date -Is) backup OK: $(ls -1 "$DESTINO" | grep "$FECHA" | tr '\n' ' ')"

if [ -n "${BACKUP_DEST:-}" ]; then
  rsync -a --delete "$DESTINO/" "$BACKUP_DEST/$PROYECTO/"
  echo "$(date -Is) copiado a $BACKUP_DEST/$PROYECTO"
else
  echo "AVISO: BACKUP_DEST vacío, el backup quedó solo en esta VM"
fi
