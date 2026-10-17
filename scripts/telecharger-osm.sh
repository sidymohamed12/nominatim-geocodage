#!/usr/bin/env bash
#
# Télécharge l'extrait OpenStreetMap intégré à l'image dans data/region.osm.pbf
# et vérifie son empreinte MD5 publiée par Geofabrik.
#
# Par défaut : Sénégal. Geofabrik ne publie pas d'extrait « Sénégal seul » :
# l'extrait couvre le Sénégal et la Gambie (enclavée dans le Sénégal). Pour
# limiter les résultats au Sénégal, les clients passent countrycodes=sn.
# Autre région : OSM_URL=<URL d'un .osm.pbf Geofabrik> (le .md5 voisin est vérifié).
#
# Usage : ./scripts/telecharger-osm.sh   (OSM_URL pour changer d'extrait)

set -Eeuo pipefail

OSM_URL=${OSM_URL:-https://download.geofabrik.de/africa/senegal-and-gambia-latest.osm.pbf}
CIBLE=data/region.osm.pbf

cd "$(dirname "$0")/.."
mkdir -p data

echo "Téléchargement de ${OSM_URL}"
curl -fL --retry 3 --retry-delay 5 -o "${CIBLE}.tmp" "$OSM_URL"

attendu=$(curl -fsSL --retry 3 "${OSM_URL}.md5" | cut -d' ' -f1)
obtenu=$(md5sum "${CIBLE}.tmp" | cut -d' ' -f1)
if [ "$attendu" != "$obtenu" ]; then
    echo "ERREUR : MD5 différent (attendu ${attendu}, obtenu ${obtenu})" >&2
    rm -f "${CIBLE}.tmp"
    exit 1
fi

mv "${CIBLE}.tmp" "$CIBLE"
echo "OK : ${CIBLE} ($(du -h "$CIBLE" | cut -f1), md5 ${obtenu})"
