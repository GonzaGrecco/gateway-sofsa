#!/usr/bin/env bash
# Auditoría de la política de logging de contenido (prompts/respuestas).
# Política: todo team declara turn_off_message_logging en metadata.logging
#   "true"  = solo metadatos (default para teams nuevos)
#   "false" = contenido enmascarado (excepción aprobada)
# y no hay keys sin team que no declaren su propia política.
# Sale con código 1 si hay desvíos, para usarlo en cron/CI con alerta.
# Uso: ./scripts/audit-logging.sh [URL] [MASTER_KEY]
# Requiere: curl, jq
set -uo pipefail

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Falta '$cmd' en el PATH (Windows: winget install jqlang.jq)"; exit 2; }
done

URL="${1:-http://localhost:4001}"
MASTER="${2:-sk-local-master-1234}"
get() { curl -sf "$URL$1" -H "Authorization: Bearer $MASTER"; }
POLICY='[.metadata.logging[]? | .callback_vars.turn_off_message_logging? | select(. != null) | tostring] | first // "SIN DEFINIR"'

TEAMS=$(get /team/list) || { echo "No se pudo leer /team/list en $URL"; exit 2; }
KEYS="[]"; PAGE=1
while :; do
  R=$(get "/key/list?return_full_object=true&size=100&page=$PAGE") || { echo "No se pudo leer /key/list en $URL"; exit 2; }
  KEYS=$(jq -c --argjson acc "$KEYS" '$acc + .keys' <<<"$R")
  [ "$PAGE" -ge "$(jq -r '.total_pages // 1' <<<"$R")" ] && break
  PAGE=$((PAGE+1))
done

echo "Teams:"
jq -r ".[] | \"  \(.team_alias // .team_id)\t\($POLICY)\"" <<<"$TEAMS" | sort | column -t -s $'\t' | sed 's/^/  /'

FALTAN_TEAMS=$(jq -r ".[] | select(($POLICY) == \"SIN DEFINIR\") | .team_alias // .team_id" <<<"$TEAMS")
# Las keys sin modelos (monitoreo) no llaman al LLM, así que no tienen contenido que loguear.
SUELTAS=$(jq -r ".[] | select(.team_id == null and .models != [\"no-default-models\"]) | select(($POLICY) == \"SIN DEFINIR\") | .key_alias // .token" <<<"$KEYS")
EXCEPCIONES=$(jq -r ".[] | select(($POLICY) == \"false\") | .team_alias // .team_id" <<<"$TEAMS")
# La política de la key pisa la del team: una key con "false" expone el contenido aunque su team lo redacte.
PISAN=$(jq -r --argjson teams "$TEAMS" "
  (\$teams | map({key: .team_id, value: ($POLICY)}) | from_entries) as \$tp
  | .[] | select(.team_id != null and \$tp[.team_id] == \"true\" and ($POLICY) == \"false\")
  | \"\(.key_alias // .token) (team \(.team_id))\"" <<<"$KEYS")

FAIL=0
echo
if [ -n "$FALTAN_TEAMS" ]; then
  FAIL=1; echo "[DESVÍO] Teams sin política de contenido ($(wc -l <<<"$FALTAN_TEAMS")): loguean prompts y respuestas"
  sed 's/^/  - /' <<<"$FALTAN_TEAMS"
fi
if [ -n "$SUELTAS" ]; then
  FAIL=1; echo "[DESVÍO] Keys sin team y sin política ($(wc -l <<<"$SUELTAS")): loguean prompts y respuestas"
  sed 's/^/  - /' <<<"$SUELTAS"
fi
if [ -n "$PISAN" ]; then
  FAIL=1; echo "[DESVÍO] Keys que desactivan la redacción de su team ($(wc -l <<<"$PISAN")): loguean prompts y respuestas"
  sed 's/^/  - /' <<<"$PISAN"
fi
if [ -n "$EXCEPCIONES" ]; then
  echo "[INFO] Teams con contenido enmascarado (excepciones, revisar que estén aprobadas):"
  sed 's/^/  - /' <<<"$EXCEPCIONES"
fi
[ $FAIL = 0 ] && echo "OK: todos los teams y keys sueltas tienen política de contenido."
exit $FAIL
