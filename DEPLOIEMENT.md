# Déploiement du worklab : procédure pas à pas

À suivre sur le serveur (`172.16.0.17`, connecté par le VPN). Toutes les
commandes sont lancées avec `sudo`. Compter environ 30 minutes.

**Avant de commencer** : la pull request de Turbo-Dactylo (chemins relatifs)
doit être fusionnée dans `main`. Sinon, le jeu s'affiche sous `/dactylo/` mais
les salons ne marchent pas (`smoke-test.sh` le signale).

---

## 1. Test préalable depuis un PC élève

Depuis un **PC élève** (pas le tien : le filtrage peut être différent), ouvrir
`http://172.16.0.17/`. L'ancien hub y répond déjà.

- **Le hub s'affiche** → garder le port 80. Rien à faire.
- **Une page du filtrage de l'école s'affiche à la place** → noter qu'il faudra
  mettre `HUB_PORT=8080` dans `.env` à l'étape 3. L'adresse deviendra
  `http://172.16.0.17:8080/`.

---

## 2. Nettoyage des anciennes stacks

L'objectif est de partir d'un serveur propre : plus d'anciens conteneurs
d'apps, plus d'ancien hub, plus de ports ouverts inutiles.

### 2.1 Faire l'inventaire

```bash
sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
ls -l /opt/stacks/
```

Noter ici ce que tu trouves. **Ne supprime que ce que tu reconnais** :

| Dossier dans /opt/stacks | Conteneurs | À supprimer ? |
|---|---|---|
| … | … | … |

Garder **Dockge** et tout ce qui n'est pas une ancienne app ni l'ancien hub.

### 2.2 Arrêter et supprimer les anciennes stacks

Pour chaque ancienne stack (app ou ancien hub), au choix :

- **Dans Dockge** (`http://172.16.0.17:5001`) : ouvrir la stack → *Arrêter*,
  puis *Supprimer* ;
- **ou en ligne de commande** :
  ```bash
  cd /opt/stacks/<nom-vérifié>
  sudo docker compose down
  ```

Si un ancien conteneur n'appartient à aucune stack (lancé avec `docker run`) :

```bash
sudo docker rm -f <nom-vérifié>
```

Vérifier qu'il ne reste que ce qui doit rester :

```bash
sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Il ne doit plus rien y avoir sur le port 80 (sinon le nouveau hub ne pourra
pas démarrer).

### 2.3 Mettre de côté l'ancien dossier du hub

S'il existe déjà un dossier `/opt/stacks/worklab-hub` (ancien hub, déjà
arrêté à l'étape 2.2) :

```bash
sudo mv /opt/stacks/worklab-hub /opt/stacks/worklab-hub.ancien
```

Une fois le nouveau hub validé, les dossiers des anciennes stacks peuvent
être supprimés (`sudo rm -r /opt/stacks/<nom-vérifié>`).

### 2.4 Retirer les anciennes règles du pare-feu

```bash
sudo ufw status numbered
```

Supprimer les règles des **anciens ports d'apps**. D'après les anciens
fichiers des dépôts : Plan de Classe utilisait 3003, Heureux Hasard 3004 et
Turbo Dactylo 3000. Vérifie dans la liste, d'autres ports ont pu être ouverts
à la main.
Supprimer une règle à la fois, en partant du plus grand numéro, car les numéros
se décalent après chaque suppression :

```bash
sudo ufw delete <numéro>
```

**À garder** : SSH (22), Dockge (5001), et le port du hub (80, ou 8080).
S'il n'y a pas encore de règle pour le hub :

```bash
sudo ufw allow 80/tcp      # ou 8080/tcp
```

(Pour rappel, Docker ouvre de toute façon les ports publiés sans passer par
ufw. La règle sert surtout de trace.)

---

## 3. Installation

```bash
sudo git clone https://github.com/Renaar/worklab-hub.git /opt/stacks/worklab-hub
cd /opt/stacks/worklab-hub
sudo cp .env.example .env
sudo nano .env
```

Dans `.env` :

- `TURBO_PIN=` : choisir un vrai PIN de modération (pas `turbo`, pas
  `à-changer`) ;
- `HUB_PORT=8080` seulement si le test de l'étape 1 l'a demandé.

Enregistrer (`Ctrl+O`, `Entrée`), quitter (`Ctrl+X`), puis protéger le fichier
et lancer le déploiement :

```bash
sudo chmod 600 .env
sudo scripts/deploy.sh
```

Le premier déploiement prend quelques minutes (téléchargement des images).
Il se termine par un résumé :

- `✔ Déploiement réussi. Hub : http://172.16.0.17/` → tout va bien ;
- `✖ …` → le message indique ce qui ne va pas. Voir les logs avec
  `sudo docker compose logs --tail 50`.

La stack `worklab-hub` apparaît dans Dockge : on peut y suivre l'état et les
logs. Pour les mises à jour, utiliser `scripts/deploy.sh` plutôt que les
boutons de Dockge : le script prépare les fichiers avant de reconstruire.

---

## 4. Tests sur place

1. **Depuis un PC élève** : `http://172.16.0.17/` affiche le hub avec les
   3 cartes.
2. **Turbo Dactylo avec 3 ou 4 vrais postes élèves**, via le hub :
   - créer un salon depuis ton poste (avec une classe, ex. `TEST`), faire
     rejoindre les élèves, faire une course ;
   - refaire une course **par équipes** (option « Équipes : 2 ») ;
   - ouvrir « Classements » : les courses y figurent ;
   - facultatif : effacer ces résultats de test par « Modération » (avec ton PIN).
3. **Au beamer** : ouvrir Plan de Classe et Heureux Hasard via le hub et
   vérifier qu'ils s'affichent bien. Les listes créées sur les anciennes
   adresses ne sont pas reprises (nouvelle adresse = nouveau stockage du
   navigateur).
4. **Sauvegarde** : la lancer une fois à la main (il faut au moins une course
   enregistrée, sinon le script signale qu'il n'y a rien à sauvegarder) :
   ```bash
   sudo /opt/stacks/worklab-hub/scripts/sauvegarde-dactylo.sh
   ls -l /opt/backups/worklab/
   ```

Tests supplémentaires, si tu veux (voir le README, section « Tester ») :
`sudo scripts/smoke-test.sh` et les courses simulées de `tests/`.

---

## 5. Sauvegarde automatique (cron)

```bash
sudo crontab -e
```

Ajouter cette ligne (une sauvegarde par jour à 18 h) :

```cron
0 18 * * * /opt/stacks/worklab-hub/scripts/sauvegarde-dactylo.sh >> /var/log/worklab-sauvegarde.log 2>&1
```

Le lendemain, vérifier : `tail /var/log/worklab-sauvegarde.log` et
`ls /opt/backups/worklab/`.

Tant qu'aucune course n'est enregistrée, la sauvegarde signale une erreur
« rien à sauvegarder » : c'est normal.

---

## 6. Plus tard

### Mettre à jour

```bash
cd /opt/stacks/worklab-hub
sudo scripts/deploy.sh
```

Une seule commande pour tout : `worklab-hub`, les apps, les images et les
tests. Les classements de Turbo Dactylo sont conservés (volume Docker).

### Revenir en arrière

Si une mise à jour de `worklab-hub` pose problème :

```bash
cd /opt/stacks/worklab-hub
sudo git log --oneline -10          # repérer le dernier commit qui marchait
sudo git checkout <commit>
sudo scripts/deploy.sh              # déploie cette version, sans git pull
```

Pour revenir ensuite à la version courante :

```bash
sudo git checkout main
sudo scripts/deploy.sh
```

Si c'est **une app** qui pose problème (nouvelle version de Turbo Dactylo,
par exemple) : dans `apps.conf` (sur GitHub), remplacer `main` par le
commit complet de la version qui marchait, puis `sudo scripts/deploy.sh`.

### En cas de souci

| Symptôme | À regarder |
|---|---|
| Le hub ne répond pas | `sudo docker compose ps`, puis `sudo docker compose logs --tail 50 hub` |
| `/dactylo/` affiche « momentanément indisponible » | `sudo docker compose logs --tail 50 turbo-dactylo`, puis `sudo docker compose restart turbo-dactylo` |
| `deploy.sh` refuse de démarrer | lire le message : il indique quoi corriger (`.env`, PIN, Docker…) |
