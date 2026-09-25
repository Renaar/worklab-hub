// Tests de bout en bout de Turbo Dactylo, à travers le hub (HTTP + WebSocket).
// Des joueurs simulés créent un salon, le rejoignent et font de vraies courses.
//
// Usage (depuis le dossier tests/) :
//   npm install
//   HUB_URL=http://localhost TURBO_PIN=... node dactylo.test.js
//
// Variables :
//   HUB_URL          adresse du hub (défaut http://localhost)
//   TURBO_PIN        PIN de modération : sert à effacer les résultats de test
//                    à la fin. Sans lui, les pseudos « zz-test-… » restent
//                    dans les classements.
//   INACTIF_SECONDES durée du test d'inactivité (défaut 130 ; 0 = sauté)
//
// Les pseudos de test commencent par « zz-test- » et la classe vaut
// « zz-test » : ils sont faciles à repérer et sont effacés à la fin.

'use strict';

const WebSocket = require('ws');

const HUB = (process.env.HUB_URL || 'http://localhost').replace(/\/$/, '');
const BASE = `${HUB}/dactylo/`;
const WS_URL = BASE.replace(/^http/, 'ws');
const PIN = process.env.TURBO_PIN || '';
const INACTIF_S = Number(process.env.INACTIF_SECONDES ?? 130);
const CLASSE = 'zz-test';

const pseudosUtilises = new Set();
let echecs = 0;

const pause = (ms) => new Promise((r) => setTimeout(r, ms));
const ok = (m) => console.log(`   ✔ ${m}`);
const ko = (m) => { console.log(`   ✖ ${m}`); echecs++; };

/** Un joueur simulé : une connexion WebSocket et la file de ses messages. */
class Joueur {
  constructor(nom) {
    this.nom = nom;
    this.messages = [];
    this.attentes = [];
    this.fermePar = null;
    this.erreurs = [];
  }

  connecter() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(WS_URL);
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
      this.ws.on('close', (code) => { this.fermePar = code; });
      this.ws.on('message', (brut) => {
        const msg = JSON.parse(brut);
        if (msg.type === 'error' || msg.type === 'lobby_error') this.erreurs.push(msg.message);
        this.messages.push(msg);
        this.attentes = this.attentes.filter((a) => !a(msg));
      });
    });
  }

  envoyer(msg) { this.ws.send(JSON.stringify(msg)); }

  /** Attend un message du type donné (déjà reçu ou à venir). */
  attendre(type, filtre = () => true, delaiMs = 20000) {
    const deja = this.messages.find((m) => m.type === type && filtre(m));
    if (deja) {
      this.messages.splice(this.messages.indexOf(deja), 1);
      return Promise.resolve(deja);
    }
    return new Promise((resolve, reject) => {
      const minuteur = setTimeout(
        () => reject(new Error(`${this.nom} : pas de message « ${type} » après ${delaiMs / 1000} s`)),
        delaiMs);
      this.attentes.push((m) => {
        if (m.type !== type || !filtre(m)) return false;
        clearTimeout(minuteur);
        this.messages.splice(this.messages.indexOf(m), 1);
        resolve(m);
        return true;
      });
    });
  }

  fermer() { if (this.ws) this.ws.close(); }
}

/**
 * Une course complète : un hôte (qui ne court pas) et nbJoueurs coureurs.
 * equipes = 0 (chacun pour soi) ou 2 à 4.
 */
async function course(titre, nbJoueurs, equipes = 0) {
  console.log(`\n== ${titre}`);
  const hote = new Joueur('zz-test-hote');
  const joueurs = Array.from({ length: nbJoueurs }, (_, i) => new Joueur(`zz-test-${i + 1}`));
  const tous = [hote, ...joueurs];
  tous.forEach((j) => pseudosUtilises.add(j.nom));
  try {
    await hote.connecter();
    hote.envoyer({ type: 'create', name: hote.nom, classe: CLASSE, wordCount: 10 });
    const { code } = await hote.attendre('welcome');
    ok(`salon ${code} créé par l'hôte`);

    await Promise.all(joueurs.map(async (j) => {
      await j.connecter();
      j.envoyer({ type: 'join', name: j.nom, code });
      await j.attendre('welcome');
    }));
    await hote.attendre('lobby', (m) => m.players.length === tous.length);
    ok(`${nbJoueurs} joueurs ont rejoint le salon`);

    hote.envoyer({ type: 'options', mode: 'mots', wordCount: 10, teams: equipes });
    await hote.attendre('lobby', (m) => m.options.teams === equipes && m.options.wordCount === 10);
    hote.envoyer({ type: 'start' });

    // Chaque joueur reçoit la liste de mots, attend le départ, puis tape
    // les mots un par un (avec un petit délai, comme un vrai élève pressé).
    await Promise.all(joueurs.map(async (j) => {
      const setup = await j.attendre('race_setup');
      await j.attendre('go');
      for (const mot of setup.words) {
        j.envoyer({ type: 'typed', value: mot, mistakes: 0 });
        await pause(30);
      }
    }));
    ok('course lancée, tous les mots envoyés');

    const resultats = await Promise.all(tous.map((j) => j.attendre('results')));
    const { results, teams } = resultats[0];
    const arrives = results.filter((r) => r.finished).length;
    if (results.length === nbJoueurs && arrives === nbJoueurs) {
      ok(`classement final reçu par tous : ${arrives}/${nbJoueurs} arrivés`);
    } else {
      ko(`classement final incomplet : ${arrives}/${nbJoueurs} arrivés`);
    }
    if (equipes) {
      if (teams && teams.length === equipes && teams.every((t) => t.rank !== null)) {
        ok(`classement des ${equipes} équipes : ${teams.map((t) => `${t.rank}. ${t.name}`).join(', ')}`);
      } else {
        ko(`classement des équipes inattendu : ${JSON.stringify(teams)}`);
      }
    }

    const erreurs = tous.flatMap((j) => j.erreurs);
    const coupes = tous.filter((j) => j.fermePar !== null);
    if (erreurs.length || coupes.length) {
      ko(`${erreurs.length} erreur(s), ${coupes.length} déconnexion(s) : ${erreurs.join(' ; ')}`);
    } else {
      ok(`${tous.length} connexions, aucune erreur ni déconnexion`);
    }
  } catch (e) {
    ko(e.message);
  } finally {
    tous.forEach((j) => j.fermer());
  }
}

/** Connexion ouverte sans rien faire pendant INACTIF_S secondes. */
async function inactivite() {
  const j = new Joueur('zz-test-inactif');
  pseudosUtilises.add(j.nom);
  await j.connecter();
  j.envoyer({ type: 'create', name: j.nom, classe: CLASSE });
  await j.attendre('welcome');
  await pause(INACTIF_S * 1000);
  // La connexion doit être restée ouverte et répondre encore
  const ouverte = j.ws.readyState === WebSocket.OPEN && j.fermePar === null;
  if (ouverte) {
    j.envoyer({ type: 'options', wordCount: 15 });
    try {
      await j.attendre('lobby', (m) => m.options.wordCount === 15, 5000);
    } catch { j.fermePar = 'pas de réponse'; }
  }
  j.fermer();
  return j.fermePar === null
    ? `connexion inactive ${INACTIF_S} s : toujours ouverte et réactive`
    : `connexion inactive ${INACTIF_S} s : coupée (${j.fermePar})`;
}

async function classementContient(pseudos) {
  const r = await fetch(`${BASE}api/classements?classe=${CLASSE}`);
  const data = await r.json();
  const noms = new Set([...data.top, ...data.assidus].map((e) => e.pseudo));
  return pseudos.every((p) => noms.has(p));
}

async function nettoyer() {
  if (!PIN) {
    console.log('\n   ⚠ TURBO_PIN non fourni : les résultats « zz-test-… » restent dans les classements.');
    return;
  }
  let n = 0;
  for (const pseudo of pseudosUtilises) {
    const r = await fetch(`${BASE}api/moderation`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pin: PIN, pseudo })
    });
    if (r.status === 403) { ko('nettoyage : PIN refusé'); return; }
    if (r.ok) n += (await r.json()).supprimees;
  }
  console.log(`\n   🧹 ${n} résultat(s) de test effacé(s) des classements`);
}

(async () => {
  console.log(`Tests Turbo Dactylo via ${BASE}`);
  // Le test d'inactivité tourne en parallèle des courses
  const inactif = INACTIF_S > 0 ? inactivite() : null;

  await course('Partie complète (3 joueurs)', 3);

  console.log('\n== Classements');
  if (await classementContient(['zz-test-1', 'zz-test-2', 'zz-test-3'])) {
    ok('la course terminée apparaît dans /dactylo/api/classements');
  } else {
    ko('la course terminée n\'apparaît pas dans /dactylo/api/classements');
  }

  await course('Course par équipes (2 équipes, 4 joueurs)', 4, 2);
  await course('Charge : 35 clients dans un même salon (hôte + 34 joueurs)', 34);

  if (inactif) {
    console.log(`\n== Inactivité (${INACTIF_S} s, lancé au début)`);
    const texte = await inactif;
    (texte.includes('toujours ouverte') ? ok : ko)(texte);
  }

  await nettoyer();
  console.log(echecs ? `\n✖ ${echecs} échec(s)` : '\n✔ Tous les tests Turbo Dactylo sont passés');
  process.exit(echecs ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
