#!/usr/bin/env bash
# Déploie ou met à jour tout le worklab. Idempotent : même commande pour la
# première installation et pour chaque mise à jour.
#
#   1. vérifie les prérequis et le fichier .env ;
#   2. met à jour worklab-hub lui-même (git pull --ff-only) ;
#   3. clone ou met à jour chaque app de apps.conf dans sources/ ;
#   4. prépare hub/build/ (page d'accueil + fichiers des apps statiques) ;
#   5. construit et (re)lance la stack, puis supprime les images inutiles ;
#   6. lance scripts/smoke-test.sh et affiche un résumé.
#
# Usage : scripts/deploy.sh

set -euo pipefail
# shellcheck source=scripts/commun.sh
source "$(dirname "$0")/commun.sh"
cd "$RACINE"

# --- 1. Prérequis ----------------------------------------------------------

etape "Prérequis"
for outil in git docker curl; do
  command -v "$outil" >/dev/null || arret "« $outil » n'est pas installé."
done
version_compose="$(docker compose version --short 2>/dev/null || true)"
if ! [[ "$version_compose" =~ ^v?([0-9]+) ]] || (( BASH_REMATCH[1] < 2 )); then
  arret "Docker Compose v2 est requis (commande « docker compose »)."
fi
docker info >/dev/null 2>&1 \
  || arret "Impossible de joindre Docker. Lancer le script avec sudo ?"
ok "git, docker, docker compose $version_compose, curl"

# --- 2. Mise à jour de worklab-hub lui-même --------------------------------

etape "Mise à jour de worklab-hub"
if [[ -n "${WORKLAB_DEJA_A_JOUR:-}" ]]; then
  ok "à jour ($(git rev-parse --short HEAD))"
elif ! git symbolic-ref -q HEAD >/dev/null; then
  # HEAD détachée = retour arrière volontaire sur un ancien commit
  # (voir DEPLOIEMENT.md) : on déploie cette version sans la mettre à jour.
  alerte "version figée sur $(git rev-parse --short HEAD) (retour arrière) : pas de git pull."
  alerte "Pour revenir à la version courante : git checkout main"
elif ! git rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
  alerte "la branche $(git branch --show-current) ne suit aucune branche distante : pas de git pull."
else
  avant="$(git rev-parse HEAD)"
  git pull --ff-only --quiet || arret "git pull impossible (modifications locales ?). Voir « git status »."
  if [[ "$(git rev-parse HEAD)" != "$avant" ]]; then
    ok "mis à jour vers $(git rev-parse --short HEAD), relance du script à jour"
    # Le script lui-même a pu changer : on relance la nouvelle version
    WORKLAB_DEJA_A_JOUR=1 exec "$0" "$@"
  fi
  ok "déjà à jour ($(git rev-parse --short HEAD))"
fi

# --- Fichier .env -------------------------------------------------------------

etape "Fichier .env"
[[ -f "$ENV_FICHIER" ]] \
  || arret "Fichier .env absent. Le créer avec : cp .env.example .env  puis l'éditer."
pin="$(lire_env TURBO_PIN)"
case "$pin" in
  '')                 arret "TURBO_PIN est vide dans .env." ;;
  turbo|à-changer)    arret "TURBO_PIN vaut encore « $pin » dans .env : choisir un vrai PIN." ;;
esac
port="$(lire_env HUB_PORT)"; port="${port:-80}"
[[ "$port" =~ ^[0-9]+$ ]] || arret "HUB_PORT invalide dans .env : « $port »."
ok "TURBO_PIN défini, HUB_PORT=$port"

# --- 3. Sources des apps ------------------------------------------------------

etape "Sources des apps (apps.conf)"
charger_apps
mkdir -p sources
for i in "${!APP_ID[@]}"; do
  id="${APP_ID[$i]}" depot="${APP_DEPOT[$i]}" ref="${APP_REF[$i]}"
  dossier="sources/$id"
  if [[ ! -d "$dossier/.git" ]]; then
    rm -rf "$dossier"
    git init --quiet "$dossier"
    git -C "$dossier" remote add origin "$depot"
  else
    git -C "$dossier" remote set-url origin "$depot"
  fi
  # Même méthode pour une branche ou un commit : on récupère uniquement la
  # version demandée (--depth 1 : pas d'historique, clone léger).
  git -C "$dossier" fetch --quiet --depth 1 origin "$ref" \
    || arret "$id : impossible de récupérer « $ref » depuis $depot."
  # --force et clean : toute modification locale est écrasée, le dossier
  # correspond exactement à la version demandée.
  git -C "$dossier" checkout --quiet --force --detach FETCH_HEAD
  git -C "$dossier" clean --quiet -fdx
  ok "$id : $ref ($(git -C "$dossier" rev-parse --short HEAD))"
done

# --- 4. Contenu de l'image du hub ----------------------------------------------

etape "Préparation du hub"

# Échappe un texte pour l'insérer dans du HTML
html() {
  local t="$1"
  t="${t//&/&amp;}"; t="${t//</&lt;}"; t="${t//>/&gt;}"; t="${t//\"/&quot;}"
  printf '%s' "$t"
}

# Carte de la page d'accueil pour l'app n° $1
carte() {
  local i="$1" icone="hub/site/icones/${APP_ID[$1]}.svg"
  [[ -f "$icone" ]] || icone="hub/site/icones/defaut.svg"
  # Lien relatif (« plan/ » et non « /plan/ »)
  cat <<CARTE
    <li>
      <a class="carte" href="$(html "${APP_CHEMIN[$i]#/}")">
        <span class="icone" aria-hidden="true">$(tr -d '\n' < "$icone")</span>
        <h2>$(html "${APP_TITRE[$i]}")</h2>
        <p>$(html "${APP_DESCRIPTION[$i]}")</p>
        <span class="ouvrir">Ouvrir →</span>
      </a>
    </li>
CARTE
}

# On repart d'un dossier vide à chaque fois : aucun fichier ancien ne traîne.
rm -rf hub/build
mkdir -p hub/build/site

# Page d'accueil : le modèle, avec les cartes à la place du repère APPS
while IFS= read -r ligne || [[ -n "$ligne" ]]; do
  if [[ "$ligne" == '<!-- APPS -->' ]]; then
    for i in "${!APP_ID[@]}"; do carte "$i"; done
  else
    printf '%s\n' "$ligne"
  fi
done < hub/site/index.html > hub/build/site/index.html
grep -q 'class="carte"' hub/build/site/index.html \
  || arret "Repère <!-- APPS --> introuvable dans hub/site/index.html."
ok "page d'accueil : ${#APP_ID[@]} app(s)"

# Apps statiques : seuls les fichiers listés dans apps.conf sont copiés
for i in "${!APP_ID[@]}"; do
  [[ "${APP_TYPE[$i]}" == statique ]] || continue
  id="${APP_ID[$i]}"
  cible="hub/build/site${APP_CHEMIN[$i]}"
  mkdir -p "$cible"
  read -r -a fichiers <<< "${APP_FICHIERS[$i]}"
  (( ${#fichiers[@]} > 0 )) || arret "$id : aucun fichier à servir dans apps.conf."
  for f in "${fichiers[@]}"; do
    [[ "$f" != /* && "$f" != *..* ]] || arret "$id : chemin interdit dans apps.conf : « $f »."
    source_f="sources/$id/$f"
    if [[ "$f" == */ ]]; then
      [[ -d "$source_f" ]] || arret "$id : dossier « $f » introuvable dans le dépôt."
      cp -R "$source_f." "$cible"
    else
      [[ -f "$source_f" ]] || arret "$id : fichier « $f » introuvable dans le dépôt."
      cp "$source_f" "$cible"
    fi
  done
  # Fichiers cachés éventuels (.gitkeep…) : jamais dans l'image
  find "$cible" -name '.*' -exec rm -rf {} +
  ok "$id → ${APP_CHEMIN[$i]} ($(find "$cible" -type f | wc -l) fichier(s))"
done

# Hors ligne : aucune ressource ne doit venir d'Internet. Simple alerte, car
# un lien cliquable vers un site externe reste permis.
# On cherche les adresses http(s):// (hors espaces de noms SVG « w3.org ») et
# les adresses « //hôte » dans src, href et url().
externes="$( { grep -rhoE "https?://[^\"'\`) <>]+" hub/build/site sources/*/public \
                 | grep -v '^https\?://www\.w3\.org/'
               grep -rhoE "(src|href)=[\"']//[^\"']+|url\([\"']?//[^)]+" hub/build/site sources/*/public
             } 2>/dev/null | sort -u || true)"
if [[ -n "$externes" ]]; then
  alerte "Références externes trouvées dans les fichiers servis :"
  printf '      %s\n' "$externes"
else
  ok "aucune ressource externe dans les fichiers servis"
fi

# --- 5. Stack Docker ------------------------------------------------------------

etape "Construction et démarrage de la stack"
# Sans cette variable, Docker joint à chaque image une « attestation »
# horodatée : une image reconstruite à l'identique changerait d'identifiant et
# les conteneurs redémarreraient pour rien.
export BUILDX_NO_DEFAULT_ATTESTATIONS=1
# --wait : attend que les healthchecks passent avant de rendre la main
if ! docker compose up -d --build --remove-orphans --wait --wait-timeout 180; then
  docker compose ps
  arret "La stack n'a pas démarré correctement. Logs : docker compose logs --tail 50"
fi
docker image prune -f >/dev/null
docker compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

# --- 6. Vérifications -------------------------------------------------------------

etape "Tests (scripts/smoke-test.sh)"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
url="http://${ip:-localhost}$([[ "$port" == 80 ]] || echo ":$port")/"
if "$RACINE/scripts/smoke-test.sh" "http://localhost:$port"; then
  echo
  echo "${VERT}${GRAS}✔ Déploiement réussi.${NORMAL} Hub : ${GRAS}$url${NORMAL}"
else
  echo
  echo "${ROUGE}${GRAS}✖ Déploiement terminé, mais un test a échoué (voir ci-dessus).${NORMAL}"
  echo "   Hub : $url — logs : docker compose logs --tail 50"
  exit 1
fi
