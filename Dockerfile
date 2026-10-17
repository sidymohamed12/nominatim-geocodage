# syntax=docker/dockerfile:1
#
# Nominatim (géocodeur OpenStreetMap) sur un extrait régional — Sénégal par
# défaut (scripts/telecharger-osm.sh, variable OSM_URL).
#
# Un seul conteneur : PostgreSQL/PostGIS + API Nominatim (uvicorn/falcon).
# L'extrait OSM est intégré à l'image (data/region.osm.pbf, téléchargé avant le
# build) : au premier démarrage, l'import se fait sur le volume persistant ;
# une nouvelle image avec de nouvelles données déclenche un réimport.
#
# Paquets Ubuntu pour toutes les bibliothèques natives (PyICU, psutil, greenlet,
# psycopg) : aucune compilation, ce qui garde rapides les builds sous émulation
# (arm64, s390x… via QEMU).
# Seuls les paquets Python purs viennent de PyPI.
#
# Compatible OpenShift : UID arbitraire, groupe 0, aucun privilège.

FROM ubuntu:24.04

ARG NOMINATIM_VERSION=5.3.2
ARG SQLALCHEMY_VERSION=2.0.54

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH=/opt/nominatim/venv/bin:/usr/lib/postgresql/16/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        postgresql-16 \
        postgresql-16-postgis-3 \
        osm2pgsql \
        python3 \
        python3-venv \
        python3-icu \
        python3-psutil \
        python3-psycopg \
        python3-jinja2 \
        python3-yaml \
        python3-dotenv \
        python3-mwparserfromhell \
        python3-greenlet \
        python3-typing-extensions \
        python3-async-timeout \
        python3-falcon \
        uvicorn \
        ca-certificates \
        curl \
 && rm -rf /var/lib/apt/lists/*

# venv adossé aux paquets système : --no-deps, les dépendances viennent d'apt.
RUN python3 -m venv --system-site-packages /opt/nominatim/venv \
 && /opt/nominatim/venv/bin/pip install --no-cache-dir --no-deps \
        "nominatim-db==${NOMINATIM_VERSION}" \
        "nominatim-api==${NOMINATIM_VERSION}" \
 && DISABLE_SQLALCHEMY_CEXT=1 /opt/nominatim/venv/bin/pip install --no-cache-dir --no-deps \
        "sqlalchemy==${SQLALCHEMY_VERSION}" \
 && nominatim --version

# OpenShift lance le conteneur avec un UID arbitraire du groupe 0 : PostgreSQL
# exige une entrée dans /etc/passwd (ajoutée au démarrage, cf. entrypoint).
# /osm est créé ici (755) : laissé à COPY --chmod=0644, le dossier recevrait
# aussi 0644 et deviendrait infranchissable pour un UID non root.
RUN chmod g=u /etc/passwd \
 && mkdir -p /data /osm \
 && chmod 0755 /osm \
 && chgrp -R 0 /data \
 && chmod -R g=u /data

COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0644 data/region.osm.pbf /osm/region.osm.pbf

ENV NOMINATIM_DATABASE_DSN="pgsql:dbname=nominatim;host=/tmp;user=nominatim" \
    NOMINATIM_DATABASE_WEBUSER=nominatim \
    NOMINATIM_DEFAULT_LANGUAGE=fr \
    NOMINATIM_SERVE_LEGACY_URLS=no

VOLUME ["/data"]
EXPOSE 8080
USER 1001

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
