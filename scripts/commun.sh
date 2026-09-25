# Fonctions partagées par les scripts du worklab.
# À inclure avec « source », jamais à lancer seul.
# shellcheck shell=bash

RACINE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_CONF="$RACINE/apps.conf"
ENV_FICHIER="$RACINE/.env"

# Couleurs seulement dans un vrai terminal (pas dans les logs du cron)
if [[ -t 1 ]]; then
  VERT=$'\e[32m' ROUGE=$'\e[31m' JAUNE=$'\e[33m' GRAS=$'\e[1m' NORMAL=$'\e[0m'
else
  VERT='' ROUGE='' JAUNE='' GRAS='' NORMAL=''
fi

etape()  { echo; echo "${GRAS}== $*${NORMAL}"; }
info()   { echo "   $*"; }
ok()     { echo "${VERT}   ✔ $*${NORMAL}"; }
alerte() { echo "${JAUNE}   ⚠ $*${NORMAL}"; }
erreur() { echo "${ROUGE}   ✖ $*${NORMAL}" >&2; }
arret()  { erreur "$*"; exit 1; }

# Lit une variable du fichier .env sans l'exécuter (le fichier n'est pas
# du bash). Affiche une valeur vide si la variable est absente.
lire_env() {
  local nom="$1" valeur=''
  if [[ -f "$ENV_FICHIER" ]]; then
    valeur="$(grep -E "^[[:space:]]*${nom}=" "$ENV_FICHIER" | tail -n 1 | cut -d= -f2- || true)"
    valeur="${valeur%$'\r'}"                 # fichier édité sous Windows
    valeur="${valeur#\"}"; valeur="${valeur%\"}"
    valeur="${valeur#\'}"; valeur="${valeur%\'}"
  fi
  printf '%s' "$valeur"
}

# Charge apps.conf dans des tableaux indexés de la même façon :
# APP_ID, APP_DEPOT, APP_REF, APP_TYPE, APP_FICHIERS, APP_CHEMIN,
# APP_TITRE, APP_DESCRIPTION. S'arrête au premier défaut de format.
charger_apps() {
  APP_ID=() APP_DEPOT=() APP_REF=() APP_TYPE=() APP_FICHIERS=()
  APP_CHEMIN=() APP_TITRE=() APP_DESCRIPTION=()
  [[ -f "$APPS_CONF" ]] || arret "Fichier introuvable : $APPS_CONF"

  local ligne n=0 champs
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    n=$((n + 1))
    ligne="${ligne%$'\r'}"
    [[ -z "${ligne//[[:space:]]/}" || "$ligne" =~ ^[[:space:]]*# ]] && continue
    IFS='|' read -r -a champs <<< "$ligne"
    (( ${#champs[@]} == 8 )) \
      || arret "apps.conf, ligne $n : 8 champs attendus, ${#champs[@]} trouvés."
    [[ "${champs[0]}" =~ ^[a-z0-9-]+$ ]] \
      || arret "apps.conf, ligne $n : id « ${champs[0]} » invalide (a-z, 0-9, -)."
    [[ "${champs[3]}" == statique || "${champs[3]}" == conteneur ]] \
      || arret "apps.conf, ligne $n : type « ${champs[3]} » invalide (statique ou conteneur)."
    [[ "${champs[5]}" =~ ^/[a-z0-9-]+/$ ]] \
      || arret "apps.conf, ligne $n : chemin « ${champs[5]} » invalide (ex. /plan/)."
    APP_ID+=("${champs[0]}")
    APP_DEPOT+=("${champs[1]}")
    APP_REF+=("${champs[2]}")
    APP_TYPE+=("${champs[3]}")
    APP_FICHIERS+=("${champs[4]}")
    APP_CHEMIN+=("${champs[5]}")
    APP_TITRE+=("${champs[6]}")
    APP_DESCRIPTION+=("${champs[7]}")
  done < "$APPS_CONF"
  (( ${#APP_ID[@]} > 0 )) || arret "apps.conf ne contient aucune app."
}
