# nominatim-senegal

Image Docker prête à l'emploi de [Nominatim](https://nominatim.org) 5.3.2, le géocodeur OpenStreetMap, chargée avec l'extrait **Sénégal**. On peut charger une autre région (voir [Autre région](#autre-région)).

- **Un seul conteneur :** PostgreSQL 16, PostGIS et l'API Nominatim. La base est importée automatiquement au premier démarrage, et réimportée quand l'image apporte de nouvelles données.
- **Extrait OSM embarqué dans l'image.** Le conteneur n'a pas besoin d'accès internet, et chaque version de l'image correspond à un instantané précis des données.
- **Multi-architecture :** `linux/amd64`, `linux/arm64` et `linux/s390x`.
- **Compatible OpenShift :** UID arbitraire du groupe 0, aucun privilège. Fonctionne aussi sur Kubernetes, Docker et Podman.

Ce dépôt fournit l'image et des exemples de déploiement. **Le déploiement et l'exploitation restent à votre charge.**

## Image publiée : inutile de la reconstruire

Une image prête à l'emploi est publiée sur Docker Hub, construite avec les valeurs par défaut de ce dépôt :

```
docker.io/sidymohamed12/nominatim-senegal:latest   # ou un tag fixe : v1, v2, v3…
```

| Réglage                         | Valeur de l'image publiée                                                                |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| Extrait OSM                     | Sénégal + Gambie (Geofabrik `senegal-and-gambia`)                                        |
| Langue par défaut des résultats | français                                                                                 |
| Architectures                   | `linux/amd64`, `linux/arm64`, `linux/s390x`                                              |
| Données                         | extrait du jour du build ; la date figure dans le label `org.openstreetmap.extrait.date` |

Si ces valeurs vous conviennent, **utilisez directement cette image** : il n'y a rien à télécharger, construire ni configurer dans GitHub. L'extrait est déjà dans l'image, et seul l'import en base a lieu au premier démarrage. Préférez un tag fixe (`vN`) à `latest` en production : chaque nouvelle version déclenche un réimport, et vous choisissez ainsi le moment.

Ne reconstruisez l'image que pour changer de région, ou pour la publier sur votre propre registre (voir [Construire et publier](#construire-et-publier-avec-github-actions)).

## Démarrage rapide

Avec l'image publiée :

```bash
docker run -d --name nominatim -p 8088:8080 -v nominatim-data:/data --shm-size=512m \
  docker.io/sidymohamed12/nominatim-senegal:latest
docker logs -f nominatim              # 1er démarrage : import (20 à 60 min)
curl 'localhost:8088/search?q=Sandaga&format=jsonv2&countrycodes=sn'
curl 'localhost:8088/reverse?lat=14.672&lon=-17.435&format=jsonv2'
curl 'localhost:8088/lookup?osm_ids=W123456&format=jsonv2'
```

Ou en construisant l'image depuis ce dépôt : `./scripts/telecharger-osm.sh`, puis `docker compose up --build`.

L'API est celle de Nominatim : `/search`, `/reverse`, `/lookup`, `/details` et `/status`. Les paramètres sont décrits dans la [documentation de l'API Nominatim](https://nominatim.org/release-docs/latest/api/Overview/).

La base est conservée dans le volume `nominatim-data`. `docker compose down -v` la supprime, ce qui déclenche un réimport au prochain démarrage.

## Contenu

```
nominatim-senegal/
├── Dockerfile                      # PostgreSQL 16 + PostGIS + Nominatim, Ubuntu 24.04
├── compose.yaml                    # essai local : docker compose up --build
├── docker/entrypoint.sh            # init PostgreSQL → import si besoin → API :8080
├── scripts/telecharger-osm.sh      # extrait Geofabrik → data/region.osm.pbf (MD5 vérifié)
├── kubernetes/                     # exemple Kustomize (Kubernetes ou OpenShift)
│   ├── kustomization.yaml
│   ├── deployment.yaml             # 1 réplique, Recreate, probes, sécurité restreinte
│   ├── pvc.yaml                    # 20 Gio pour la base
│   ├── service.yaml                # ClusterIP
│   └── networkpolicy.yaml          # accès limité au namespace
├── .github/workflows/nominatim-image.yml   # build + publication Docker Hub (v1, v2…)
└── data/                           # ignoré par git : l'extrait OSM téléchargé
```

## Fonctionnement

```
Build                                       Conteneur
─────                                       ─────────
extrait Geofabrik (~100 Mo) ──► image vN ──► 1er démarrage : initdb + import (20–60 min)
                                             démarrages suivants : API directe
                                             image aux données changées : réimport
```

- **PostgreSQL reste local.** Il écoute sur une socket Unix, sans port réseau ni mot de passe. Seule l'API Nominatim (uvicorn) est exposée, sur le port 8080.
- **Import automatique.** Au démarrage, l'empreinte SHA-256 de l'extrait embarqué est comparée à celle du dernier import réussi (`/data/import.sha256`). Si elles diffèrent, la base est réimportée. Un import interrompu est repris de zéro au démarrage suivant.
- **Sénégal et Gambie.** Geofabrik ne publie pas d'extrait du Sénégal seul : l'extrait officiel est `senegal-and-gambia`, et la Gambie, enclavée dans le Sénégal, pèse très peu. Pour ne garder que le Sénégal, les clients ajoutent `countrycodes=sn` à `/search`.

## Construire et publier avec GitHub Actions

Le workflow `.github/workflows/nominatim-image.yml` télécharge l'extrait, construit l'image pour chaque architecture et la publie. Les versions sont taguées `v1`, `v2`… et `latest`.

Dans _Settings → Secrets and variables → Actions_ :

| Type     | Nom                    | Défaut                                | Rôle                                            |
| -------- | ---------------------- | ------------------------------------- | ----------------------------------------------- |
| Variable | `DOCKERHUB_USERNAME`   | —                                     | Compte ou organisation Docker Hub (obligatoire) |
| Secret   | `DOCKERHUB_TOKEN`      | —                                     | Jeton Docker Hub « Read & Write » (obligatoire) |
| Variable | `DOCKERHUB_REPOSITORY` | `nominatim-senegal`                   | Nom de l'image                                  |
| Variable | `PLATEFORMES`          | `linux/amd64,linux/arm64,linux/s390x` | Architectures publiées                          |
| Variable | `OSM_URL`              | extrait Sénégal + Gambie              | Extrait `.osm.pbf` Geofabrik à embarquer        |

Le premier build est long, de l'ordre de 10 à 20 minutes par architecture non native : les paquets s'installent sous émulation QEMU. Les builds suivants réutilisent le cache et ne refont que la couche des données. Pour aller plus vite, limiter `PLATEFORMES` aux architectures utiles.

Pour construire sans GitHub :

```bash
./scripts/telecharger-osm.sh
docker buildx build --platform linux/amd64,linux/s390x -t <registre>/nominatim-senegal:v1 --push .
```

## Déployer

### Kubernetes ou OpenShift

1. `kubernetes/kustomization.yaml` pointe vers l'image publiée. Choisir le tag (`newTag`), ou remplacer `newName` par votre propre image.
2. Appliquer :

```bash
kubectl apply -k kubernetes/       # ou : oc apply -k kubernetes/
kubectl logs -f deploy/nominatim   # suivre l'import (premier démarrage)
```

Le pod passe _Ready_ à la fin de l'import. Depuis le même namespace, le service répond sur `http://nominatim:8080`.

- **Kubernetes standard (hors OpenShift) :** ajouter `fsGroup: 1001` dans le `securityContext` du pod (`deployment.yaml`), pour que le volume soit inscriptible par l'utilisateur de l'image. OpenShift attribue le `fsGroup` tout seul : il ne faut pas l'ajouter.
- **Exposition :** Nominatim n'a ni authentification ni limite de débit. Les exemples le gardent interne au cluster (Service `ClusterIP`, pas d'Ingress ni de Route). Si vous l'exposez, placez devant lui une passerelle qui gère l'authentification et la limitation de débit.

### Docker

```bash
docker run -d --name nominatim -p 8080:8080 -v nominatim-data:/data --shm-size=512m docker.io/sidymohamed12/nominatim-senegal:v1
```

### Mettre à jour les données

Déployer un tag plus récent de l'image publiée, ou publier votre propre image en relançant le workflow. Le conteneur réimporte, et l'API est **indisponible pendant l'import** (20 à 60 min pour le Sénégal). Faire la mise à jour aux heures creuses, ou prévoir un service de secours. Une mise à jour par mois suffit en général.

**Forcer un réimport** sans changer d'image :

```bash
kubectl exec deploy/nominatim -- rm /data/import.sha256
kubectl rollout restart deploy/nominatim
```

## Configuration à l'exécution

| Variable                     | Défaut  | Rôle                                                    |
| ---------------------------- | ------- | ------------------------------------------------------- |
| `IMPORT_THREADS`             | `2`     | Threads de l'import                                     |
| `API_WORKERS`                | `2`     | Processus uvicorn (requêtes en parallèle)               |
| `PG_SHARED_BUFFERS`          | `512MB` | Cache PostgreSQL                                        |
| `PG_MAINTENANCE_WORK_MEM`    | `1GB`   | Mémoire de création des index (import)                  |
| `PG_WORK_MEM`                | `32MB`  | Mémoire par tri ou jointure                             |
| `PG_EFFECTIVE_CACHE_SIZE`    | `2GB`   | Estimation du cache disponible                          |
| `NOMINATIM_DEFAULT_LANGUAGE` | `fr`    | Langue des résultats quand la requête ne la précise pas |

**Ressources pour le Sénégal :**

- **Mémoire :** 2 Gio demandés et 4 Gio de limite. Si le conteneur est tué pour manque de mémoire pendant l'import (`OOMKilled`), monter à 6 Gio.
- **Disque :** PVC de 20 Gio.
- **Durée de l'import :** pour l'accélérer, augmenter `IMPORT_THREADS` et la limite CPU.

## Autre région

Choisir un extrait `.osm.pbf` sur [download.geofabrik.de](https://download.geofabrik.de/), puis :

```bash
OSM_URL=https://download.geofabrik.de/africa/ivory-coast-latest.osm.pbf ./scripts/telecharger-osm.sh
docker compose up --build
```

En CI, renseigner la variable `OSM_URL`. Pour une grande région, agrandir le PVC, la mémoire et la `startupProbe` (2 h par défaut). Pensez aussi à renommer l'image (`DOCKERHUB_REPOSITORY`).

## Limites

- **Pas d'autocomplétion par préfixe.** `Sandaga` est trouvé, mais pas `Sanda`. Pour une recherche au fil de la frappe, associez [photon-senegal](../photon-senegal), construit sur les mêmes données OpenStreetMap et les mêmes identifiants.
- **Une seule réplique**, et une indisponibilité pendant les réimports.

## Licences

- Nominatim : GPL-3.0 ou ultérieure.
- Données : © les contributeurs [OpenStreetMap](https://www.openstreetmap.org/copyright), licence ODbL. **L'attribution « © OpenStreetMap contributors » doit être affichée avec les résultats.**
