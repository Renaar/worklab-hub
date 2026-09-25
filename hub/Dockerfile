# Image du hub : nginx + page d'accueil + fichiers des apps statiques.
# Les fichiers sont copiés (pas de volume) : l'image est figée, et une mise
# à jour des apps = un nouveau build (scripts/deploy.sh s'en charge).
#
# Le dossier build/ est préparé par scripts/deploy.sh à partir de apps.conf :
# il contient la page d'accueil générée et UNIQUEMENT les fichiers à servir
# de chaque app statique (jamais de .git, README, compose…).

# Branche « stable » de nginx (versions paires, uniquement des correctifs),
# plutôt que la branche « mainline » qui reçoit les nouveautés.
FROM nginx:stable-alpine

# On retire la page d'accueil et la configuration d'exemple de nginx
RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/*

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY erreurs/ /usr/share/nginx/erreurs/
COPY build/site/ /usr/share/nginx/html/

# Le build échoue si la configuration est invalide
RUN nginx -t
