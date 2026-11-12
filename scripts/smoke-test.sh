#!/usr/bin/env bash
# Prueba de gobierno del gateway: crea team + key y valida permisos, rate limit y budget.
# Al terminar borra los teams y keys que creó.
# Uso: ./scripts/smoke-test.sh [URL] [MASTER_KEY]
#   Contra el balanceador (profile ha: http://localhost:8080) el paso 5 valida
#   además que el rate limit se comparta entre instancias.
# Requiere: curl, jq
set -uo pipefail

for cmd in curl jq; do
  command -v "$cmd" >/dev/null || { echo "Falta '$cmd' en el PATH (Windows: winget install jqlang.jq)"; exit 1; }
done

URL="${1:-http://localhost:4001}"
MASTER="${2:-sk-local-master-1234}"
SUFFIX="$(date +%s)"
PASS=0; FAIL=0

ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
admin(){ curl -s -X POST "$URL$1" -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" -d "$2"; }
chat() { # $1 key, $2 model -> imprime el HTTP code
  curl -s -o /dev/null -w "%{http_code}" -X POST "$URL/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"hola\"}]}"
}

KEYS=(); TEAMS=()
cleanup() {
  echo; echo "Limpieza"
  local k t
  for k in "${KEYS[@]}"; do [[ "$k" == sk-* ]] && admin /key/delete "{\"keys\":[\"$k\"]}" >/dev/null; done
  for t in "${TEAMS[@]}"; do [ -n "$t" ] && [ "$t" != "null" ] && admin /team/delete "{\"team_ids\":[\"$t\"]}" >/dev/null; done
  echo "  borrados ${#KEYS[@]} keys y ${#TEAMS[@]} teams de prueba"
}
trap cleanup EXIT

echo "1. Salud del gateway"
[ "$(curl -s -o /dev/null -w "%{http_code}" "$URL/health/liveliness")" = "200" ] && ok "gateway arriba" || { bad "gateway no responde en $URL"; exit 1; }

echo "2. Team 'juridicos' (solo claude-sonnet) y key de app con 3 req/min"
TEAM=$(admin /team/new "{\"team_alias\":\"juridicos-$SUFFIX\",\"models\":[\"claude-sonnet\"],\"max_budget\":10,\"budget_duration\":\"30d\"}" | jq -r .team_id)
TEAMS+=("$TEAM")
[ "$TEAM" != "null" ] && [ -n "$TEAM" ] && ok "team creado ($TEAM)" || bad "no se creó el team"
KEY=$(admin /key/generate "{\"team_id\":\"$TEAM\",\"key_alias\":\"chatbot-expedientes-$SUFFIX\",\"rpm_limit\":3,\"metadata\":{\"env\":\"local\"}}" | jq -r .key)
KEYS+=("$KEY")
[[ "$KEY" == sk-* ]] && ok "virtual key creada" || bad "no se creó la key"

echo "3. Llamada permitida"
[ "$(chat "$KEY" claude-sonnet)" = "200" ] && ok "claude-sonnet responde" || bad "claude-sonnet no respondió 200"

echo "4. Modelo no habilitado para el team"
OTRO="${OTRO_MODELO:-claude-sonnet-real}"   # cualquier modelo del config que el team no tenga
CODE=$(chat "$KEY" "$OTRO")
[[ "$CODE" =~ ^(401|403)$ ]] && ok "$OTRO bloqueado ($CODE)" || bad "$OTRO debería bloquearse (dio $CODE)"

# Con 2 instancias en round robin cada una recibe 2 de las 4 llamadas: si el
# límite no se compartiera por Redis, ninguna superaría 2 y no habría 429.
echo "5. Rate limit (key nueva con 2 req/min, 4 llamadas)"
KEY_RL=$(admin /key/generate "{\"team_id\":\"$TEAM\",\"key_alias\":\"rate-limit-$SUFFIX\",\"rpm_limit\":2}" | jq -r .key)
KEYS+=("$KEY_RL")
CODES=""; for i in 1 2 3 4; do CODES+="$(chat "$KEY_RL" claude-sonnet) "; done
[ "$CODES" = "200 200 429 429 " ] && ok "límite aplicado: $CODES" || bad "se esperaba '200 200 429 429', dio: $CODES"

echo "6. Budget agotado"
TEAM2=$(admin /team/new "{\"team_alias\":\"sin-presupuesto-$SUFFIX\",\"max_budget\":0.000001}" | jq -r .team_id)
TEAMS+=("$TEAM2")
KEY2=$(admin /key/generate "{\"team_id\":\"$TEAM2\"}" | jq -r .key)
KEYS+=("$KEY2")
chat "$KEY2" claude-sonnet >/dev/null
echo "     esperando que se registre el gasto (15s)..."; sleep 15
CODE=$(chat "$KEY2" claude-sonnet)
[[ "$CODE" =~ ^(400|422|429)$ ]] && ok "bloqueado por presupuesto ($CODE)" || bad "debería bloquearse por presupuesto (dio $CODE)"

echo "7. Gasto registrado"
# LiteLLM escribe el gasto en la base por lotes: recién reiniciado puede tardar.
for i in $(seq 1 10); do
  SPEND=$(curl -s "$URL/team/info?team_id=$TEAM" -H "Authorization: Bearer $MASTER" | jq -r '.team_info.spend')
  awk "BEGIN{exit !($SPEND > 0)}" && break; sleep 3
done
awk "BEGIN{exit !($SPEND > 0)}" && ok "spend del team = USD $SPEND" || bad "no se registró gasto (spend=$SPEND)"

echo; echo "Resultado: $PASS OK, $FAIL FAIL"
[ $FAIL = 0 ]
