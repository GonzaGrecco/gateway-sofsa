#!/usr/bin/env bash
# Se puede correr más de una vez: lo que ya existe se saltea.
# Presupuestos y límites provisorios, a definir con SOFSA.
# Uso: ./scripts/carga-inicial.sh URL MASTER_KEY
# Las keys nuevas se muestran una sola vez.
# Requiere: curl, jq
set -uo pipefail

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Falta '$cmd' en el PATH (Windows: winget install jqlang.jq)"; exit 2; }
done

URL="${1:?uso: $0 URL MASTER_KEY}"
MASTER="${2:?uso: $0 URL MASTER_KEY}"
RPM=60

# team | USD por mes | key de la app | modelos (separados por coma)
TEAMS=(
  "saco|20|saco-app|saco-chat,saco-vision,saco-embeddings"
  "sofia|20|sofia-app|sofia-chat,sofia-embeddings"
  "plataforma|5|plataforma-pruebas|claude-sonnet"
)

api() { curl -s -X "$1" "$URL$2" -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" ${3:+-d "$3"}; }

EXISTENTES_T=$(api GET /team/list) || { echo "No se pudo leer /team/list en $URL"; exit 2; }
EXISTENTES_K=$(api GET "/key/list?return_full_object=true&size=100")

for fila in "${TEAMS[@]}"; do
  IFS='|' read -r TEAM USD KEY MODS <<<"$fila"
  MODELOS=$(jq -nc --arg m "$MODS" '$m | split(",")')
  TID=$(jq -r --arg a "$TEAM" '[.[] | select(.team_alias == $a) | .team_id][0] // empty' <<<"$EXISTENTES_T")
  if [ -n "$TID" ]; then
    echo "team $TEAM: ya existe"
  else
    TID=$(api POST /team/new "$(jq -nc --arg a "$TEAM" --argjson m "$MODELOS" --argjson b "$USD" \
      '{team_alias:$a, models:$m, max_budget:$b, budget_duration:"30d"}')" | jq -r '.team_id // empty')
    [ -n "$TID" ] && echo "team $TEAM: creado (USD $USD/mes)" || { echo "team $TEAM: ERROR al crear"; continue; }
  fi

  if jq -e --arg a "$KEY" '.keys[] | select(.key_alias == $a)' <<<"$EXISTENTES_K" >/dev/null; then
    echo "  key $KEY: ya existe"
  else
    K=$(api POST /key/generate "$(jq -nc --arg t "$TID" --arg a "$KEY" --argjson r "$RPM" '{team_id:$t, key_alias:$a, rpm_limit:$r}')" | jq -r '.key // empty')
    [ -n "$K" ] && echo "  key $KEY: $K" || echo "  key $KEY: ERROR al crear"
  fi
done

# Key de solo lectura para que Prometheus lea /metrics/.
if jq -e '.keys[] | select(.key_alias == "monitoreo-prometheus")' <<<"$EXISTENTES_K" >/dev/null; then
  echo "key monitoreo-prometheus: ya existe"
else
  # Sin auto_create_key, /user/new le crea al usuario una key con acceso a todos los modelos.
  api POST /user/new '{"user_id":"monitoreo","user_role":"proxy_admin_viewer","auto_create_key":false}' >/dev/null
  K=$(api POST /key/generate '{"user_id":"monitoreo","key_alias":"monitoreo-prometheus","models":["no-default-models"]}' | jq -r '.key // empty')
  [ -n "$K" ] && echo "key monitoreo-prometheus: $K" || echo "key monitoreo-prometheus: ERROR al crear"
fi
