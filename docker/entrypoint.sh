#!/usr/bin/env bash
#
# Démarrage du conteneur Nominatim :
#   1. entrée /etc/passwd pour l'UID arbitraire d'OpenShift ;
#   2. initialisation de PostgreSQL au premier démarrage (volume /data vide) ;
#   3. import de l'extrait OSM s'il n'a jamais été importé, ou si l'image
#      embarque un extrait différent de celui déjà importé (réimport complet) ;
#   4. API Nominatim sur le port 8080.
#
# PostgreSQL n'écoute que sur une socket Unix locale : seule l'API du
# conteneur y accède, sans mot de passe.
#
# Un import interrompu (pod tué, mémoire insuffisante…) n'écrit pas le
# marqueur : il est repris de zéro au démarrage suivant.

set -Eeuo pipefail

DATA_DIR=${DATA_DIR:-/data}
PGDATA=${DATA_DIR}/pgdata
PROJET=${DATA_DIR}/projet
MARQUEUR=${DATA_DIR}/import.sha256
PBF=${OSM_FILE:-/osm/region.osm.pbf}
SOCKET_DIR=/tmp
PORT=${PORT:-8080}

# Réglages PostgreSQL : valeurs prévues pour un pod de 4 Gio (import compris).
PG_SHARED_BUFFERS=${PG_SHARED_BUFFERS:-512MB}
PG_MAINTENANCE_WORK_MEM=${PG_MAINTENANCE_WORK_MEM:-1GB}
PG_WORK_MEM=${PG_WORK_MEM:-32MB}
PG_EFFECTIVE_CACHE_SIZE=${PG_EFFECTIVE_CACHE_SIZE:-2GB}
IMPORT_THREADS=${IMPORT_THREADS:-2}
API_WORKERS=${API_WORKERS:-2}

log() { printf '%s [nominatim] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# ── 1. Utilisateur ───────────────────────────────────────────────────────
if ! whoami >/dev/null 2>&1; then
    if [ -w /etc/passwd ]; then
        echo "nominatim:x:$(id -u):0:Nominatim:${DATA_DIR}:/usr/sbin/nologin" >> /etc/passwd
    else
        log "ERREUR : UID $(id -u) inconnu et /etc/passwd non modifiable"
        exit 1
    fi
fi
export HOME=${DATA_DIR}

[ -r "$PBF" ] || { log "ERREUR : extrait OSM introuvable ($PBF)"; exit 1; }

# ── 2. PostgreSQL ────────────────────────────────────────────────────────
if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    log "Initialisation de PostgreSQL dans ${PGDATA}"
    rm -rf "$PGDATA" "$MARQUEUR"
    mkdir -p "$PGDATA"
    chmod 0700 "$PGDATA"
    initdb --pgdata="$PGDATA" --username=nominatim --auth=trust \
           --encoding=UTF8 --locale=C.UTF-8 >/dev/null
fi

postgres -D "$PGDATA" \
    -c listen_addresses='' \
    -c unix_socket_directories="$SOCKET_DIR" \
    -c shared_buffers="$PG_SHARED_BUFFERS" \
    -c maintenance_work_mem="$PG_MAINTENANCE_WORK_MEM" \
    -c work_mem="$PG_WORK_MEM" \
    -c effective_cache_size="$PG_EFFECTIVE_CACHE_SIZE" \
    -c synchronous_commit=off \
    -c max_wal_size=2GB \
    -c checkpoint_timeout=10min \
    -c random_page_cost=1.1 \
    -c jit=off \
    -c log_min_messages=warning \
    -c log_min_duration_statement=5000 &
PG_PID=$!
API_PID=

# shellcheck disable=SC2329  # appelée via trap
arreter() {
    log "Arrêt demandé"
    [ -n "$API_PID" ] && kill -TERM "$API_PID" 2>/dev/null || true
    # SIGINT = arrêt « fast » : transactions en cours annulées, données intactes.
    kill -INT "$PG_PID" 2>/dev/null || true
    wait "$PG_PID" 2>/dev/null || true
    exit 0
}
trap arreter TERM INT

until pg_isready -h "$SOCKET_DIR" -q; do
    kill -0 "$PG_PID" 2>/dev/null || { log "ERREUR : PostgreSQL ne démarre pas"; exit 1; }
    sleep 1
done

# ── 3. Import ────────────────────────────────────────────────────────────
mkdir -p "$PROJET"
cd "$PROJET"

SHA_PBF=$(sha256sum "$PBF" | cut -d' ' -f1)
if [ "$(cat "$MARQUEUR" 2>/dev/null || true)" != "$SHA_PBF" ]; then
    if [ -s "$MARQUEUR" ]; then
        log "Nouvel extrait OSM dans l'image : réimport complet (API indisponible pendant l'import)"
    else
        log "Premier import de l'extrait OSM (plusieurs dizaines de minutes)"
    fi
    rm -f "$MARQUEUR"
    dropdb -h "$SOCKET_DIR" --if-exists nominatim
    rm -rf "${PROJET:?}/"* "${PROJET}/.env" 2>/dev/null || true

    debut=$(date +%s)
    # En arrière-plan pour qu'un arrêt du pod interrompe l'import sans attendre.
    nominatim import --osm-file "$PBF" --threads "$IMPORT_THREADS" --project-dir "$PROJET" &
    API_PID=$!
    wait "$API_PID"
    API_PID=
    echo "$SHA_PBF" > "$MARQUEUR"
    log "Import terminé en $(( ($(date +%s) - debut) / 60 )) min"
else
    log "Données déjà importées (extrait ${SHA_PBF:0:12})"
fi

# ── 4. API ───────────────────────────────────────────────────────────────
log "API Nominatim sur le port ${PORT}"
# « python -m » : le Python du venv, seul à voir nominatim-api (pas /usr/bin/uvicorn).
python -m uvicorn --factory nominatim_api.server.falcon.server:run_wsgi \
    --host 0.0.0.0 --port "$PORT" --workers "$API_WORKERS" \
    --no-access-log --timeout-graceful-shutdown 20 &
API_PID=$!

# Si l'un des deux processus s'arrête, le conteneur s'arrête (OpenShift le relance).
set +e
wait -n "$PG_PID" "$API_PID"
code=$?
log "Processus terminé (code ${code}) : arrêt du conteneur"
kill -TERM "$API_PID" 2>/dev/null
kill -INT "$PG_PID" 2>/dev/null
wait
exit "$code"
