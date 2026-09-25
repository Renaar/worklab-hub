#!/usr/bin/env bash
# Sauvegarde les classements de Turbo Dactylo (resultats.ndjson) hors du
# volume Docker, dans une copie datée. Garde les 30 copies les plus récentes.
# Code de retour non nul si la sauvegarde échoue (fichier absent ou vide…).
#
# Usage : scripts/sauvegarde-dactylo.sh
# Variables facultatives :
#   BACKUP_DIR     dossier des copies (défaut /opt/backups/worklab)
#   HEARTBEAT_URL  URL appelée après une sauvegarde réussie (aussi lue dans .env)

set -euo pipefail
# shellcheck source=scripts/commun.sh
source "$(dirname "$0")/commun.sh"
cd "$RACINE"

DOSSIER="${BACKUP_DIR:-/opt/backups/worklab}"
GARDER=30
HEARTBEAT_URL="${HEARTBEAT_URL:-$(lire_env HEARTBEAT_URL)}"

mkdir -p "$DOSSIER" || arret "Impossible de créer $DOSSIER (lancer avec sudo ?)."
date_copie="$(date +%Y-%m-%d_%H%M%S)"
copie="$DOSSIER/resultats-$date_copie.ndjson"
temp="$DOSSIER/.en-cours-$date_copie"
trap 'rm -f "$temp"' EXIT

# « docker compose cp » marche aussi quand le conteneur est arrêté.
# On écrit d'abord dans un fichier temporaire : jamais de copie à moitié écrite.
if ! docker compose cp turbo-dactylo:/app/data/resultats.ndjson "$temp" 2>/dev/null; then
  arret "Échec : resultats.ndjson introuvable (conteneur turbo-dactylo absent, ou volume vide ?)."
fi
[[ -s "$temp" ]] || arret "Échec : resultats.ndjson est vide, rien à sauvegarder."
mv "$temp" "$copie"
ok "Sauvegarde : $copie ($(wc -l < "$copie") résultat(s))"

# Rotation : on garde les 30 copies les plus récentes. Le nom daté se trie
# dans l'ordre chronologique : les plus anciennes sont en tête de liste.
copies=("$DOSSIER"/resultats-*.ndjson)
en_trop=$(( ${#copies[@]} - GARDER ))
if (( en_trop > 0 )); then
  rm -f -- "${copies[@]:0:en_trop}"
  info "$en_trop ancienne(s) copie(s) supprimée(s), $GARDER conservées."
fi

# Signal de vie facultatif (ex. un service de surveillance des tâches cron)
if [[ -n "$HEARTBEAT_URL" ]]; then
  curl -fsS --max-time 10 --retry 3 -o /dev/null "$HEARTBEAT_URL" \
    || alerte "Sauvegarde faite, mais l'appel à HEARTBEAT_URL a échoué."
fi
