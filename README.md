# Worklab

Le hub des apps pédagogiques du collège, hébergées sur le serveur « worklab »
(`172.16.0.17`). Une seule adresse, une seule stack Docker, une commande pour
tout mettre à jour.

| Adresse | App |
|---|---|
| `http://172.16.0.17/` | Page d'accueil du hub |
| `http://172.16.0.17/plan/` | Plan de Classe |
| `http://172.16.0.17/hasard/` | Heureux Hasard |
| `http://172.16.0.17/dactylo/` | Turbo Dactylo |

Tout tourne sur le serveur : aucune page ne charge quoi que ce soit depuis
Internet. Le serveur a seulement besoin d'Internet pour récupérer les dépôts
GitHub lors d'une mise à jour.

La procédure d'installation pas à pas est dans [DEPLOIEMENT.md](DEPLOIEMENT.md).

## Architecture

```
Navigateur ──► :HUB_PORT (80)   conteneur « hub » (nginx:stable-alpine)
                 ├─ /           → page d'accueil du hub         (fichiers dans l'image)
                 ├─ /plan/      → Plan-De-Classe/index.html     (fichier copié dans l'image)
                 ├─ /hasard/    → Heureux-Hasard/public/        (fichiers copiés dans l'image)
                 └─ /dactylo/   → conteneur « turbo-dactylo »:3000 (HTTP + WebSocket, préfixe retiré)
```

- **Apps statiques** : pas de conteneur à elles. Leurs fichiers sont copiés
  dans l'image du hub au moment du build. Une mise à jour = un nouveau build.
- **Turbo Dactylo** : son propre conteneur, construit avec le `Dockerfile` de
  son dépôt. Il ne publie **aucun port** : seul le hub le joint, par le
  réseau interne de la stack. Ses résultats sont dans le volume
  `worklab-hub_dactylo-data`.
- **Un seul port publié**, celui du hub. Attention : Docker contourne ufw.
  Un port publié est ouvert au réseau, quelles que soient les règles ufw.
- **Le hub ne dépend pas de Turbo Dactylo** : si le jeu est arrêté, l'accueil,
  `/plan/` et `/hasard/` marchent. `/dactylo/` affiche une page « Cette app
  est momentanément indisponible », puis revient seule quand le jeu redémarre.

## Rôle de chaque fichier

```
worklab-hub/
├── apps.conf                  la liste des apps : la seule source de vérité
├── docker-compose.yml         la stack : services hub et turbo-dactylo
├── .env.example               modèle du fichier .env (port, PIN)
├── hub/
│   ├── Dockerfile             image du hub (nginx + fichiers)
│   ├── nginx.conf             routes, proxy, en-têtes, pages d'erreur
│   ├── erreurs/               pages d'erreur en français (404, 502/504)
│   └── site/
│       ├── index.html         modèle de la page d'accueil (sans la liste des apps)
│       └── icones/            une icône SVG par app (<id>.svg), defaut.svg sinon
├── scripts/
│   ├── deploy.sh              installe ou met à jour tout le worklab
│   ├── smoke-test.sh          tests rapides (curl) : routage, sécurité, WebSocket
│   ├── sauvegarde-dactylo.sh  copie datée des classements de Turbo Dactylo
│   └── commun.sh              fonctions partagées par les scripts
└── tests/
    └── dactylo.test.js        courses simulées de bout en bout (Node + ws)
```

Dossiers créés par `deploy.sh`, jamais versionnés :

- `sources/<id>/` : les dépôts des apps, à la version indiquée dans `apps.conf` ;
- `hub/build/` : ce que l'image du hub va contenir (page d'accueil générée,
  fichiers des apps statiques).
- `.env` : réglages locaux et PIN (jamais dans git).

## Mettre à jour

```bash
cd /opt/stacks/worklab-hub
sudo scripts/deploy.sh
```

Le script récupère la dernière version de `worklab-hub` et de chaque app,
reconstruit ce qui a changé, relance la stack et vérifie que tout répond.
Si rien n'a changé, rien ne redémarre.

## Ajouter une app

Règle d'or : **l'app doit utiliser des chemins relatifs** (`style.css`,
`api/…`, et pas `/style.css` ni `/api/…`). Elle sera servie sous un
sous-chemin (`/mon-app/`) et un chemin absolu partirait à la racine du hub.

**App statique** (HTML/CSS/JS, sans serveur) :

1. Ajouter une ligne dans `apps.conf` (le format est expliqué en tête du fichier) :
   ```
   mon-app|https://github.com/Renaar/Mon-App.git|main|statique|public/|/mon-app/|Mon App|Ce que fait mon app en une phrase.
   ```
2. Facultatif : ajouter une icône `hub/site/icones/mon-app.svg` (SVG avec
   `stroke="currentColor"` pour prendre la couleur de la carte).
3. Commiter, pousser, puis `sudo scripts/deploy.sh` sur le serveur.

La carte apparaît sur l'accueil et les fichiers sont servis sous `/mon-app/`.

**App avec son propre serveur** (type `conteneur`), en plus de la ligne dans
`apps.conf` (champ fichiers : `-`) :

1. un service dans `docker-compose.yml`, **sans `ports:`**, avec
   `build: ./sources/<id>` (copier le modèle de `turbo-dactylo`) ;
2. une route dans `hub/nginx.conf` (copier le bloc `/dactylo/` : variable
   dans `proxy_pass` et `rewrite … break`).

## Figer une version d'app

Dans `apps.conf`, remplacer `main` par un identifiant de commit complet
(40 caractères). `deploy.sh` utilisera exactement ce commit jusqu'à ce qu'on
remette `main`.

## Changer de port

Dans `.env`, mettre par exemple `HUB_PORT=8080`, puis `sudo scripts/deploy.sh`.
Le hub est alors sur `http://172.16.0.17:8080/`. Les redirections restent
justes, car elles sont relatives.

## Sauvegarder les classements de Turbo Dactylo

```bash
sudo scripts/sauvegarde-dactylo.sh
```

Une copie datée de `resultats.ndjson` est écrite dans `/opt/backups/worklab/`.
Les 30 plus récentes sont gardées. Le script renvoie une erreur si le fichier
est introuvable ou vide. Si `HEARTBEAT_URL` est défini dans `.env`, cette
adresse est appelée après chaque sauvegarde réussie (pour un service de
surveillance, par exemple).

Tous les jours à 18 h, avec le cron de root (`sudo crontab -e`) :

```cron
0 18 * * * /opt/stacks/worklab-hub/scripts/sauvegarde-dactylo.sh >> /var/log/worklab-sauvegarde.log 2>&1
```

Restaurer une copie :

```bash
cd /opt/stacks/worklab-hub
sudo docker compose cp /opt/backups/worklab/resultats-AAAA-MM-JJ_HHMMSS.ndjson turbo-dactylo:/app/data/resultats.ndjson
sudo docker compose restart turbo-dactylo
```

## Tester

- `scripts/smoke-test.sh` : lancé automatiquement par `deploy.sh`. Environ
  50 contrôles avec `curl` (routes, redirections, fichiers protégés,
  remontée de dossier, modération, poignée de main WebSocket). S'arrête au
  premier échec.
- `tests/dactylo.test.js` : de vraies courses simulées (3 joueurs, 2 équipes,
  35 clients, 2 minutes d'inactivité). Les résultats de test sont effacés à
  la fin si le PIN est fourni. Sans installer Node sur le serveur :
  ```bash
  cd /opt/stacks/worklab-hub
  sudo docker run --rm --network host -v "$PWD/tests:/tests" -w /tests \
    -e HUB_URL=http://localhost -e TURBO_PIN='le-PIN-du-.env' \
    node:20-alpine sh -c "npm install --silent && node dactylo.test.js"
  ```
  (avec `HUB_URL=http://localhost:8080` si le port a changé).

## Détails techniques

- nginx suit la branche **stable** (`nginx:stable-alpine`) : uniquement des
  correctifs, pas de nouveautés.
- Fichiers cachés (`.git`, `.env`…) : toujours 404. En plus, ils ne sont
  jamais copiés dans l'image.
- Les pages HTML sont envoyées avec `Cache-Control: no-cache` : une mise à
  jour est visible sans `Ctrl+F5`.
- Fuseau horaire : `Europe/Zurich` pour les deux services. L'image de Turbo
  Dactylo n'a pas les fuseaux horaires : ceux du serveur sont prêtés en
  lecture seule (`/usr/share/zoneinfo`).
- Logs : 3 fichiers de 10 Mo au maximum par service (`docker compose logs`).
