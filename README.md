# Gateway IA SOFSA — LiteLLM + Langfuse

Gateway corporativo de IA (Ítem A del pliego PLIEG-2026-82465799-APN-GSYP#SOFSA).
Arquitectura: `docs/arquitectura.png`.

```
config/config.yaml        Config real, igual para dev / test / prod (secretos por env vars)
envs/.env.example         Variables a completar por ambiente
local/                    Entorno de prueba local con modelos mock (sin credenciales)
local/langfuse/           Langfuse local (web, worker, ClickHouse, Postgres, Redis, MinIO)
scripts/smoke-test.sh     Prueba de gobierno: permisos, rate limit, budget, gasto
scripts/carga-inicial.sh  Teams y keys iniciales (SACO, SOFIA, plataforma, monitoreo); se puede repetir
scripts/audit-logging.sh  Auditoría de la política de logging de contenido (para cron, sale 1 si hay desvíos)
config/presidio-ar.json   Reconocedores de datos personales argentinos para Presidio (DNI, CUIT/CUIL, CBU, patente)
docs/                     Diagrama de arquitectura
```

---

## Paso a paso local (sin credenciales)

### 0. Requisitos
Docker Desktop (o Docker + compose v2), git, curl y jq. En Windows, correr los scripts desde WSL o Git Bash.

### 1. Levantar LiteLLM + Postgres + Redis
```bash
cd local
cp .env.local.example .env
docker compose up -d
docker compose logs -f litellm      # esperar "Uvicorn running" (las migraciones tardan 1-2 min la primera vez)
```

### 2. Primera llamada
```bash
curl http://localhost:4001/v1/chat/completions \
  -H "Authorization: Bearer sk-local-master-1234" -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet","messages":[{"role":"user","content":"hola"}]}'
```
Tiene que devolver `"Respuesta mock del gateway (claude-sonnet)."`.
Consola web: http://localhost:4001/ui (usuario `admin` / `admin-local`).

### 3. Prueba de gobierno
```bash
cd ..
./scripts/smoke-test.sh
```
Crea un team y una virtual key, y valida:
- que la key llama al modelo habilitado;
- que se bloquea un modelo no habilitado para el team;
- el rate limit (2 req/min: espera `200 200 429 429`);
- el corte por presupuesto;
- que el gasto quede registrado.

Tiene que terminar en `0 FAIL`.

### 4. Alta disponibilidad (2 instancias, como en prod)
```bash
cd local
docker compose --profile ha up -d
cd .. && ./scripts/smoke-test.sh http://localhost:8080
```
nginx reparte entre las 2 instancias. Si el rate limit sigue dando 429, Redis está compartiendo los contadores.

### 5. Langfuse (trazas)
```bash
cd local/langfuse && docker compose up -d     # UI en http://localhost:3002 (admin@local.test / admin-local-1234)
```
El proyecto y sus keys se crean solos al arrancar, y `local/.env` ya los tiene. Hacer una llamada y ver la traza en Langfuse. Usa unos 2,5 GB de RAM.

Otras trazas: Jaeger (collector OTel local) en http://localhost:16686.

### 6. Opcionales
- **Teams y keys de ejemplo:** `./scripts/carga-inicial.sh` (SACO, SOFIA, plataforma y monitoreo). Las keys se muestran una sola vez.
- **Enmascarado de datos personales:** `docker compose --profile pii up -d` y descomentar `guardrails:` en `local/config.local.yaml`. Suma más de 1 GB de RAM.
- **Anthropic real:** completar `ANTHROPIC_API_KEY` en `local/.env` y usar el modelo `claude-sonnet-real` (gasta).
- **Auditoría de logging:** `./scripts/audit-logging.sh`.

### 7. Bajar todo
```bash
cd local && docker compose --profile ha --profile pii down      # agregar -v para borrar la base
cd langfuse && docker compose down
```

---

## Notas
- `LITELLM_SALT_KEY` cifra las credenciales en la base. **No se cambia nunca** después de cargar credenciales.
- La imagen está fijada en `ghcr.io/berriai/litellm:v1.108.0` (la probada). Para cambiarla, volver a correr el smoke test. No usar `main-stable` en prod.
- Los presupuestos (`max_budget`) están en USD y se calculan con el precio por token del modelo.
