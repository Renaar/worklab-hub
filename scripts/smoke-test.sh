#!/usr/bin/env bash
# Tests rapides du worklab en marche, uniquement avec curl :
# routage, sécurité et poignée de main WebSocket.
# S'arrête au premier échec (code de retour 1).
#
# Usage : scripts/smoke-test.sh [URL du hub]
#         (par défaut http://localhost:<HUB_PORT du .env>)

set -euo pipefail
# shellcheck source=scripts/commun.sh
source "$(dirname "$0")/commun.sh"

port="$(lire_env HUB_PORT)"
BASE="${1:-http://localhost:${port:-80}}"
BASE="${BASE%/}"
PIN="${TURBO_PIN:-$(lire_env TURBO_PIN)}"
charger_apps

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
nb_tests=0

# Requête GET : remplit $CODE (statut HTTP), $TYPE (Content-Type),
# $TMP/corps et $TMP/entetes. Options curl supplémentaires en arguments.
requete() {
  local chemin="$1"; shift
  local res
  res="$(curl -s --max-time 10 -o "$TMP/corps" -D "$TMP/entetes" \
         -w '%{http_code} %{content_type}' "$@" "$BASE$chemin")" || res="000 -"
  CODE="${res%% *}"
  TYPE="${res#* }"
}
entete() { grep -i "^$1:" "$TMP/entetes" | head -n 1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//'; }

reussi() { nb_tests=$((nb_tests + 1)); ok "$*"; }
echec()  { erreur "$*"; exit 1; }

# attendu <description> <code attendu> <chemin> [options curl…]
attendu() {
  local desc="$1" code="$2" chemin="$3"; shift 3
  requete "$chemin" "$@"
  [[ "$CODE" == "$code" ]] || echec "$desc : $chemin → $CODE (attendu $code)"
  reussi "$desc : $chemin → $CODE"
}

# contient <texte> : le dernier corps reçu contient le texte
contient() { grep -qF -- "$1" "$TMP/corps"; }

echo "Tests sur $BASE"

# --- Routage --------------------------------------------------------------------

etape "Routage"
attendu "Accueil" 200 /
for i in "${!APP_ID[@]}"; do
  contient "${APP_TITRE[$i]//&/&amp;}" \
    || echec "Accueil : carte « ${APP_TITRE[$i]} » absente"
done
nb_cartes="$(grep -c 'class="carte"' "$TMP/corps" || true)"
[[ "$nb_cartes" == "${#APP_ID[@]}" ]] \
  || echec "Accueil : $nb_cartes carte(s), ${#APP_ID[@]} attendue(s)"
reussi "Accueil : ${#APP_ID[@]} cartes"
[[ "$(entete Cache-Control)" == no-cache ]] || echec "Accueil : Cache-Control no-cache absent"
reussi "Accueil : Cache-Control: no-cache"

for i in "${!APP_ID[@]}"; do
  chemin="${APP_CHEMIN[$i]}"
  attendu "${APP_TITRE[$i]}" 200 "$chemin"
  contient "<title>${APP_TITRE[$i]}</title>" \
    || echec "$chemin ne contient pas <title>${APP_TITRE[$i]}</title>"
  reussi "$chemin contient <title>${APP_TITRE[$i]}</title>"
  attendu "Redirection" 301 "${chemin%/}"
  [[ "$(entete Location)" == "$chemin" ]] \
    || echec "${chemin%/} redirige vers « $(entete Location) » au lieu de $chemin"
  reussi "${chemin%/} → Location: $chemin"
done

# Propre à Turbo Dactylo (seule app à conteneur pour l'instant)
attendu "Turbo Dactylo" 200 /dactylo/style.css
attendu "Turbo Dactylo" 200 /dactylo/game.js
# Sous /dactylo/, un appel absolu (« /api/… ») partirait à la racine du hub
if grep -qE "fetch\([\"'\`]/|://\\\$\{location\.host\}[\"'\`]" "$TMP/corps"; then
  echec "/dactylo/game.js utilise encore des chemins absolus (correctif de Turbo-Dactylo absent ?)"
fi
reussi "/dactylo/game.js : chemins relatifs"
attendu "API" 200 /dactylo/api/classements
if [[ "$TYPE" != application/json* ]] || ! contient '"top":'; then
  echec "/dactylo/api/classements : pas du JSON attendu ($TYPE)"
fi
reussi "/dactylo/api/classements : JSON valide"
attendu "Plus rien à la racine" 404 /api/classements
attendu "URL inexistante" 404 /cette-page-n-existe-pas
contient "Page introuvable" || echec "La page 404 n'est pas la page en français"
reussi "Page 404 en français"

# --- Sécurité -------------------------------------------------------------------

etape "Sécurité"
for chemin in /.git/HEAD /.env /plan/README.md /hasard/README.md \
              /plan/docker-compose.yml /hasard/docker-compose.yml /hasard/deploy.sh \
              /dactylo/.git/HEAD /dactylo/.env /erreurs/50x.html; do
  attendu "Fichier protégé" 404 "$chemin"
done

# Remontée de dossier, en clair et encodée : jamais le contenu d'un fichier
for chemin in /dactylo/../server.js /dactylo/%2e%2e/server.js /dactylo/..%2fserver.js \
              /dactylo/%2e%2e%2fserver.js /dactylo/..%2f..%2fetc/passwd \
              /plan/../../../etc/passwd /plan/%2e%2e/%2e%2e/etc/passwd /%2e%2e/%2e%2e/etc/passwd; do
  requete "$chemin" --path-as-is
  if [[ "$CODE" == 200 ]] || contient 'require(' || contient 'root:'; then
    echec "Remontée de dossier : $chemin → $CODE"
  fi
  reussi "Remontée de dossier refusée : $chemin → $CODE"
done

requete /
[[ -z "$(entete Server | tr -dc 0-9)" ]] || echec "La version de nginx est visible : $(entete Server)"
reussi "Version de nginx masquée"
[[ "$(entete X-Content-Type-Options)" == nosniff ]] || echec "En-tête X-Content-Type-Options absent"
[[ "$(entete Referrer-Policy)" == same-origin ]] || echec "En-tête Referrer-Policy absent"
reussi "En-têtes X-Content-Type-Options et Referrer-Policy"

# Modération : « turbo » (PIN par défaut) refusé ; le vrai PIN accepté.
# Avec le vrai PIN, on vise une entrée inexistante : réponse 404 « Entrée
# introuvable », preuve que le PIN est accepté, sans rien supprimer.
json=(-X POST -H 'Content-Type: application/json')
attendu "Modération, PIN « turbo »" 403 /dactylo/api/moderation "${json[@]}" \
  --data '{"pin":"turbo","id":"smoke-test"}'
if [[ -n "$PIN" ]]; then
  pin_json="$(sed 's/\\/\\\\/g; s/"/\\"/g' <<< "$PIN")"
  attendu "Modération, bon PIN (entrée inexistante)" 404 /dactylo/api/moderation "${json[@]}" \
    --data "{\"pin\":\"$pin_json\",\"id\":\"smoke-test-inexistant\"}"
  contient "introuvable" || echec "Modération : réponse inattendue avec le bon PIN"
else
  alerte "TURBO_PIN inconnu : test du bon PIN sauté"
fi
head -c 20000 /dev/zero | tr '\0' 'x' > "$TMP/gros"
attendu "Envoi trop gros refusé" 413 /dactylo/api/moderation "${json[@]}" --data-binary "@$TMP/gros"

# --- WebSocket -----------------------------------------------------------------

etape "WebSocket (poignée de main)"
# curl ne parle pas WebSocket, mais il envoie la demande et lit la réponse
# « 101 Switching Protocols ». La connexion reste ouverte : --max-time la coupe.
reponse="$(curl -s -i -N --http1.1 --max-time 3 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "$BASE/dactylo/" 2>/dev/null | head -n 1 | tr -d '\r' || true)"
[[ "$reponse" == *" 101 "* ]] || echec "WebSocket sur /dactylo/ : « $reponse » (attendu 101)"
reussi "WebSocket sur /dactylo/ → 101"

echo
ok "${GRAS}$nb_tests tests réussis${NORMAL}"
