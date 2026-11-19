# Gateway IA SOFSA — LiteLLM + Langfuse

Gateway corporativo de IA.
Las apps llaman a un único endpoint compatible con OpenAI y Anthropic. El gateway decide el proveedor y el modelo, aplica keys, límites y presupuestos, y manda las trazas a Langfuse.

```
config/config.yaml         Modelos y alias del gateway (el mismo para dev, test y prod)
config/config.local.yaml   Los mismos alias con respuestas mock, para probar en la notebook
deploy/gateway/            LiteLLM, nginx, Postgres y Redis
deploy/langfuse/           Langfuse (web, worker, ClickHouse, Postgres, Redis, RustFS)
scripts/smoke-test.sh      Valida permisos, rate limit, presupuesto y gasto
scripts/carga-inicial.sh   Crea los teams y keys de SACO, SOFIA, plataforma y monitoreo
scripts/backup.sh          Backup de Postgres y ClickHouse con copia fuera de la VM
```

## VMs y ambientes

| VM | Rol | Ambiente | Archivo de variables |
|---|---|---|---|
| VM 1 | `gateway` (su Postgres y su Redis son los de prod) | prod | `deploy/gateway/prod.env` |
| VM 2 | `gateway` (LiteLLM apunta a la base y el Redis de VM 1) | prod | `deploy/gateway/prod.env` |
| VM 3 | `langfuse` | prod | `deploy/langfuse/prod.env` |
| VM 4 | `gateway` dev y test + `langfuse` no productivo | dev, test | `deploy/gateway/dev.env`, `test.env` y `deploy/langfuse/dev.env` |

## Desplegar

1. Clonar el repo en la VM.
2. Copiar el `.env.example` del rol a `<ambiente>.env` y completar los valores vacíos. Si falta uno obligatorio, `docker compose` lo avisa. VM 1 y VM 2 llevan la **misma** master key y salt key. Guardar una copia de los secretos fuera de la VM.
3. Desde `deploy/<rol>/`:
   ```bash
   git checkout <tag>
   docker compose --env-file <ambiente>.env up -d --wait
   ```
   `--wait` vuelve recién cuando los servicios están sanos, y da error si no lo logran.
4. La primera vez, y cada vez que se actualiza LiteLLM: `./scripts/smoke-test.sh <URL> <master key>`.
5. Solo la primera vez: `./scripts/carga-inicial.sh <URL> <master key>` y el cron de `./scripts/backup.sh gateway|langfuse` con `BACKUP_DEST` apuntando fuera de la VM.

**Ramas:** `feat/*` → PR a `dev` → `test` → `main`. El CI corre estos mismos comandos para `dev` y `test` en VM 4. `main` se despliega a mano en prod, con un tag por versión y de a una VM. Para volver atrás, se hace `git checkout` del tag anterior y otra vez `up -d --wait`, y se restaura el backup si hubo migraciones de base.

## Probar en la notebook

Requisitos: Docker, git, curl y jq (en Windows, Git Bash o WSL).

1. Copiar `deploy/gateway/.env.example` a `deploy/gateway/local.env` y cambiar:
   - `COMPOSE_PROJECT_NAME=gateway-local`, `ENV_FILE=local.env` y `CONFIG_FILE=config.local.yaml`;
   - `HTTP_PORT` por un puerto libre;
   - completar los valores vacíos con cualquier cosa (las keys de LiteLLM empiezan con `sk-`).
2. En `deploy/gateway/`: `docker compose --env-file local.env up -d --wait`.
3. `./scripts/smoke-test.sh http://localhost:<HTTP_PORT> <master key>` tiene que terminar en `8 OK, 0 FAIL`.
4. Langfuse es igual, con `deploy/langfuse/local.env`. El proyecto y sus keys se crean desde la consola.
5. Para bajar todo: `docker compose --env-file local.env down -v` en cada carpeta.

## Notas
- `LITELLM_SALT_KEY` cifra las credenciales en la base. **No se cambia nunca** después de cargarlas.
- La imagen de LiteLLM está fijada en `v1.108.0`. Para cambiarla, volver a correr el smoke test.
- Prometheus lee `/metrics/` de **cada VM**, no del balanceador, con la key `monitoreo-prometheus`.
- VM 2 levanta Postgres y Redis, pero hasta tener alta disponibilidad quedan sin uso: su `DB_HOST` y su `REDIS_HOST` apuntan a VM 1. Con la alta disponibilidad pasan a ser réplicas.
- El balanceador entre VM 1 y VM 2 está pendiente.
