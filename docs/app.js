// DoubleLeren-website: inloggen met je uitnodigingscode en je code van zes woorden, gegevens ontsleutelen en controleren
// in de browser, voortgang en team tonen. Je code en sleutels verlaten de browser nooit.
import * as K from './krypto.js';
import { WOORDEN } from './woorden.js';

// Nooit in een frame draaien (een andere pagina zou anders mee kunnen kijken)
if (window.top !== window.self) { document.documentElement.innerHTML = ''; throw new Error('DoubleLeren mag niet in een frame draaien'); }

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const MAAND = ['jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
const fmtDatum = (iso) => { const d = new Date(String(iso).slice(0, 10) + 'T12:00:00'); return isNaN(d) ? '' : `${d.getDate()} ${MAAND[d.getMonth()]} ${d.getFullYear()}`; };
const fmtMaand = (m) => `${MAAND[+m.slice(5, 7) - 1]} ${m.slice(0, 4)}`;
const dagKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const pct = (a, b) => (b ? Math.round((a / b) * 100) : 0);
const komma = (x) => Number(x).toFixed(1).replace('.', ',');
const RES = { goed: 'Goed', deels: 'Deels', fout: 'Fout' };
const chip = (r) => (RES[r] ? `<span class="chip ${r}"><i></i>${RES[r]}</span>` : '');
const SIG = { bevestigd: 'Bevestigd', overschat: 'Mogelijk overschat', onderschat: 'Mogelijk onderschat', groeit: 'Groeit' };
const sigChip = (s) => (SIG[s] ? `<span class="chip ${s}">${SIG[s]}</span>` : '');
const veiligeLink = (u) => { try { const x = new URL(String(u)); return x.protocol === 'https:' && String(u).length <= 500 ? x.href : null; } catch { return null; } };
const UITNODIGING = /^(lid-[0-9a-f]{6}):([A-Za-z0-9_]{20,255})$/;

// ---------------------------------------------------------------- bronnen
// Productie: app-repo openbaar (raw), data-repo privé (GitHub-API met je token). Beheerbestanden staan in de data-repo
// onder beheer/ en zijn ondertekend met de beheersleutel uit vertrouwd.json in de app-repo; collega's met een token
// kunnen ze dus wel overschrijven, maar niet vervalsen.
// Lokaal testen alleen op localhost: ?app=/pad&data=/pad (relatieve paden, met .lijst.json).
const params = new URLSearchParams(location.search);
const LOKAAL = ['localhost', '127.0.0.1'].includes(location.hostname) && ['app', 'data'].every((k) => /^\/[\w\-/.]+$/.test(params.get(k) || ''));
// Alleen lokaal testen: ?vandaag=JJJJ-MM-DD doet alsof het die dag is (deadlines, reeks, scorebord)
const NU = LOKAAL && /^\d{4}-\d{2}-\d{2}$/.test(params.get('vandaag') || '') ? params.get('vandaag').split('-').map(Number) : null;
const TIJD = LOKAAL && /^\d{2}:\d{2}$/.test(params.get('tijd') || '') ? params.get('tijd').split(':').map(Number) : null;   // ?tijd=HH:MM
const nu = () => { const d = new Date(); if (NU) d.setFullYear(NU[0], NU[1] - 1, NU[2]); if (TIJD) d.setHours(TIJD[0], TIJD[1]); return d; };

// Lokaal schrijven gaat naar test/lokale-server.py (alleen localhost, alleen de testmap).
function lokaleBron(basis) {
  let paden = null;
  return {
    async init() { try { const r = await fetch(`${basis}/.lijst.json`, { cache: 'no-store' }); if (r.ok) paden = await r.json(); } catch { /* geen lijst */ } },
    get paden() { return paden; },
    async bytes(p) { const r = await fetch(`${basis}/${p}`, { cache: 'no-store' }); if (r.status === 404) return null; if (!r.ok) throw new Error(`${p}: ${r.status}`); return new Uint8Array(await r.arrayBuffer()); },
    async ververs(p) { return this.bytes(p); },
    async schrijf(p, b) { const r = await fetch(`${basis}/${p}`, { method: 'PUT', body: b }); if (!r.ok) throw new Error(`${p}: ${r.status}`); if (paden && !paden.includes(p)) paden.push(p); },
    async verwijder(p) { await fetch(`${basis}/${p}`, { method: 'DELETE' }); if (paden) paden = paden.filter((x) => x !== p); }
  };
}
const b64 = (bytes) => { const s = K.b64u.enc(bytes).replace(/-/g, '+').replace(/_/g, '/'); return s + '==='.slice((s.length + 3) % 4); };
function apiBron(eigenaar, repo, token) {
  let paden = null; const shas = new Map();
  const kop = { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github.raw+json', 'X-GitHub-Api-Version': '2022-11-28' };
  const url = (p) => `https://api.github.com/repos/${eigenaar}/${repo}/contents/${p.split('/').map(encodeURIComponent).join('/')}`;
  // Elke leesactie een eigen adres: een bedrijfsproxy (bijv. Cisco Umbrella) negeert 'Vary: Accept' en gaf anders het ruwe
  // bestand terug waar JSON werd verwacht, of een verouderde versie (oude sha → steeds 'conflict')
  const vers = (p, ref = '') => `${url(p)}?${ref}t=${Date.now()}${Math.random().toString(36).slice(2, 8)}`;
  // Neutrale commit onder één algemene naam: geen namen, pseudoniemen of lestitels in de geschiedenis
  const wie = { name: 'doubleleren', email: 'sync@doubleleren.invalid' };
  const verstuur = async (methode, p, body) => {
    const r = await fetch(url(p), { method: methode, headers: { ...kop, Accept: 'application/vnd.github+json', 'Content-Type': 'application/json' }, body: JSON.stringify({ message: 'sync', branch: 'main', committer: wie, author: wie, ...body }) });
    if (r.status === 409 || r.status === 422) throw new Error('conflict');
    if (r.status === 401 || r.status === 403) throw new Error('Je uitnodigingscode mag niet (meer) schrijven. Vraag de beheerder om een nieuwe.');
    if (!r.ok) throw new Error(`Opslaan mislukt (${r.status})`);
    return r.status === 204 ? null : r.json();
  };
  return {
    async init() {
      const r = await fetch(`https://api.github.com/repos/${eigenaar}/${repo}/git/trees/main?recursive=1`, { headers: { ...kop, Accept: 'application/vnd.github+json' }, cache: 'no-store' });
      if (r.status === 401 || r.status === 403 || r.status === 404) throw new Error('UITNODIGING');
      if (r.ok) { const blobs = (await r.json()).tree.filter((t) => t.type === 'blob'); paden = blobs.map((t) => t.path); blobs.forEach((t) => shas.set(t.path, t.sha)); }
    },
    get paden() { return paden; },
    async bytes(p) {
      const r = await fetch(vers(p), { headers: kop, cache: 'no-store' });
      if (r.status === 404) return null; if (!r.ok) throw new Error(`${p}: ${r.status}`); return new Uint8Array(await r.arrayBuffer());
    },
    // Nieuwste versie en sha ophalen (na een conflict: een andere laptop schreef net)
    async ververs(p) {
      const r = await fetch(vers(p, 'ref=main&'), { headers: { ...kop, Accept: 'application/vnd.github+json' }, cache: 'no-store' });
      if (r.status === 404) { shas.delete(p); return null; }
      if (!r.ok) throw new Error(`${p}: ${r.status}`);
      const j = await r.json(); shas.set(p, j.sha);
      return K.b64u.dec(String(j.content).replace(/\s/g, '').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''));
    },
    async schrijf(p, b) {
      const sha = shas.get(p);
      const res = await verstuur('PUT', p, { content: b64(b), ...(sha ? { sha } : {}) });
      shas.set(p, res.content.sha); if (paden && !paden.includes(p)) paden.push(p);
    },
    async verwijder(p) {
      const sha = shas.get(p); if (!sha) return;
      await verstuur('DELETE', p, { sha }); shas.delete(p); if (paden) paden = paden.filter((x) => x !== p);
    }
  };
}
function rawBron(eigenaar, repo) {
  return { paden: null, async init() {}, async bytes(p) { const r = await fetch(`https://raw.githubusercontent.com/${eigenaar}/${repo}/main/${p}`, { cache: 'no-cache' }); if (r.status === 404) return null; if (!r.ok) throw new Error(`${p}: ${r.status}`); return new Uint8Array(await r.arrayBuffer()); } };
}
const json = async (bron, p) => { const b = await bron.bytes(p); return b ? JSON.parse(K.tekst.uitBytes(b)) : null; };
// Beheerbestand lezen en de handtekening van de beheersleutel controleren; vervalst = fout, ontbreekt = null
async function beheerJson(p) {
  const env = await json(S.data, `beheer/${p}`);
  if (!env) return null;
  if (env.v !== 2 || env.door !== 'beheer' || typeof env.inhoud !== 'string' || !(await K.verifieer(S.vertrouwd, `beheer|${p}`, 'beheer', env.inhoud, env.sig)))
    throw new Error(`Beheerbestand ${p} heeft geen geldige handtekening van de beheerder. Neem contact op met de beheerder.`);
  return JSON.parse(env.inhoud);
}

// ---------------------------------------------------------------- state
const S = { bron: null, mij: null, prive: null, ak: null, org: null, lessen: {}, sjabloon: new Map(), vakken: [], alleVakken: [], leden: {}, sleutels: new Map(), ongeldig: 0 };

async function laadOpenbaar() {
  if (LOKAAL) { S.app = lokaleBron(params.get('app')); await S.app.init(); }
  else {
    S.eigenaar = location.hostname.split('.')[0]; S.appRepo = location.pathname.split('/').filter(Boolean)[0];
    S.app = rawBron(S.eigenaar, S.appRepo);
  }
  S.inst = await json(S.app, 'instellingen.json');
  S.vertrouwd = (await json(S.app, 'vertrouwd.json'))?.beheer;
  if (!K.sleutelVorm(S.vertrouwd)) throw new Error('de beheerder heeft DoubleLeren nog niet ingericht');
  const idx = await json(S.app, 'lessen/index.json');
  for (const l of idx?.lessen || []) if (/^[0-9a-z][0-9a-z-]{0,80}$/.test(l.id)) S.lessen[l.id] = l;
  // Alle vakken uit instellingen.json (S.alleVakken); alleen die met een skilllijst doen mee (S.vakken).
  // Het standaardvak houdt kale id's (1.1.1), de rest 'cro:1.1.1'
  const lijst = (Array.isArray(S.inst.vakken) && S.inst.vakken.length ? S.inst.vakken : [{ id: S.inst.vakgebied }]).filter((v) => VAK_VORM.test(String(v?.id)));
  // soort: discipline (standaard; eigen vak en leren), groep (alleen eigen vak in het organogram, bijv. Base), onderwerp (alleen leren)
  const soortVan = (v) => (['groep', 'onderwerp'].includes(v.soort) ? v.soort : 'discipline');
  const csvs = await Promise.all(lijst.map((v) => (soortVan(v) === 'groep' ? null : S.app.bytes(`sjablonen/${v.id}/skilllijst.csv`).catch(() => null))));
  lijst.forEach((v, n) => {
    S.alleVakken.push({ id: v.id, naam: String(v.naam || String(v.id).toUpperCase()), lijst: !!csvs[n], soort: soortVan(v) });
    if (!csvs[n]) return;
    const [kop, ...regels] = K.tekst.uitBytes(csvs[n]).replace(/^﻿/, '').trim().split(/\r?\n/).map((r) => r.split(';'));
    for (const r of regels) {
      const o = Object.fromEntries(kop.map((k, i) => [k, r[i] || '']));
      if (!/^\d+\.\d+\.\d+$/.test(o.id)) continue;
      const id = v.id === S.inst.vakgebied ? o.id : `${v.id}:${o.id}`;
      S.sjabloon.set(id, { ...o, id, nr: o.id, vak: v.id });
    }
    S.vakken.push({ id: v.id, naam: String(v.naam || String(v.id).toUpperCase()) });
  });
  $('vak').textContent = vakNaam(S.inst.vakgebied);
}

// ---------------------------------------------------------------- vakken
// Iedereen hoort bij één vak (organogram, standaard instellingen.vakgebied) en kiest zelf welke vakken hij leert,
// met prioriteit 1 hoog, 2 normaal, 3 laag (matrix.vakken). Niets gekozen = alleen het eigen vak.
const VAK_VORM = /^[a-z][a-z-]{0,30}$/;
const vakNaam = (v) => S.alleVakken.find((x) => x.id === v)?.naam || String(v || '').toUpperCase();
const meerVakken = () => S.vakken.length > 1;
const hgSleutel = (id) => String(id).replace(/\.\d+\.\d+$/, '');      // hoofdgebied: '1' of 'cro:1'
const eigenVak = (id) => { const v = S.org?.leden?.[id]?.vak; return typeof v === 'string' && VAK_VORM.test(v) ? v : S.inst.vakgebied; };
const headVanVak = (v) => S.org?.heads?.[v] || (v === S.inst.vakgebied ? S.org?.head : null) || null;
const headVakken = (id) => S.vakken.map((x) => x.id).filter((v) => headVanVak(v) === id);
const schoonVakken = (p) => Object.fromEntries(Object.entries(p && typeof p === 'object' ? p : {}).filter(([k, v]) => S.vakken.some((x) => x.id === k) && [1, 2, 3].includes(v)));
function gekozenVakken(lid) { const k = schoonVakken(lid?.vakken); if (Object.keys(k).length) return k; const e = eigenVak(lid?.id); return S.vakken.some((x) => x.id === e) ? { [e]: 1 } : {}; }
const vakkenVan = (lid) => Object.entries(gekozenVakken(lid)).sort((a, b) => a[1] - b[1]).map(([v]) => v);
const itemsVan = (lid, vak) => { const vk = vak ? [vak] : vakkenVan(lid); return [...S.sjabloon.values()].filter((it) => vk.includes(it.vak)); };
const hgNaam = (it) => (meerVakken() ? `${vakNaam(it.vak)} · ${it.hoofdgebied}` : it.hoofdgebied);
const ingevuld = (lid, vak) => itemsVan(lid, vak).some((it) => lid?.matrix?.has(it.id));

async function verbind(uitnodiging) {
  const m = UITNODIGING.exec(uitnodiging.trim());
  if (!m) throw new Error('De uitnodigingscode klopt niet. Je vindt hem in het Teams-bericht van de beheerder.');
  S.data = LOKAAL ? lokaleBron(params.get('data')) : apiBron(S.eigenaar, S.inst.dataRepo, m[2]);
  try { await S.data.init(); }
  catch (e) { if (e.message === 'UITNODIGING') throw new Error('Deze uitnodigingscode heeft geen toegang (meer). Vraag de beheerder om een nieuwe.'); throw e; }
  return m[1];
}

async function inloggen(id, code) {
  code = K.normaliseerCode(code);
  if (code.split('-').length !== 6) throw new Error('Een code bestaat uit zes woorden.');
  const s = await beheerJson(`sleutels/${id}.json`);
  if (!s) throw new Error('Je account wacht nog op goedkeuring door de beheerder.');
  if (!K.sleutelVorm(s.publiek)) throw new Error('Je sleutel heeft een ongeldige vorm. Neem contact op met de beheerder.');
  let jwk;
  try { jwk = await K.openKluis(id, s.kluis, code); } catch { throw new Error('Deze code klopt niet. Controleer de spelling; elk woord telt.'); }
  if (jwk.n !== s.publiek.n) throw new Error('De sleutel past niet bij je account.');
  await gebruikSleutel(id, jwk);
  return jwk;
}
async function gebruikSleutel(id, jwk) {
  S.mij = id; S.ak = await K.akUitJwk(jwk); S.prive = await K.priveSleutel(jwk); S.teken = await K.tekenSleutel(jwk);
}

// ---------------------------------------------------------------- onthoud mij (alleen als je dat aanvinkt)
// Je sleutel en uitnodigingscode worden versleuteld met een apparaatsleutel die de browser zelf maakt en die niet
// uitleesbaar is (WebCrypto, niet-exporteerbaar), en samen in IndexedDB van deze site bewaard. Je code van zes woorden
// wordt nooit bewaard. Na 30 dagen, bij Uitloggen of als je sleutel is vervangen (code kwijt) vraagt de site hem weer.
const SESSIE_DAGEN = 30;
function idb(mode, fn) {
  return new Promise((ok, nee) => {
    const open = indexedDB.open('doubleleren', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('kv');
    open.onerror = () => nee(open.error);
    open.onsuccess = () => {
      const db = open.result, tx = db.transaction('kv', mode), req = fn(tx.objectStore('kv'));
      tx.oncomplete = () => { db.close(); ok(req.result); };
      tx.onerror = () => { db.close(); nee(tx.error); };
    };
  });
}
const vergeetSessie = () => idb('readwrite', (s) => s.delete('sessie')).catch(() => {});
async function bewaarSessie(id, jwk, uitnodiging) {
  try {
    const apparaat = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
    const iv = K.willekeurig(12);
    const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: K.tekst.naarBytes('doubleleren-sessie|' + id) }, apparaat, K.tekst.naarBytes(JSON.stringify({ id, jwk, uitnodiging }))));
    await idb('readwrite', (s) => s.put({ v: 1, id, apparaat, iv, ct, tot: Date.now() + SESSIE_DAGEN * 864e5 }, 'sessie'));
  } catch { /* geen opslag beschikbaar (bijv. privévenster): gewoon zonder onthouden */ }
}
// Geeft true als er automatisch is ingelogd
async function probeerSessie() {
  let s = null; try { s = await idb('readonly', (st) => st.get('sessie')); } catch { return false; }
  if (!s) return false;
  if (!(s.tot > Date.now()) || s.v !== 1) { await vergeetSessie(); return false; }
  let inhoud;
  try { inhoud = JSON.parse(K.tekst.uitBytes(new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: s.iv, additionalData: K.tekst.naarBytes('doubleleren-sessie|' + s.id) }, s.apparaat, s.ct)))); }
  catch { await vergeetSessie(); return false; }
  $('login').hidden = true; $('voet').textContent = 'Automatisch inloggen…';
  try {
    if (await verbind(inhoud.uitnodiging) !== inhoud.id) throw new Error('sleutel');
    const sl = await beheerJson(`sleutels/${inhoud.id}.json`);
    if (!sl || sl.publiek?.n !== inhoud.jwk.n) throw new Error('sleutel');   // vervangen na 'code kwijt'
    await gebruikSleutel(inhoud.id, inhoud.jwk);
    await naInloggen();
    return true;
  } catch (e) {
    if (e.message === 'sleutel' || /uitnodigingscode/.test(e.message)) await vergeetSessie();
    $('login').hidden = false; $('voet').textContent = '';
    $('login-fout').textContent = e.message === 'sleutel' ? 'Log opnieuw in met je code.' : 'Automatisch inloggen lukte niet: ' + e.message;
    return false;
  }
}

// Publieke sleutels (huidig + eerdere) voor het controleren van handtekeningen
// Generatorsleutel uit beheer/generator.json (ondertekend door de beheerder); null = nog geen aparte generatorsleutel
async function generatorSleutel() {
  if (S.generator === undefined) { const g = await beheerJson('generator.json').catch(() => null); S.generator = K.sleutelVorm(g?.publiek) ? g.publiek : null; }
  return S.generator;
}
async function sleutelsVan(id) {
  if (id === 'generator') return [await generatorSleutel(), S.vertrouwd].filter(Boolean);   // beheersleutel: van vóór de aparte generatorsleutel
  if (!S.sleutels.has(id)) { const s = await beheerJson(`sleutels/${id}.json`).catch(() => null); S.sleutels.set(id, s ? [s.publiek, ...(Array.isArray(s.eerdere) ? s.eerdere : [])].filter(Boolean) : []); }
  return S.sleutels.get(id);
}
// Ontsleutelen + handtekening controleren; ongeldig = fout
async function openEnc(id, soort, sl, b) {
  const env = JSON.parse(K.tekst.uitBytes(await K.ontsleutel(sl, `${id}|${soort}`, b)));
  const verwacht = soort === 'wachtrij' ? 'generator' : id;
  if (env.v !== 2 || env.door !== verwacht || typeof env.inhoud !== 'string') throw new Error(`${soort}: onbekend formaat`);
  for (const pub of await sleutelsVan(env.door)) if (await K.verifieer(pub, `${id}|${soort}`, env.door, env.inhoud, env.sig)) return JSON.parse(env.inhoud);
  throw new Error(`${soort}: ongeldige handtekening`);
}
// Bij het tonen: ongeldig overslaan en tellen
async function leesEnc(id, soort, sl) {
  const b = await S.data.bytes(`data/${id}/${soort}.enc`);
  if (!b) return null;
  try { return await openEnc(id, soort, sl, b); } catch { S.ongeldig++; return null; }
}

// Opschonen: alleen verwachte vormen en waarden komen in de weergave
const geldigeScore = (v) => { const n = Number(v); return Number.isInteger(n) && n >= 1 && n <= 5 ? n : null; };
function schoonMatrix(m) {
  const uit = new Map();
  for (const [id, sc] of Object.entries(m?.scores || {})) {
    if (!S.sjabloon.has(id) || typeof sc !== 'object' || !sc) continue;
    const s = {}; for (const [mnd, v] of Object.entries(sc)) { const n = geldigeScore(v); if (/^\d{4}-(0[1-9]|1[0-2])$/.test(mnd) && n) s[mnd] = n; }
    uit.set(id, s);
  }
  return uit;
}
// Eigen prioriteit per hoofdgebied (sleutel = vaardigheid-id zonder de laatste twee cijfers: '1' of 'cro:1'): 1 hoog, 2 normaal, 3 laag
const schoonPrioriteit = (p) => Object.fromEntries(Object.entries(p && typeof p === 'object' ? p : {}).filter(([k, v]) => /^(?:[a-z][a-z-]{0,30}:)?\d{1,2}$/.test(k) && [1, 2, 3].includes(v)));
function hoofdgebieden(lid) { const m = new Map(); for (const it of lid ? itemsVan(lid) : S.sjabloon.values()) { const n = hgSleutel(it.id); if (!m.has(n)) m.set(n, hgNaam(it)); } return m; }
function schoonLog(r) {
  if (!r || typeof r !== 'object' || !/^\d{4}-\d{2}-\d{2}T/.test(String(r.datum))) return null;
  return { datum: String(r.datum), id: String(r.id || ''), resultaat: RES[r.resultaat] ? r.resultaat : null, niveau: ['basis', 'gevorderd', 'expert'].includes(r.niveau) ? r.niveau : 'basis',
    matrix: Array.isArray(r.matrix) ? r.matrix.map(String).filter((x) => S.sjabloon.has(x)) : [], titel: String(r.titel || ''), vakgebied: String(r.vakgebied || '') };
}
const logMaanden = (id) => {
  const p = S.data.paden;
  if (p) return p.filter((x) => x.startsWith(`data/${id}/log-`)).map((x) => x.slice(-11, -4)).filter((m) => /^\d{4}-\d{2}$/.test(m));
  const m = []; const d = nu(); for (let i = 0; i < 12; i++) { m.push(dagKey(d).slice(0, 7)); d.setMonth(d.getMonth() - 1); } return m;
};
async function laadLid(id) {
  const t = await beheerJson(`toegang/${id}.json`);
  const kopie = t?.kopieen?.[S.mij];
  if (!kopie) return null;
  const sl = await K.sleutelsUitDk(await K.pakUit(S.prive, K.b64u.dec(kopie)));
  const profiel = await leesEnc(id, 'profiel', sl);
  const lid = { id, naam: String(S.org.leden[id]?.naam || profiel?.naam || id), sinds: typeof profiel?.sinds === 'string' ? profiel.sinds : null, matrix: null, logs: [] };
  const m = await leesEnc(id, 'matrix', sl); if (m) { const mx = schoonMatrix(m); lid.matrix = mx.size ? mx : null; lid.prioriteit = schoonPrioriteit(m.prioriteit); lid.vakken = schoonVakken(m.vakken); }
  for (const mnd of await Promise.all(logMaanden(id).map((x) => leesEnc(id, `log-${x}`, sl)))) for (const r of mnd?.regels || []) { const s = schoonLog(r); if (s) lid.logs.push(s); }
  lid.logs.sort((a, b) => (a.datum < b.datum ? 1 : -1));
  if (id === S.mij) { lid.sl = sl; lid.profiel = profiel; }
  if (id === S.mij) lid.antwoorden = ((await leesEnc(id, 'prive', S.ak))?.antwoorden || []).filter((a) => a && typeof a.antwoord === 'string');
  return lid;
}

// ---------------------------------------------------------------- berekeningen
const scoresVan = (lid, id) => lid.matrix?.get(id) || {};
function laatste(scores) { const m = Object.keys(scores).sort(); return m.length ? { s: scores[m[m.length - 1]], m: m[m.length - 1] } : null; }
function eerste(scores) { const m = Object.keys(scores).sort(); return m.length ? scores[m[0]] : null; }
function maandenVan(lid) { const s = new Set(); for (const v of lid.matrix?.values() || []) Object.keys(v).forEach((m) => s.add(m)); return [...s].sort(); }
function reeks(logs) {
  const dagen = new Set(logs.map((l) => l.datum.slice(0, 10))); const d = nu(); let n = 0;
  if (!dagen.has(dagKey(d))) d.setDate(d.getDate() - 1);
  for (let i = 0; i < 3650; i++) { const w = d.getDay(); if (dagen.has(dagKey(d))) n++; else if (w !== 0 && w !== 6) break; d.setDate(d.getDate() - 1); }
  return n;
}
// Bewijs per vaardigheid: goed +1, deels 0, fout -1; gevorderd x1,5, expert x2; recenter weegt zwaarder (halfwaarde 60 dagen)
function bewijs(lid) {
  const per = new Map(), nuMs = Date.now();
  for (const l of lid.logs) {
    const w = (l.niveau === 'expert' ? 2 : l.niveau === 'gevorderd' ? 1.5 : 1) * Math.pow(0.5, (nuMs - new Date(l.datum)) / (60 * 864e5));
    const v = l.resultaat === 'goed' ? 1 : l.resultaat === 'fout' ? -1 : 0;
    for (const id of l.matrix) { if (!per.has(id)) per.set(id, { som: 0, n: 0, gevorderdGoed: 0 }); const p = per.get(id); p.som += v * w; p.n++; if (v > 0 && l.niveau !== 'basis') p.gevorderdGoed++; }
  }
  return per;
}
function signalen(lid) {
  const b = bewijs(lid), uit = [];
  for (const [id, p] of b) {
    const zelf = laatste(scoresVan(lid, id))?.s; if (!zelf) continue;
    let s = null;
    if (zelf >= 3 && p.som < -0.3 && p.n >= 2) s = 'overschat';
    else if (zelf <= 2 && p.som > 0.8 && (p.gevorderdGoed > 0 || p.n >= 2)) s = 'onderschat';
    else if (zelf >= 3 && p.som > 0.3) s = 'bevestigd';
    if (s) uit.push({ id, s, zelf, n: p.n });
  }
  const groei = [];
  for (const [id, sc] of lid.matrix || []) { const a = eerste(sc), z = laatste(sc)?.s; if (a && z && z > a) groei.push({ id, s: 'groeit', zelf: z, van: a }); }
  const orde = { overschat: 0, onderschat: 1, groeit: 2, bevestigd: 3 };
  return [...uit, ...groei.filter((g) => !uit.some((u) => u.id === g.id))].sort((x, y) => orde[x.s] - orde[y.s]);
}
function groepeer(lid, vakken = vakkenVan(lid)) {
  const g = new Map();
  for (const it of [...S.sjabloon.values()].filter((i) => vakken.includes(i.vak))) {
    const hg = hgNaam(it);
    if (!g.has(hg)) g.set(hg, new Map());
    const o = g.get(hg); if (!o.has(it.onderwerp)) o.set(it.onderwerp, []);
    o.get(it.onderwerp).push({ ...it, scores: scoresVan(lid, it.id) });
  }
  return g;
}
const gem = (xs) => { const v = xs.filter((x) => typeof x === 'number'); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : 0; };

// ---------------------------------------------------------------- weergave: mij
function toonMij() {
  const lid = S.leden[S.mij], logs = lid.logs;
  const tel = { goed: 0, deels: 0, fout: 0 }; logs.forEach((l) => { if (l.resultaat) tel[l.resultaat]++; });
  const mijnItems = itemsVan(lid), beoordeeld = tel.goed + tel.deels + tel.fout, maanden = maandenVan(lid), totaal = mijnItems.length;
  const items = mijnItems.map((it) => lid.matrix?.get(it.id)).filter(Boolean);
  const opNiveau = items.filter((s) => (laatste(s)?.s || 0) >= 3).length, start = items.filter((s) => (eerste(s) || 0) >= 3).length;
  const delta = pct(opNiveau, totaal) - pct(start, totaal), rk = reeks(logs);
  $('kpis').innerHTML =
    `<div class="kpi accent"><span class="label">Lessen afgerond</span><span class="waarde num">${logs.length}</span><span class="toel">${logs.filter((l) => l.datum.startsWith(dagKey(nu()).slice(0, 7))).length} deze maand</span></div>` +
    `<div class="kpi"><span class="label">Reeks</span><span class="waarde num">${rk}<small> ${rk === 1 ? 'dag' : 'dagen'}</small></span><span class="toel">Weekenden tellen niet als onderbreking</span></div>` +
    `<div class="kpi"><span class="label">Goed beantwoord</span><span class="waarde num">${pct(tel.goed, beoordeeld)}<small>%</small></span><span class="toel num">${tel.goed} goed · ${tel.deels} deels · ${tel.fout} fout</span></div>` +
    (lid.matrix
      ? `<div class="kpi"><span class="label">Skilllijst op niveau</span><span class="waarde num">${pct(opNiveau, totaal)}<small>%</small></span><span class="toel num">${opNiveau} van ${totaal} op 3–5${maanden.length > 1 ? ` · ${delta >= 0 ? '+' : ''}${delta} pt sinds ${esc(fmtMaand(maanden[0]))}` : maanden.length ? ` · meting ${esc(fmtMaand(maanden[0]))}` : ''}</span></div>`
      : '<div class="kpi"><span class="label">Skilllijst</span><span class="waarde num">–</span><span class="toel">Nog geen skilllijst. <button type="button" class="leslink" data-naar="skilllijst" data-formulier="1">Vul hem in</button></span></div>');

  const sig = signalen(lid);
  $('signalen').innerHTML = sig.length ? sig.slice(0, 8).map((x) => {
    const it = S.sjabloon.get(x.id) || {}, over = logs.filter((l) => l.matrix.includes(x.id));
    return `<details class="sig"><summary class="rij"><span><b>${esc(it.vaardigheid || x.id)}</b><br><span class="sub">${esc(it.onderwerp)} · jij ${Number(x.zelf)}${x.van ? ` (was ${Number(x.van)})` : ''}${over.length ? ` · ${over.length} les${over.length === 1 ? '' : 'sen'}` : ''}</span></span>${sigChip(x.s)}</summary>`
      + `<div class="sig-lessen">${over.length ? over.map((l) => `<div class="sig-les"><span class="sub num datum-k">${esc(fmtDatum(l.datum))}</span><span>${lesKnop(l.id, l.datum, titelVan(l))}</span>${chip(l.resultaat)}</div>`).join('') : '<p class="leeg">Nog geen lessen over deze vaardigheid.</p>'}</div></details>`;
  }).join('')
    : '<p class="leeg">Nog te weinig lessen om iets over te zeggen. Na een paar weken zie je hier waar je eigen score en je resultaten uit elkaar lopen.</p>';

  // Per dag alle lessen (oudste eerst); een vakje opent de eerste, de les toont de rest onder "Ook die dag"
  const gedaan = new Map();
  for (const l of [...logs].reverse()) { const k = l.datum.slice(0, 10); if (!gedaan.has(k)) gedaan.set(k, []); gedaan.get(k).push(l); }
  const vandaag = nu(); vandaag.setHours(12, 0, 0, 0);
  const d = new Date(vandaag); d.setDate(d.getDate() - 7 * 25 - ((d.getDay() + 6) % 7));
  // Begin bij je aanmelding (of je eerste les als die eerder was) en groei door tot de laatste 26 weken
  const begin = [lid.sinds, logs.length ? logs[logs.length - 1].datum.slice(0, 10) : null].filter((x) => /^\d{4}-\d{2}-\d{2}/.test(String(x))).map((x) => String(x).slice(0, 10)).sort()[0] || null;
  let vanafAanmelding = false;
  if (begin) { const b = new Date(begin + 'T12:00:00'); b.setDate(b.getDate() - ((b.getDay() + 6) % 7)); if (b > d) { d.setTime(b.getTime()); vanafAanmelding = true; } }
  const cellen = []; let n26 = 0;
  while (d <= vandaag || (d.getDay() + 6) % 7 !== 0) {
    const k = dagKey(d), ls = gedaan.get(k), toekomst = d > vandaag, isVandaag = k === dagKey(vandaag);
    if (toekomst || (vanafAanmelding && k < begin)) cellen.push('<div class="buiten"></div>');
    else if (ls) {
      // Kleurintensiteit: licht = 1 les, donker = 2 (of meer) lessen die dag
      n26++; const tip = `${fmtDatum(k)}, ${ls.length} ${ls.length === 1 ? 'les' : 'lessen'}: ${ls.map(titelVan).join(' · ')}`;
      cellen.push(`<button type="button" class="gedaan${ls.length >= 2 ? ' twee' : ''}${isVandaag ? ' vandaag' : ''}" data-les="${esc(ls[0].id)}" data-datum="${esc(ls[0].datum)}" data-tip="${esc(tip)}" aria-label="${esc(tip)}"></button>`);
    } else cellen.push(`<div${isVandaag ? ' class="vandaag"' : ''} data-tip="${esc(fmtDatum(k) + ': geen les')}"></div>`);
    d.setDate(d.getDate() + 1);
  }
  $('kal').innerHTML = cellen.join(''); $('kal').parentNode.scrollLeft = 1e6;
  const nLessen = logs.filter((l) => !vanafAanmelding || l.datum.slice(0, 10) >= begin).length;
  $('kal-sub').textContent = vanafAanmelding
    ? `${nLessen} ${nLessen === 1 ? 'les' : 'lessen'} op ${n26} ${n26 === 1 ? 'dag' : 'dagen'} sinds je begon op ${fmtDatum(begin)}`
    : `${n26} ${n26 === 1 ? 'dag' : 'dagen'} met een les in de afgelopen 26 weken`;

  const antw = new Map((lid.antwoorden || []).map((a) => [String(a.id) + String(a.datum), a.antwoord]));
  $('recent').innerHTML = logs.length ? logs.slice(0, 3).map((l) => lesHtml(l, antw.get(l.id + l.datum))).join('') : '<p class="leeg">Nog geen lessen afgerond. Je eerste les verschijnt vanzelf op je laptop.</p>';
}

// ---------------------------------------------------------------- weergave: skilllijst
function toonSkilllijst() {
  const lid = S.leden[S.mij]; if (!lid) return;
  const maanden = maandenVan(lid), totaal = itemsVan(lid).length, r = ronde(lid);
  const open = vakkenVan(lid).filter((v) => !ingevuld(lid, v)), klaar = vakkenVan(lid).filter((v) => ingevuld(lid, v));
  $('mx-bijwerken').textContent = lid.matrix ? 'Skilllijst bijwerken' : 'Skilllijst invullen';
  $('mx-ronde').textContent = r.voldaan ? `Halfjaarlijkse check van ${r.naam}: gedaan. De volgende is vóór ${r.volgende}.`
    : r.vrij ? `Je skilllijst is nog vers; de eerste halfjaarlijkse check is vóór ${r.volgende}.`
    : `Halfjaarlijkse check: werk je skilllijst bij vóór ${r.tekst}${r.teLaat ? '. De deadline is voorbij: tot je hem bijwerkt, kun je geen lessen doen' : ''}.`;
  $('mx-bijwerken').hidden = !totaal;
  if (!totaal) {
    $('mx-sub').textContent = '';
    $('matrix').innerHTML = isGroep(eigenVak(S.mij)) && !Object.keys(lid.vakken || {}).length
      ? '<p class="leeg">Je hebt nog geen vak gekozen om te leren. Kies er een bij <button type="button" class="leslink" data-naar="instellingen">Instellingen</button>; daarna vul je hier de skilllijst in.</p>'
      : '<p class="leeg">Voor jouw vak is er nog geen skilllijst. Zodra die er is, vul je hem hier in.</p>';
    return;
  }
  if (!lid.matrix) {
    $('mx-sub').textContent = `${totaal} vaardigheden`;
    $('matrix').innerHTML = '<p class="leeg">Je hebt nog geen skilllijst. Klik op <b>Skilllijst invullen</b> en geef per vaardigheid aan hoe goed je hem nu beheerst.</p>';
    return;
  }
  const nogDoen = open.length ? `<p class="leeg">Nog niet ingevuld: ${open.map((v) => `<b>${esc(vakNaam(v))}</b> <button type="button" class="leslink" data-naar="skilllijst" data-formulier="1" data-vak="${esc(v)}">vul in</button>`).join(' · ')}. Tot dan krijg je daarin lessen op beginnersniveau.</p>` : '';
  $('mx-sub').textContent = maanden.length ? `${totaal} vaardigheden · laatste meting ${fmtMaand(maanden[maanden.length - 1])}. Klik op een onderwerp voor details.` : 'Nog geen scores.';
  const sig = signalen(lid), b = bewijs(lid), sigPer = new Map(sig.map((x) => [x.id, x.s]));
  $('matrix').innerHTML = nogDoen + [...groepeer(lid, klaar)].map(([hg, onderwerpen]) => `<div class="mx-groep"><h3>${esc(hg)}</h3>${[...onderwerpen].map(([o, its]) => {
    const nuG = gem(its.map((i) => laatste(i.scores)?.s)), startG = gem(its.map((i) => eerste(i.scores)));
    return `<details class="mx"><summary><span class="mx-naam"><i class="pijl"></i>${esc(o)}</span><span class="balk" data-tip="${esc(`${o}: ${komma(nuG)}${maanden.length > 1 ? ` (eerste meting ${komma(startG)})` : ''}`)}"><i style="width:${((nuG / 5) * 100).toFixed(1)}%"></i>${maanden.length > 1 ? `<b style="left:calc(${((startG / 5) * 100).toFixed(1)}% - 1px)"></b>` : ''}</span><span class="mx-score num">${komma(nuG)}</span></summary><div class="mx-items">${its.map((i) => {
      const hist = Object.keys(i.scores).sort().map((m) => Number(i.scores[m])).join(' → '); const bi = b.get(i.id);
      return `<div class="mx-item"><span class="id num">${esc(i.nr || i.id)}</span><span>${esc(i.vaardigheid)} ${sigChip(sigPer.get(i.id))}${bi ? ` <span class="tag">${Number(bi.n)} les${bi.n === 1 ? '' : 'sen'}</span>` : ''}${i.notitie ? `<span class="noot">${esc(i.notitie)}</span>` : ''}</span><span class="num" style="font-weight:600">${esc(hist || '–')}</span></div>`;
    }).join('')}</div></details>`;
  }).join('')}</div>`).join('');
}
// Bewust leeg: je eerdere score staat er niet bij, zodat je echt opnieuw inschat. Typ 1–5 en je springt naar de volgende.
function toonSkillFormulier(vak) {
  const lid = S.leden[S.mij]; if (!lid?.sl) return;
  const vk = vakkenVan(lid); if (!vk.length) return;
  S.formVak = vk.includes(vak) ? vak : vk.find((v) => !ingevuld(lid, v)) || vk[0];
  $('mx-vakkeuze').hidden = vk.length < 2;
  $('mx-vakkeuze').innerHTML = vk.length < 2 ? '' : vk.map((v) => `<button type="button" class="knop" data-formvak="${esc(v)}" aria-pressed="${v === S.formVak}">${esc(vakNaam(v))}${ingevuld(lid, v) ? '' : ' (nieuw)'}</button>`).join('');
  $('mx-form-titel').textContent = meerVakken() ? `Skilllijst ${vakNaam(S.formVak)} bijwerken` : 'Skilllijst bijwerken';
  $('mx-velden').innerHTML = [...groepeer(lid, [S.formVak])].map(([hg, onderwerpen]) => `<div class="mx-groep"><h3>${esc(hg)}</h3>${[...onderwerpen].map(([o, its]) => {
    let context = '';
    const rijen = its.map((i) => {
      const kop = i.context && i.context !== context ? `<div class="mx-context">${esc(i.context)}</div>` : ''; context = i.context;
      return `${kop}<div class="mx-rij"><span class="id num">${esc(i.nr || i.id)}</span><label for="s-${esc(i.id)}">${esc(i.vaardigheid)}${i.notitie ? `<span class="noot">${esc(i.notitie)}</span>` : ''}</label><input class="score-veld num" id="s-${esc(i.id)}" data-id="${esc(i.id)}" inputmode="numeric" maxlength="1" autocomplete="off" aria-label="${esc(`Score 1 tot 5 voor ${i.id} ${i.vaardigheid}`)}"></div>`;
    }).join('');
    return `<div class="mx-onderwerp"><h4>${esc(o)}</h4>${rijen}</div>`;
  }).join('')}</div>`).join('');
  $('mx-fout').textContent = ''; $('mx-klaar').textContent = '';
  telSkillVelden();
  $('mx-form-paneel').hidden = false;
  $('mx-form-paneel').scrollIntoView({ behavior: 'smooth', block: 'start' });
  setTimeout(() => $('mx-velden').querySelector('.score-veld')?.focus({ preventScroll: true }), 400);
}
const skillVelden = () => [...$('mx-velden').querySelectorAll('.score-veld')];
function telSkillVelden() {
  const v = skillVelden(), n = v.filter((x) => /^[1-5]$/.test(x.value)).length;
  $('mx-voortgang').textContent = `${n} van ${v.length} ingevuld`;
}
function springSkillVeld(veld, stap) {
  const v = skillVelden(), doel = v[v.indexOf(veld) + stap];
  if (doel) { doel.focus(); doel.select(); } else if (stap > 0) $('mx-opslaan').focus();
}
$('mx-velden').addEventListener('input', (e) => {
  const veld = e.target.closest('.score-veld'); if (!veld) return;
  veld.value = veld.value.replace(/[^1-5]/g, '').slice(-1);
  veld.classList.remove('mist'); telSkillVelden();
  if (veld.value) springSkillVeld(veld, 1);
});
$('mx-velden').addEventListener('keydown', (e) => {
  const veld = e.target.closest('.score-veld'); if (!veld) return;
  if (e.key === 'ArrowDown' || e.key === 'Enter') { e.preventDefault(); springSkillVeld(veld, 1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); springSkillVeld(veld, -1); }
  else if (e.key === 'Backspace' && !veld.value) { e.preventDefault(); springSkillVeld(veld, -1); }
  else if (e.key.length === 1 && !/[1-5]/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) e.preventDefault();   // ander teken: negeren, score blijft staan
});
$('mx-velden').addEventListener('focusin', (e) => { if (e.target.classList?.contains('score-veld')) e.target.select(); });
// Schrijft de huidige maand voor élke vaardigheid: zo telt het als je halfjaarlijkse inschatting
async function slaSkilllijstOp() {
  const ik = S.leden[S.mij], maand = dagKey(nu()).slice(0, 7), keuze = {}, missend = [];
  for (const veld of skillVelden()) { const v = Number(veld.value); if (S.sjabloon.has(veld.dataset.id) && v >= 1 && v <= 5) keuze[veld.dataset.id] = v; else { missend.push(veld); veld.classList.add('mist'); } }
  if (missend.length) {
    missend[0].focus();
    throw new Error(`Vul nog ${missend.length} ${missend.length === 1 ? 'vaardigheid' : 'vaardigheden'} in (rood gemarkeerd).`);
  }
  await werkBij(S.mij, 'matrix', ik.sl, (h) => {
    const scores = {};
    for (const [id, sc] of Object.entries(h?.scores || {})) if (sc && typeof sc === 'object') scores[id] = { ...sc };
    for (const [id, n] of Object.entries(keuze)) scores[id] = { ...(scores[id] || {}), [maand]: n };
    const prioriteit = schoonPrioriteit(h?.prioriteit), vakken = schoonVakken(h?.vakken);
    return { v: 1, sjabloon: S.inst.vakgebied, scores, ...(Object.keys(prioriteit).length ? { prioriteit } : {}), ...(Object.keys(vakken).length ? { vakken } : {}) };
  });
  const nieuw = await laadLid(S.mij); if (nieuw) S.leden[S.mij] = nieuw;
  $('mx-form-paneel').hidden = true;
  toonMij(); toonSkilllijst(); toonRonde();
  $('mx-klaar').textContent = `Opgeslagen: je inschatting${meerVakken() ? ` voor ${vakNaam(S.formVak)}` : ''} van ${fmtMaand(maand)} staat erin.`;
  if (L.status?.geblokkeerd) { L.status = await kiesLes().catch(() => ({ leeg: true })); toonLesStatus(); }
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// ---------------------------------------------------------------- eigen prioriteit per hoofdgebied
const PRIO = { 1: 'Hoog', 2: 'Normaal', 3: 'Laag' };
function toonPrioriteit() {
  const lid = S.leden[S.mij], p = lid?.prioriteit || {};
  $('prio').innerHTML = lid?.matrix
    ? [...hoofdgebieden(lid)].map(([n, naam]) => `<div class="rij"><span>${esc(naam)}</span><span class="prio-keuze" role="group" aria-label="${esc(`Prioriteit ${naam}`)}">${[1, 2, 3].map((k) => `<button type="button" class="knop" data-prio="${esc(n)}" data-waarde="${k}" aria-pressed="${(p[n] || 2) === k}">${PRIO[k]}</button>`).join('')}</span></div>`).join('')
    : '<p class="leeg">Vul eerst je skilllijst in; daarna kies je hier waar je je op wilt richten.</p>';
}
async function zetPrioriteit(n, k) {
  const ik = S.leden[S.mij];
  $('prio').querySelectorAll('button').forEach((b) => { b.disabled = true; }); $('prio-status').textContent = 'Opslaan…';
  try {
    await werkBij(S.mij, 'matrix', ik.sl, (h) => { if (!h) throw new Error('Vul eerst je skilllijst in.'); return { ...h, prioriteit: { ...schoonPrioriteit(h.prioriteit), [n]: k } }; });
    ik.prioriteit = { ...(ik.prioriteit || {}), [n]: k };
    $('prio-status').textContent = `Opgeslagen: ${hoofdgebieden().get(n)} heeft nu prioriteit ${PRIO[k].toLowerCase()}. De generator houdt er vanaf de volgende ochtend rekening mee.`;
  } catch (e) { $('prio-status').textContent = 'Opslaan mislukt: ' + e.message; }
  toonPrioriteit();
}
$('prio').addEventListener('click', (e) => { const b = e.target.closest('button[data-prio]'); if (b && !b.disabled && b.getAttribute('aria-pressed') !== 'true') zetPrioriteit(b.dataset.prio, Number(b.dataset.waarde)); });

// ---------------------------------------------------------------- instellingen (tandwiel rechtsboven)
// Wat je leert, je prioriteiten, het scorebord en hoe je elke dag je les krijgt. Losse tab, zodat de andere tabs rustig blijven.
function toonInstellingen() {
  toonVakken(); toonPrioriteit();
  $('sb-instelling').hidden = !magLessen(); $('sb-zichtbaar').checked = SB.zichtbaar;
  $('snelkoppeling').hidden = !magLessen();
}

// ---------------------------------------------------------------- welke vakken je leert
// Alle vakken uit instellingen.json die je kunt leren (geen groepen zoals Base); een vak zonder skilllijst staat erbij als
// "volgt nog". Uit = geen lessen over dat vak. Wie bij een groep hoort, heeft geen standaardvak en kiest zelf.
const isGroep = (v) => S.alleVakken.find((x) => x.id === v)?.soort === 'groep';
function toonVakken() {
  const lid = S.leden[S.mij], leerbaar = S.alleVakken.filter((v) => v.soort !== 'groep');
  $('vakken-paneel').hidden = leerbaar.length < 2 || !lid?.sl;
  if ($('vakken-paneel').hidden) return;
  const k = gekozenVakken(lid), eigen = eigenVak(S.mij);
  $('vakken').innerHTML = (isGroep(eigen) ? `<p class="sub" style="margin:0 0 6px">Bij ${esc(vakNaam(eigen))} hoort geen vak met eigen lessen. Zet hieronder aan wat je wilt leren.</p>` : '') + leerbaar.map((v) => !v.lijst
    ? `<div class="rij"><span>${esc(v.naam)}${v.id === eigen ? ' <span class="sub">(jouw vak)</span>' : ''}</span><span class="sub">Skilllijst volgt nog</span></div>`
    : `<div class="rij"><span>${esc(v.naam)}${v.id === eigen ? ' <span class="sub">(jouw vak)</span>' : ''}</span><span class="prio-keuze" role="group" aria-label="${esc(`Leren: ${v.naam}`)}">${[1, 2, 3, 0].map((w) => `<button type="button" class="knop" data-vak="${esc(v.id)}" data-waarde="${w}" aria-pressed="${(k[v.id] || 0) === w}">${w ? PRIO[w] : 'Uit'}</button>`).join('')}</span></div>`).join('');
}
async function zetVak(vak, w) {
  const ik = S.leden[S.mij], nieuw = { ...gekozenVakken(ik) };
  if (w) nieuw[vak] = w; else delete nieuw[vak];
  if (!Object.keys(nieuw).length) { $('vakken-status').textContent = 'Je leert altijd minstens één vak.'; return; }
  $('vakken').querySelectorAll('button').forEach((b) => { b.disabled = true; }); $('vakken-status').textContent = 'Opslaan…';
  try {
    await werkBij(S.mij, 'matrix', ik.sl, (h) => ({ ...(h || { v: 1, sjabloon: S.inst.vakgebied, scores: {} }), vakken: nieuw }));
    ik.vakken = nieuw;
    $('vakken-status').textContent = w
      ? `Opgeslagen: ${vakNaam(vak)} staat op ${PRIO[w].toLowerCase()}.${ingevuld(ik, vak) ? '' : ' Vul ook je skilllijst voor dit vak in, dan passen de lessen bij je niveau.'} De generator houdt er vanaf de volgende ochtend rekening mee.`
      : `Opgeslagen: je krijgt geen lessen meer over ${vakNaam(vak)}.`;
  } catch (e) { $('vakken-status').textContent = 'Opslaan mislukt: ' + e.message; }
  toonInstellingen(); toonSkilllijst(); toonMij();
}
$('vakken').addEventListener('click', (e) => { const b = e.target.closest('button[data-vak]'); if (b && !b.disabled && b.getAttribute('aria-pressed') !== 'true') zetVak(b.dataset.vak, Number(b.dataset.waarde)); });
$('mx-vakkeuze').addEventListener('click', (e) => { const b = e.target.closest('button[data-formvak]'); if (b && b.getAttribute('aria-pressed') !== 'true') toonSkillFormulier(b.dataset.formvak); });

// ---------------------------------------------------------------- halfjaarlijkse check van de skilllijst
// Twee rondes per jaar: januari (deadline 31 januari) en juli (deadline 31 juli). Gedaan = een score uit dat halfjaar.
// Wie zijn eerste meting of zijn aanmelding minder dan ~3 maanden voor de deadline deed, slaat die ronde over.
// Na de deadline: geen lessen tot de skilllijst is bijgewerkt.
const MAANDLANG = ['januari', 'februari', 'maart', 'april', 'mei', 'juni', 'juli', 'augustus', 'september', 'oktober', 'november', 'december'];
function ronde(lid, d = nu()) {
  const j = d.getFullYear(), h2 = d.getMonth() >= 6, start = `${j}-${h2 ? '07' : '01'}`, eind = `${j}-${h2 ? '12' : '06'}`;
  const maanden = [...new Set([...(lid?.matrix?.values() || [])].flatMap((s) => Object.keys(s)))].sort();
  const voldaan = maanden.some((m) => m >= start && m <= eind);
  const sinds = /^\d{4}-\d{2}/.test(String(lid?.sinds)) ? String(lid.sinds).slice(0, 7) : null, grens = dagKey(new Date(j, (h2 ? 6 : 0) - 2, 1)).slice(0, 7);
  const vrij = !voldaan && ((!!maanden[0] && maanden[0] >= grens) || (!!sinds && sinds >= grens));
  const deadline = new Date(j, h2 ? 6 : 0, 31, 23, 59, 59);
  return { naam: `${MAANDLANG[h2 ? 6 : 0]} ${j}`, tekst: `31 ${MAANDLANG[h2 ? 6 : 0]}`, volgende: `31 ${MAANDLANG[h2 ? 0 : 6]}${h2 ? ` ${j + 1}` : ''}`,
    voldaan, vrij, nodig: !voldaan && !vrij, teLaat: !voldaan && !vrij && d > deadline };
}
function toonRonde() {
  const b = $('ronde-banner'), ik = S.leden[S.mij];
  const r = ik && magLessen() ? ronde(ik) : null;
  if (!r?.nodig) { b.hidden = true; return; }
  b.className = 'banner' + (r.teLaat ? ' laat' : '');
  b.innerHTML = `<span>${r.teLaat ? `<b>De deadline van ${esc(r.tekst)} is voorbij.</b> Werk eerst je skilllijst bij; daarna kun je weer lessen doen.` : `<b>Halfjaarlijkse check:</b> hoe sta je er nu voor? Werk je skilllijst bij vóór ${esc(r.tekst)}.`}</span>`
    + '<button type="button" class="knop zwart" data-naar="skilllijst" data-formulier="1">Skilllijst bijwerken</button>';
  b.hidden = false;
}

// Kennisvideo onder de bron: alleen een echte YouTube-video (zelfde regel als beheer/lescontrole.ps1)
function videoHtml(v) {
  const u = veiligeLink(v?.url);
  if (!u || !/^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{11}$/.test(u)) return '';
  return `<div class="bron video">Wil je er meer over weten? Kijk deze video: <a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(v.titel || 'video')}</a>${v.kanaal ? ` <span class="sub">(${esc(v.kanaal)})</span>` : ''}</div>`;
}
function bronHtml(bron) { const u = veiligeLink(bron?.url); return u ? `<div class="bron">Bron: <a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(bron.titel || u)}</a></div>` : ''; }
const titelVan = (l) => S.lessen[l.id]?.titel || l.titel || l.id;
const lesKnop = (id, datum, tekst) => `<button type="button" class="leslink" data-les="${esc(id)}"${datum ? ` data-datum="${esc(datum)}"` : ''}>${esc(tekst)}</button>`;
function lesHtml(l, antwoord) {
  const les = S.lessen[l.id] || {};
  return `<article class="les"><div class="datum num">${esc(fmtDatum(l.datum))}</div><div><h3>${lesKnop(l.id, l.datum, les.titel || l.titel || l.id)}</h3><div class="meta"><span class="tag">${esc(les.vakgebied || l.vakgebied)}</span>${chip(l.resultaat)}</div>${les.kernpunt ? `<p>${esc(les.kernpunt)}</p>` : ''}${bronHtml(les.bron) + videoHtml(les.video)}${antwoord ? `<details><summary>Jouw antwoord</summary><blockquote>${esc(antwoord)}</blockquote></details>` : ''}</div></article>`;
}

// ---------------------------------------------------------------- weergave: team
const HEAT = ['#F8F6FD', '#E1D3EF', '#C4A8E0', '#9C7CC4', '#6B4E9B'];
function teamLeden() { return Object.values(S.leden).filter((l) => l.id !== S.mij && (l.matrix || l.logs.length)); }
function rolTitel() {
  const hv = headVakken(S.mij); if (hv.length) return `Heel ${hv.map(vakNaam).join(' & ')}`;
  const cel = S.org.cellen.find((c) => c.leider === S.mij); if (cel) return `Cel ${cel.naam}`;
  const p = S.org.cellen.flatMap((c) => c.projecten).find((x) => x.leider === S.mij); if (p) return p.naam;
  return 'Mijn team';
}
function plekVan(id) {
  const l = S.org.leden[id] || {};
  const hv = headVakken(id);
  if (hv.length) return meerVakken() ? `Head ${hv.map(vakNaam).join(' & ')}` : 'Head';   // ook als de head in een cel staat (dan ziet die celleider hem)
  for (const c of S.org.cellen) { if (l.cel === c.id) return String(c.naam); const p = c.projecten.find((x) => x.id === l.project); if (p) return String(p.naam); }
  return '';
}
function toonTeam() {
  // Jezelf bovenaan, zodat je je eigen stand naast die van je team ziet
  const ik = S.leden[S.mij], zelf = ik && (ik.matrix || ik.logs.length) ? [ik] : [];
  const leden = zelf.concat(teamLeden().sort((a, b) => plekVan(a.id).localeCompare(plekVan(b.id)) || a.naam.localeCompare(b.naam)));
  const naamVan = (l) => esc(l.naam) + (l.id === S.mij ? ' <span class="sub" style="font-weight:400">(jij)</span>' : '');
  $('team-titel').textContent = rolTitel();
  // Eén vak tegelijk: standaard het vak waarvan je head bent, anders je eigen vak
  const vak = [S.teamVak, ...headVakken(S.mij), eigenVak(S.mij)].find((v) => S.vakken.some((x) => x.id === v)) || S.vakken[0]?.id;
  $('team-vak').hidden = !meerVakken();
  $('team-vak').innerHTML = S.vakken.map((v) => `<option value="${esc(v.id)}"${v.id === vak ? ' selected' : ''}>${esc(v.naam)}</option>`).join('');
  const vakItems = itemsVan(null, vak);
  const hgs = [...new Set(vakItems.map((i) => i.hoofdgebied))];
  const gemHg = (lid, hg) => gem(vakItems.filter((i) => i.hoofdgebied === hg).map((i) => laatste(scoresVan(lid, i.id))?.s));
  $('heatmap').innerHTML = `<thead><tr><th style="width:150px"></th>${hgs.map((h) => `<th title="${esc(h)}">${esc(h)}</th>`).join('')}</tr></thead><tbody>${leden.map((l) => `<tr><td class="naam"><button type="button" data-lid="${esc(l.id)}">${naamVan(l)}</button><br><span class="sub" style="font-weight:400">${esc(plekVan(l.id))}</span></td>${hgs.map((h) => { const v = gemHg(l, h); const i = Math.max(0, Math.min(4, Math.round(v) - 1)); return v ? `<td style="background:${HEAT[i]};color:${i >= 3 ? '#fff' : '#000'}" data-tip="${esc(`${l.naam} · ${h}: ${komma(v)}`)}">${komma(v)}</td>` : '<td style="background:var(--cool-50)">–</td>'; }).join('')}</tr>`).join('')}</tbody>`;
  $('hm-legenda').innerHTML = [1, 2, 3, 4, 5].map((s) => `<span><i class="sw" style="background:${HEAT[s - 1]};border:1px solid var(--cool)"></i>${s}</span>`).join('') + '<span>gemiddelde laatste score</span>';

  const aandacht = hgs.map((h) => ({ h, v: gem(leden.map((l) => gemHg(l, h)).filter((x) => x)), sterk: leden.filter((l) => gemHg(l, h) >= 3.5) })).filter((x) => x.v && x.v < 2.5).sort((a, b) => a.v - b.v);
  $('aandacht').innerHTML = aandacht.length ? aandacht.map((x) => `<div class="rij"><span><b>${esc(x.h)}</b> · gemiddeld ${komma(x.v)}<br><span class="sub">${x.sterk.length ? `Sterk: ${x.sterk.map((l) => esc(l.naam)).join(', ')} (kennis delen?)` : 'Niemand scoort hier hoog: training of kennissessie?'}</span></span><span class="chip deels">Aandacht</span></div>`).join('') : '<p class="leeg">Geen hoofdgebieden onder de 2,5. Mooi.</p>';

  const maand = dagKey(nu()).slice(0, 7);
  const skillChip = (l) => { const r = ronde(l); return r.voldaan ? '<span class="chip goed"><i></i>Bijgewerkt</span>' : r.vrij ? '<span class="sub">Nieuw</span>' : `<span class="chip ${r.teLaat ? 'fout' : 'deels'}" data-tip="${esc(`Deadline ${r.tekst}`)}"><i></i>${r.teLaat ? 'Te laat' : 'Nog doen'}</span>`; };
  $('activiteit').innerHTML = `<thead><tr><th>Naam</th><th>Plek</th><th class="r">Deze maand</th><th class="r">Reeks</th><th class="r">Goed</th><th>Laatste les</th><th>Skilllijst</th></tr></thead><tbody>${leden.map((l) => { const t = l.logs.filter((x) => x.resultaat); return `<tr><td><button type="button" class="leslink" data-lid="${esc(l.id)}">${naamVan(l)}</button></td><td>${esc(plekVan(l.id))}</td><td class="r num">${l.logs.filter((x) => x.datum.startsWith(maand)).length}</td><td class="r num">${reeks(l.logs)}</td><td class="r num">${t.length ? pct(t.filter((x) => x.resultaat === 'goed').length, t.length) + '%' : '–'}</td><td class="num">${l.logs[0] ? esc(fmtDatum(l.logs[0].datum)) : '–'}</td><td>${skillChip(l)}</td></tr>`; }).join('')}</tbody>`;
  zoekExperts();
}
function zoekExperts() {
  const q = $('expert').value.trim().toLowerCase();
  if (!q) { $('experts').innerHTML = '<p class="leeg">Typ een vaardigheid of onderwerp.</p>'; return; }
  const iedereen = teamLeden().concat(S.leden[S.mij] ? [S.leden[S.mij]] : []);
  const items = [...S.sjabloon.values()].filter((i) => `${i.vaardigheid} ${i.onderwerp} ${i.context}`.toLowerCase().includes(q)).slice(0, 12);
  const rijen = items.map((i) => ({ i, wie: iedereen.map((l) => ({ l, s: laatste(scoresVan(l, i.id))?.s || 0 })).filter((x) => x.s >= 4).sort((a, b) => b.s - a.s) })).filter((r) => r.wie.length);
  $('experts').innerHTML = rijen.length ? rijen.map((r) => `<div class="rij"><span><b>${esc(r.i.vaardigheid)}</b><br><span class="sub">${meerVakken() ? `${esc(vakNaam(r.i.vak))} · ` : ''}${esc(r.i.onderwerp)}</span></span><span style="text-align:right">${r.wie.map((x) => `${esc(x.l.naam)} <b class="num">${Number(x.s)}</b>`).join('<br>')}</span></div>`).join('') : `<p class="leeg">Niemand in je team scoort 4 of 5 op "${esc(q)}".</p>`;
}
function toonProfiel(id) {
  const l = S.leden[id]; if (!l) return;
  const sig = signalen(l), p = $('profiel');
  const ond = [...groepeer(l)].flatMap(([hg, os]) => [...os].map(([o, its]) => ({ hg, o, v: gem(its.map((i) => laatste(i.scores)?.s)) }))).sort((a, b) => a.v - b.v);
  p.hidden = false;
  p.innerHTML = `<div class="paneel-kop"><div><h2>${esc(l.naam)}</h2><p class="sub">${esc(plekVan(id))} · ${l.logs.length} lessen · reeks ${reeks(l.logs)} · scores en resultaten, geen antwoorden</p>${(() => { const hg = hoofdgebieden(), p = l.prioriteit || {}; const t = (k) => Object.keys(p).filter((n) => p[n] === k && hg.has(n)).map((n) => esc(hg.get(n))).join(', '); return t(1) || t(3) ? `<p class="sub">${t(1) ? `Wil zich richten op: <b>${t(1)}</b>` : ''}${t(1) && t(3) ? ' · ' : ''}${t(3) ? `Minder prioriteit: ${t(3)}` : ''}</p>` : ''; })()}</div><button class="knop" type="button" id="profiel-sluit" style="background:var(--cool-50)">Sluiten</button></div>
  <div class="twee"><div><h3 style="font-size:15px;margin-bottom:6px">Laagste onderwerpen</h3>${ond.slice(0, 6).map((x) => `<div class="rij"><span>${esc(x.o)}<br><span class="sub">${esc(x.hg)}</span></span><b class="num">${komma(x.v)}</b></div>`).join('')}
  <h3 style="font-size:15px;margin:16px 0 6px">Sterkste onderwerpen</h3>${ond.slice(-4).reverse().map((x) => `<div class="rij"><span>${esc(x.o)}</span><b class="num">${komma(x.v)}</b></div>`).join('')}</div>
  <div><h3 style="font-size:15px;margin-bottom:6px">Signalen</h3>${sig.length ? sig.slice(0, 6).map((x) => `<div class="rij"><span>${esc(S.sjabloon.get(x.id)?.vaardigheid || x.id)}</span>${sigChip(x.s)}</div>`).join('') : '<p class="leeg">Nog geen signalen.</p>'}
  <h3 style="font-size:15px;margin:16px 0 6px">Recente lessen</h3>${l.logs.slice(0, 6).map((x) => `<div class="rij"><span>${lesKnop(x.id, id === S.mij ? x.datum : null, titelVan(x))}<br><span class="sub">${esc(fmtDatum(x.datum))}</span></span>${chip(x.resultaat)}</div>`).join('') || '<p class="leeg">Nog geen lessen.</p>'}</div></div>`;
  $('profiel-sluit').onclick = () => { p.hidden = true; };
  p.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// ---------------------------------------------------------------- kennisbank
// Alleen lessen die je zelf al gehad hebt: je eigen naslag, die groeit met elke les (en niets verklapt van lessen die nog komen)
function toonKennisbank() {
  const q = $('kb-zoek').value.trim().toLowerCase();
  const gehad = new Map();
  for (const r of S.leden[S.mij]?.logs || []) if (!gehad.has(r.id)) gehad.set(r.id, r);   // logs staan nieuwste eerst
  const alle = [...gehad.values()].map((r) => ({ ...(S.lessen[r.id] || { titel: r.titel, vakgebied: r.vakgebied, niveau: r.niveau, matrix: r.matrix }), log: r }));
  const res = alle.filter((l) => !q || [l.titel, l.kernpunt, l.onderwerp, l.vakgebied, l.bron?.titel].join(' ').toLowerCase().includes(q));
  $('kb-teller').textContent = q ? `${res.length} van ${alle.length} lessen` : `${alle.length} ${alle.length === 1 ? 'les' : 'lessen'} die je gehad hebt`;
  if (!alle.length) { $('kb-lijst').innerHTML = '<p class="leeg">Hier verschijnt elke les die je hebt gedaan, met het kernpunt en de bron. Zo bouw je je eigen naslag op.</p>'; return; }
  $('kb-lijst').innerHTML = res.map((l) => `<article class="les"><div class="datum">${esc(fmtDatum(l.log.datum))}</div><div><h3>${lesKnop(l.log.id, l.log.datum, l.titel || l.log.id)}</h3><div class="meta">${chip(l.log.resultaat)}<span class="tag">${esc(l.vakgebied)}</span>${TYPE[l.type] ? `<span class="tag" style="background:var(--cool-50)">${esc(TYPE[l.type])}</span>` : ''}${l.herkomst === 'team' ? '<span class="tag" style="background:var(--fun-50)">Van het team</span>' : ''}${Array.isArray(l.matrix) && l.matrix.length ? `<span class="tag" style="background:var(--smart-50)">${esc(l.matrix.join(', '))}</span>` : ''}</div>${l.kernpunt ? `<p>${esc(l.kernpunt)}</p>` : ''}${bronHtml(l.bron) + videoHtml(l.video)}</div></article>`).join('') || `<p class="leeg">Niets gevonden voor "${esc(q)}".</p>`;
}

// ---------------------------------------------------------------- lesdetail (#les/<id>)
// De volledige les terug lezen: vraag, uitleg, kernpunt en bron. Niet je eigen antwoord en niet het modelantwoord.
const LESSEN = new Map();
const LES_ID = /^[0-9a-z][0-9a-z-]{0,80}$/;
function haalLes(id) {
  if (!LES_ID.test(id)) return Promise.resolve(null);
  if (!LESSEN.has(id)) LESSEN.set(id, json(S.app, `lessen/${id}.json`).then((l) => (geldigeLes(l, id) ? l : null)).catch(() => null));
  return LESSEN.get(id);
}
const NAV = { huidig: 'mij', vorige: 'mij', les: null, geduwd: false };
function openLes(id, datum) {
  if (!['lesdetail', 'feedback'].includes(NAV.huidig)) NAV.vorige = NAV.huidig;
  history.pushState({ dl: 1 }, '', `${location.pathname}${location.search}#les/${encodeURIComponent(id)}`); NAV.geduwd = true;
  toonLesDetail(id, datum);
}
async function toonLesDetail(id, datum) {
  NAV.huidig = 'lesdetail'; NAV.les = id; toonView('lesdetail'); window.scrollTo({ top: 0 });
  $('ld-kop').innerHTML = '<p class="sub">Les laden…</p>'; $('ld-inhoud').innerHTML = ''; $('ld-knoppen').innerHTML = knop('terug', '← Terug', 'zwart');
  const les = await haalLes(id);
  if (NAV.huidig !== 'lesdetail' || NAV.les !== id) return;
  if (!les) { $('ld-kop').innerHTML = '<h2>Les niet gevonden</h2>'; $('ld-inhoud').innerHTML = '<p>Deze les staat (nog) niet in de kennisbank.</p>'; return; }
  const mijn = (S.leden[S.mij]?.logs || []).filter((l) => l.id === id), log = mijn.find((l) => l.datum === datum) || mijn[0];
  const o = les.opdracht, juist = Number(o.juist);
  const label = { meerkeuze: 'Vraag', open: 'Denk na', 'zoek-op': 'Zoek het op', 'maak-met-claude': 'Maak het met Claude' }[o.soort];
  $('ld-kop').innerHTML = `<div class="les-meta"><span class="pill">${esc(les.vakgebied || '')}${les.type ? ' · ' + esc(TYPE[les.type] || les.type) : ''}</span>${log ? `<span class="sub">Gedaan op ${esc(fmtDatum(log.datum))}</span>${chip(log.resultaat)}` : ''}</div><h2>${esc(les.titel)}</h2>`;
  let h = (les.intro ? `<div class="zacht">${tekstHtml(les.intro)}</div>` : '') + lesLabel(label) + `<div class="vraag">${tekstHtml(o.vraag)}</div>`;
  // Een les die je zelf nog niet had (bijv. vanuit een teamprofiel): antwoord en uitleg pas na een klik
  const opties = (markeer) => `<div class="opties">${o.opties.map((t, i) => { const j = markeer && i === juist; return `<div class="optie stil${j ? ' juist' : ''}"><span aria-hidden="true">${j ? '✓' : '·'}</span><span>${esc(t)}${j ? ' <span class="sub">(juist)</span>' : ''}</span></div>`; }).join('')}</div>`;
  const uitleg = (o.soort === 'meerkeuze' && !log ? opties(true) : '') + tekstHtml(les.toelichting) + lesLabel('Uitleg') + tekstHtml(les.uitleg) + kader(les.kernpunt, 'onthoud', 'Onthoud') + kader(les.toepassing, 'probeer', 'Probeer') + bronHtml(les.bron) + videoHtml(les.video);
  // Bijgewerkt na feedback of resultaten (door de generator): laat zien wanneer en waarom
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(les.herzien || ''))) h = `<p class="sub">${les.actief === false ? 'Uit de roulatie gehaald' : 'Bijgewerkt'} op ${esc(fmtDatum(les.herzien))}${typeof les.wijziging === 'string' && les.wijziging ? ': ' + esc(les.wijziging.slice(0, 300)) : ''}</p>` + h;
  if (o.soort === 'meerkeuze') h += opties(!!log);
  h += log ? uitleg : `<details class="spoiler"><summary>Toon antwoord en uitleg <span class="sub">(je hebt deze les zelf nog niet gehad)</span></summary>${uitleg}</details>`;
  const dag = log?.datum.slice(0, 10), ook = dag ? (S.leden[S.mij]?.logs || []).filter((l) => l.datum.startsWith(dag) && l.id !== id) : [];
  if (ook.length) h += lesLabel('Ook die dag') + ook.map((l) => `<p>${lesKnop(l.id, l.datum, titelVan(l))}</p>`).join('');
  $('ld-inhoud').innerHTML = h;
  $('ld-knoppen').innerHTML = knop('feedback-les', 'Feedback over deze les') + knop('terug', '← Terug', 'zwart');
}
function terugUitDetail() {
  if (NAV.geduwd && history.state?.dl) { NAV.geduwd = false; history.back(); return; }
  tab(magTab(NAV.vorige) ? NAV.vorige : standaardTab());
}

// ---------------------------------------------------------------- scorebord
// Per lid per maand scorebord/<JJJJ-MM>/<lid>.json in de data-repo: ondertekend door het lid zelf, NIET versleuteld (het
// hele team leest mee) en zonder naam (die komt uit het ondertekende organogram). Alleen aantal goed en reeks; nooit
// skilllijst, vragen of antwoorden. Punten = goed + langste reeks in die maand. Wie zich verbergt, ziet het bord zelf ook niet.
const SB_PAD = /^scorebord\/(\d{4}-(?:0[1-9]|1[0-2]))\/(lid-[0-9a-f]{6})\.json$/;
const SB = { cache: new Map(), zichtbaar: true };
const sbPad = (maand, id) => `scorebord/${maand}/${id}.json`;
const sbPaden = () => (S.data.paden || []).filter((p) => SB_PAD.test(p));
const telBaar = (x, max) => Number.isInteger(x) && x >= 0 && x <= max;
const isWerkdag = (d) => d.getDay() !== 0 && d.getDay() !== 6;
// Goed en langste reeks binnen één maand (zelfde weekendregel als reeks()); reeksAanEind = de reeks op de laatste dag
function maandStand(logs, maand) {
  const inM = logs.filter((l) => l.datum.startsWith(maand)), dagen = new Set(inM.map((l) => l.datum.slice(0, 10)));
  const [j, m] = maand.split('-').map(Number), d = new Date(j, m - 1, 1, 12), tot = dagKey(nu());
  let lang = 0, cur = 0;
  while (d.getMonth() === m - 1 && dagKey(d) <= tot) {
    if (dagen.has(dagKey(d))) { cur++; lang = Math.max(lang, cur); } else if (isWerkdag(d) && dagKey(d) !== tot) cur = 0;
    d.setDate(d.getDate() + 1);
  }
  return { goed: inM.filter((l) => l.resultaat === 'goed').length, langsteReeks: lang, reeksAanEind: cur, laatsteDag: [...dagen].sort().pop() || null, lessen: inM.length };
}
// De opgeslagen huidige reeks is 0 als er sinds de laatste lesdag een werkdag zonder les was (tot en met gisteren)
function actueleReeks(s) {
  if (!s.laatsteDag) return 0;
  const d = new Date(s.laatsteDag + 'T12:00:00'), vandaag = dagKey(nu());
  for (d.setDate(d.getDate() + 1); dagKey(d) < vandaag; d.setDate(d.getDate() + 1)) if (isWerkdag(d)) return 0;
  return s.huidigeReeks;
}
async function leesScore(pad) {
  if (SB.cache.has(pad)) return SB.cache.get(pad);
  const [, maand, id] = SB_PAD.exec(pad) || []; let uit = null;
  try {
    const env = maand ? await json(S.data, pad) : null;
    if (env) {
      let s = null;
      // Ondertekend door het lid zelf of door de generator (die elke ochtend ieders stand bijwerkt)
      if (env.v === 2 && (env.door === id || env.door === 'generator') && typeof env.inhoud === 'string') {
        for (const pub of await sleutelsVan(env.door)) if (await K.verifieer(pub, `scorebord|${maand}|${id}`, env.door, env.inhoud, env.sig)) { s = JSON.parse(env.inhoud); break; }
      }
      if (s?.v === 1 && s.maand === maand && s.zichtbaar === false) uit = { id, maand, zichtbaar: false };
      else if (s?.v === 1 && s.maand === maand && s.zichtbaar === true && telBaar(s.goed, 5000) && telBaar(s.langsteReeks, 31) && telBaar(s.huidigeReeks, 3650) && (s.laatsteDag === null || /^\d{4}-\d{2}-\d{2}$/.test(s.laatsteDag)))
        uit = { id, maand, zichtbaar: true, goed: s.goed, langsteReeks: s.langsteReeks, huidigeReeks: s.huidigeReeks, laatsteDag: s.laatsteDag };
      else S.ongeldig++;
    }
  } catch { S.ongeldig++; }
  SB.cache.set(pad, uit); return uit;
}
// Wie zich verborg: per lid telt het nieuwste GELDIGE bestand (maanden na deze maand tellen niet mee). Bij verbergen
// overschrijft het lid al zijn maanden, dus een verwijderd of vervalst bestand maakt iemand niet zichtbaar.
async function sbVerborgen() {
  const nuM = dagKey(nu()).slice(0, 7), per = new Map();
  for (const p of sbPaden()) { const [, m, id] = SB_PAD.exec(p); if (m > nuM) continue; if (!per.has(id)) per.set(id, []); per.get(id).push(m); }
  const uit = new Set();
  await Promise.all([...per].map(async ([id, ms]) => {
    for (const m of ms.sort().reverse()) { const s = await leesScore(sbPad(m, id)); if (s) { if (!s.zichtbaar) uit.add(id); return; } }
  }));
  return uit;
}
async function schrijfOndertekend(pad, context, obj) {
  const inhoud = JSON.stringify(obj);
  const b = K.tekst.naarBytes(JSON.stringify({ v: 2, door: S.mij, inhoud, sig: await K.onderteken(S.teken, context, S.mij, inhoud) }));
  for (let poging = 1; poging <= 4; poging++) {
    try { await S.data.schrijf(pad, b); return; }
    catch (e) { if (e.message !== 'conflict') throw e; await S.data.ververs(pad); await new Promise((r) => setTimeout(r, 400 * poging)); }
  }
  throw new Error('Opslaan lukt niet: het bestand werd steeds tegelijk gewijzigd.');
}
// Eigen stand bijwerken voor deze en (als daar lessen in zaten) de vorige maand; alleen schrijven als er iets veranderde.
// Na het aan- of uitzetten (alleMaanden): elke maand met een eigen bestand of lessen, zodat verbergen nergens cijfers laat staan.
async function werkScorebordBij(alleMaanden = false) {
  const ik = S.leden[S.mij]; if (!ik?.sl || !S.teken || !magLessen()) return;
  const nuM = dagKey(nu()).slice(0, 7), v = nu(); v.setDate(1); v.setMonth(v.getMonth() - 1);
  const maanden = alleMaanden
    ? [...new Set([...sbPaden().map((p) => SB_PAD.exec(p)).filter((m) => m[2] === S.mij).map((m) => m[1]), ...ik.logs.map((l) => l.datum.slice(0, 7)), nuM])].filter((m) => m <= nuM).sort()
    : [dagKey(v).slice(0, 7), nuM];
  for (const maand of maanden) {
    const pad = sbPad(maand, S.mij), st = maandStand(ik.logs, maand), bestaat = (S.data.paden || []).includes(pad);
    if (maand !== nuM && !st.lessen && !bestaat) continue;
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(maand)) continue;
    const obj = SB.zichtbaar
      ? { v: 1, maand, zichtbaar: true, goed: st.goed, langsteReeks: st.langsteReeks, huidigeReeks: maand === nuM ? reeks(ik.logs) : st.reeksAanEind, laatsteDag: st.laatsteDag }
      : { v: 1, maand, zichtbaar: false };
    const oud = bestaat ? await leesScore(pad) : null;
    if (oud && ['zichtbaar', 'goed', 'langsteReeks', 'huidigeReeks', 'laatsteDag'].every((k) => oud[k] === obj[k])) continue;
    await schrijfOndertekend(pad, `scorebord|${maand}|${S.mij}`, { ...obj, bijgewerkt: lokaleTijd() });
    SB.cache.set(pad, { id: S.mij, ...obj });
  }
}
async function toonScorebord() {
  const nuM = dagKey(nu()).slice(0, 7), sel = $('sb-keuze');
  const maanden = [...new Set([nuM, ...sbPaden().map((p) => SB_PAD.exec(p)[1])])].sort().reverse();
  const opties = [...maanden.map((m) => [`m:${m}`, `${MAANDLANG[+m.slice(5) - 1]} ${m.slice(0, 4)}`]), ...[...new Set(maanden.map((m) => m.slice(0, 4)))].map((j) => [`j:${j}`, `Heel ${j}`])];
  const gekozen = opties.some(([w]) => w === sel.value) ? sel.value : `m:${nuM}`;
  sel.innerHTML = opties.map(([w, t]) => `<option value="${esc(w)}"${w === gekozen ? ' selected' : ''}>${esc(t)}</option>`).join('');
  const [soort, w] = gekozen.split(':'), ms = soort === 'm' ? [w] : maanden.filter((m) => m.startsWith(w)), huidig = soort === 'm' && w === nuM;
  $('sb-tabel').innerHTML = '<tbody><tr><td class="sub">Laden…</td></tr></tbody>';
  const [standen, verborgen] = await Promise.all([Promise.all(sbPaden().filter((p) => ms.includes(SB_PAD.exec(p)[1])).map(leesScore)), sbVerborgen()]);
  if (sel.value !== gekozen) return;
  const per = new Map();
  for (const s of standen) {
    if (!s?.zichtbaar || verborgen.has(s.id) || !S.org.leden[s.id]) continue;
    const t = per.get(s.id) || { id: s.id, goed: 0, punten: 0, reeks: 0, nu: 0 };
    t.goed += s.goed; t.punten += s.goed + s.langsteReeks; t.reeks = Math.max(t.reeks, s.langsteReeks); if (s.maand === nuM) t.nu = actueleReeks(s);
    per.set(s.id, t);
  }
  const rij = [...per.values()].sort((a, b) => b.punten - a.punten || b.goed - a.goed || String(S.org.leden[a.id].naam).localeCompare(String(S.org.leden[b.id].naam)));
  let plek = 0;
  $('sb-tabel').innerHTML = rij.length ? `<thead><tr><th class="r">#</th><th>Naam</th><th class="r">Goed</th><th class="r">Langste reeks</th>${huidig ? '<th class="r">Reeks nu</th>' : ''}<th class="r">Punten</th></tr></thead><tbody>${rij.map((t, i) => {
    if (i === 0 || t.punten !== rij[i - 1].punten || t.goed !== rij[i - 1].goed) plek = i + 1;
    return `<tr${t.id === S.mij ? ' class="ik"' : ''}><td class="r num">${plek}</td><td>${esc(S.org.leden[t.id].naam || t.id)}${t.id === S.mij ? ' <span class="sub">(jij)</span>' : ''}</td><td class="r num">${t.goed}</td><td class="r num">${t.reeks}</td>${huidig ? `<td class="r num">${t.nu}</td>` : ''}<td class="r num"><b>${t.punten}</b></td></tr>`;
  }).join('')}</tbody>` : '<tbody><tr><td class="leeg">Nog niemand op het scorebord in deze periode.</td></tr></tbody>';
  $('sb-sub').textContent = soort === 'j' ? `Jaarstand ${w}: punten en goed opgeteld over de maanden, langste reeks = de beste maand.` : huidig ? 'Deze maand loopt nog. Je stand wordt bijgewerkt zodra je een les afrondt.' : '';
}
// De keuze staat in je eigen profiel (versleuteld en door jou ondertekend), niet in de openbare scorebordbestanden
async function zetZichtbaar(aan) {
  $('sb-zichtbaar').disabled = true; $('sb-zichtbaar-status').textContent = 'Opslaan…';
  try {
    const ik = S.leden[S.mij];
    await werkBij(S.mij, 'profiel', ik.sl, (h) => ({ ...(h && typeof h === 'object' ? h : { v: 1 }), scorebord: aan }));
    ik.profiel = { ...(ik.profiel || {}), scorebord: aan }; SB.zichtbaar = aan;
    await werkScorebordBij(true);
    $('sb-zichtbaar-status').textContent = aan ? 'Je staat op het scorebord.' : 'Je staat niet meer op het scorebord en ziet het zelf ook niet. Eerder getoonde standen kunnen nog in de geschiedenis van de (privé) opslag staan.';
    $('tab-scorebord').hidden = !magTab('scorebord');
  } catch (e) { $('sb-zichtbaar').checked = !aan; SB.zichtbaar = !aan; $('sb-zichtbaar-status').textContent = 'Opslaan mislukt: ' + e.message; }
  finally { $('sb-zichtbaar').disabled = false; }
}

// ---------------------------------------------------------------- feedback
// Versleuteld naar de beheerder: feedback/<tijd>-<willekeurig>.json met een eigen DK, verpakt voor de beheersleutel
// (kopieen is een map: later komt de generator erbij). Binnenin de bekende envelop, ondertekend door het lid.
// De buitenkant verraadt niets (geen naam, geen soort); alleen de beheerder kan lezen wie wat schreef (de generator leest het zonder naam).
const FB_SOORTEN = ['bug', 'fout', 'toevoeging', 'goed'];
let fbTerug = null;
function openFeedback(lesId) {
  const terugNaar = NAV.huidig === 'lesdetail' ? { les: NAV.les } : { tab: NAV.huidig === 'feedback' ? NAV.vorige : NAV.huidig };
  if (NAV.huidig !== 'feedback') fbTerug = terugNaar;
  const gehad = new Map(); for (const l of S.leden[S.mij]?.logs || []) if (!gehad.has(l.id)) gehad.set(l.id, l);
  $('fb-les').innerHTML = '<option value="">Geen specifieke les</option>' + [...gehad.values()].map((l) => `<option value="${esc(l.id)}">${esc(`${fmtDatum(l.datum)}: ${titelVan(l)}`)}</option>`).join('');
  if (lesId && !gehad.has(lesId) && LES_ID.test(lesId)) $('fb-les').insertAdjacentHTML('beforeend', `<option value="${esc(lesId)}">${esc(S.lessen[lesId]?.titel || lesId)}</option>`);
  $('fb-les').value = lesId && LES_ID.test(lesId) ? lesId : '';
  $('fb-fout').textContent = ''; $('fb-status').textContent = '';
  if (NAV.huidig !== 'lesdetail' && NAV.huidig !== 'feedback') NAV.vorige = NAV.huidig;
  NAV.huidig = 'feedback'; toonView('feedback'); history.replaceState(null, '', `${location.pathname}${location.search}#feedback`);
  window.scrollTo({ top: 0 });
}
function sluitFeedback() {
  const t = fbTerug; fbTerug = null;
  if (t?.les) { history.replaceState({ dl: 1 }, '', `${location.pathname}${location.search}#les/${encodeURIComponent(t.les)}`); toonLesDetail(t.les); }
  else tab(t?.tab && magTab(t.tab) ? t.tab : standaardTab());
}
async function verstuurFeedback() {
  const soort = document.querySelector('input[name="fb-soort"]:checked')?.value, tekst = $('fb-tekst').value.trim().slice(0, 2000), les = $('fb-les').value;
  if (!FB_SOORTEN.includes(soort)) throw new Error('Kies wat voor feedback het is.');
  if (tekst.length < 5) throw new Error('Schrijf kort wat je bedoelt.');
  if (soort === 'fout' && !les) throw new Error('Kies over welke les het gaat.');
  if (les && !LES_ID.test(les)) throw new Error('Onbekende les.');
  const naam = `${lokaleTijd().replace(/[-:]/g, '')}-${[...K.willekeurig(4)].map((b) => b.toString(16).padStart(2, '0')).join('')}`, ctx = `feedback|${naam}`;
  const inhoud = JSON.stringify({ v: 1, soort, ...(les ? { les } : {}), tekst, datum: lokaleTijd() });
  const env = { v: 2, door: S.mij, inhoud, sig: await K.onderteken(S.teken, ctx, S.mij, inhoud) };
  const dk = K.willekeurig(32), sl = await K.sleutelsUitDk(dk);
  const kopieen = { beheer: K.b64u.enc(await K.verpak(S.vertrouwd, dk)) }, gen = await generatorSleutel();
  if (gen) kopieen.generator = K.b64u.enc(await K.verpak(gen, dk));   // de lesgenerator leert van feedback
  const bestand = { v: 1, kopieen, blob: K.b64u.enc(await K.versleutel(sl, ctx, vulOp(K.tekst.naarBytes(JSON.stringify(env))))) };
  await S.data.schrijf(`feedback/${naam}.json`, K.tekst.naarBytes(JSON.stringify(bestand)));
  $('fb-form').reset();
  $('fb-status').textContent = 'Bedankt! Je feedback is versleuteld verstuurd naar de beheerder.';
}

// ---------------------------------------------------------------- versleuteld schrijven
// Zelfde formaat als ConvertTo-DlEnvelop in PowerShell: {"v":2,"door","inhoud","sig"}, opgevuld tot een veelvoud van 1024 bytes
function vulOp(b) {
  const doel = Math.max(1024, Math.ceil(b.length / 1024) * 1024);
  if (doel === b.length) return b;
  const out = new Uint8Array(doel).fill(0x20); out.set(b); return out;
}
async function schrijfEnc(id, soort, sl, obj, door, teken) {
  const inhoud = JSON.stringify(obj);
  const env = { v: 2, door, inhoud, sig: await K.onderteken(teken, `${id}|${soort}`, door, inhoud) };
  await S.data.schrijf(`data/${id}/${soort}.enc`, await K.versleutel(sl, `${id}|${soort}`, vulOp(K.tekst.naarBytes(JSON.stringify(env)))));
}
const lokaleTijd = (d = nu()) => `${dagKey(d)}T${[d.getHours(), d.getMinutes(), d.getSeconds()].map((x) => String(x).padStart(2, '0')).join(':')}`;

// ---------------------------------------------------------------- aanmelden (#welkom)
// Alles gebeurt in deze browser: sleutelpaar, code van zes woorden, kluis, datasleutel, versleuteld profiel en
// skilllijst. Naar de privé-repo gaan alleen versleutelde bestanden en een aanvraag; beheer.ps1 -AutoGoedkeuren keurt
// nieuwe aanvragen vanzelf goed. Alleen bij herstel (code kwijt) worden de controlewoorden via Teams vergeleken. Spiegelbeeld van Install-Nieuw in app/installeer.ps1.
const W = { id: null, uitnodiging: null, leren: 'verplicht', naam: '', vak: null, matrix: null, herstel: false };
const welkomItems = () => itemsVan(null, W.vak);
function welkomStap(naam) {
  for (const s of ['w-stap1', 'w-stap2', 'w-stap3', 'w-bestaand', 'w-wacht']) $(s).hidden = s !== naam;
  $('w-fout').textContent = '';
}
async function welkomVerbind() {
  const uitnodiging = $('w-uitnodiging').value.trim();
  W.id = await verbind(uitnodiging); W.uitnodiging = uitnodiging;
  const org = await beheerJson('organisatie.json');
  const lid = org?.leden?.[W.id];
  if (!lid) throw new Error('Deze uitnodiging is (nog) niet bekend. Vraag de beheerder om je toe te voegen.');
  W.leren = lid.leren === 'optioneel' ? 'optioneel' : 'verplicht'; W.naam = String(lid.naam || '');
  W.vak = typeof lid.vak === 'string' && VAK_VORM.test(lid.vak) ? lid.vak : S.inst.vakgebied;
  if ($('w-onthoud').checked) { try { localStorage.setItem('dl-uitnodiging', uitnodiging); } catch {} }
  if (await beheerJson(`sleutels/${W.id}.json`)) { welkomStap('w-bestaand'); return; }
  const a = await json(S.data, `aanvragen/${W.id}.json`);
  if (a && a.id === W.id && a.publiek && a.kluis) {
    $('w-wacht-woorden').textContent = await K.controlewoorden(a, WOORDEN);
    $('w-wacht-herstel').hidden = !a.herstel; $('w-wacht-auto').hidden = !!a.herstel;
    welkomStap('w-wacht'); return;
  }
  welkomFormulier(false);
}
function welkomFormulier(herstel) {
  W.herstel = herstel; W.matrix = null;
  $('w-hallo').textContent = herstel ? 'Nieuwe code aanmaken' : `Welkom${W.naam ? ' ' + W.naam : ''}!`;
  $('w-uitleg').textContent = herstel
    ? 'Je krijgt een nieuwe code van zes woorden. Je scores en voortgang blijven bewaard; je eigen antwoorden op open vragen kunnen niet terug (die kon alleen je oude code openen).'
    : 'Vul je naam in en kies je ingevulde skilllijst. Daarna maakt je browser je persoonlijke code van zes woorden.';
  $('w-naam').value = W.naam; $('w-naam-rij').hidden = herstel; $('w-xlsx-rij').hidden = herstel || !welkomItems().length;
  $('w-xlsx').value = ''; $('w-xlsx-info').textContent = W.leren === 'optioneel' ? 'Optioneel: je kunt dit ook later nog doen.' : '';
  $('w-lessen-rij').hidden = herstel || W.leren !== 'optioneel';
  $('w-maak').textContent = herstel ? 'Nieuwe code aanmaken' : 'Account aanmaken';
  welkomStap('w-stap2');
}
async function welkomLeesXlsx() {
  W.matrix = null; $('w-xlsx-info').textContent = '';
  const f = $('w-xlsx').files?.[0]; if (!f) return;
  $('w-xlsx-info').textContent = 'Skilllijst lezen…';
  try {
    const { leesXlsx, importeerSkilllijst } = await import('./xlsx.js');
    const res = importeerSkilllijst(await leesXlsx(f), new Map(welkomItems().map((i) => [i.id, i])), S.inst.vakgebied);
    if (!res.gekoppeld) throw new Error('Geen vaardigheden met een score (1–5) gevonden. Is dit de skilllijst?');
    W.matrix = res.matrix;
    $('w-xlsx-info').textContent = `${res.gekoppeld} van ${res.totaal} vaardigheden herkend.` + (res.nietGevonden.length ? ` ${res.nietGevonden.length} regel(s) op volgorde gekoppeld.` : '');
  } catch (e) { $('w-xlsx').value = ''; $('w-xlsx-info').textContent = ''; throw e; }
}
async function welkomMaak() {
  const naam = $('w-naam').value.trim();
  if (!W.herstel && !naam) throw new Error('Vul je naam in.');
  if (!W.herstel && W.leren === 'verplicht' && !W.matrix && welkomItems().length) throw new Error('Kies je ingevulde skilllijst (Excel).');
  if (!W.herstel && await beheerJson(`sleutels/${W.id}.json`)) throw new Error('Je bent al aangemeld. Log in met je code.');
  const status = (s) => { $('w-maak').textContent = s; };
  status('Sleutels maken…');
  let kp = await K.nieuwSleutelpaar(3072);
  if (!K.sleutelVorm(kp.publiek)) kp = await K.nieuwSleutelpaar(3072);
  const code = K.nieuweCode(WOORDEN);
  status('Code beveiligen…');
  const kluis = await K.sluitKluis(W.id, kp.prive, code);
  const aanvraag = { v: 1, id: W.id, publiek: kp.publiek, kluis, aangevraagd: lokaleTijd() };
  status('Versleuteld opslaan…');
  if (W.herstel) {
    aanvraag.herstel = true;
    await S.data.verwijder(`data/${W.id}/prive.enc`);   // je oude antwoorden kan niemand meer openen
  } else {
    const dk = K.willekeurig(32), sl = await K.sleutelsUitDk(dk), teken = await K.tekenSleutel(kp.prive);
    const lessen = W.leren === 'verplicht' || $('w-lessen').checked;
    await schrijfEnc(W.id, 'profiel', sl, { v: 1, naam, sinds: dagKey(nu()), lessen }, W.id, teken);
    if (W.matrix) await schrijfEnc(W.id, 'matrix', sl, W.matrix, W.id, teken);
    aanvraag.toegang = { [W.id]: K.b64u.enc(await K.verpak(kp.publiek, dk)), generator: K.b64u.enc(await K.verpak((await generatorSleutel()) || S.vertrouwd, dk)) };
  }
  await S.data.schrijf(`aanvragen/${W.id}.json`, K.tekst.naarBytes(JSON.stringify(aanvraag, null, 2)));
  $('w-code').textContent = code.replace(/-/g, ' ');
  $('w-controle').textContent = await K.controlewoorden(aanvraag, WOORDEN);
  $('w-controle-stap').hidden = !aanvraag.herstel; $('w-auto-stap').hidden = !!aanvraag.herstel;
  $('w-bewaard').checked = false; $('w-klaar').disabled = true;
  welkomStap('w-stap3');
}
function naarInloggen() {
  try { bewaard = localStorage.getItem('dl-uitnodiging'); } catch {}
  if (bewaard && UITNODIGING.test(bewaard)) { $('uitnodiging-rij').hidden = true; $('vergeet-rij').hidden = false; }
  else if (W.uitnodiging) $('uitnodiging').value = W.uitnodiging;
  $('w-code').textContent = ''; W.matrix = null;
  $('welkom').hidden = true; $('login').hidden = false;
  history.replaceState(null, '', location.pathname + location.search);
  $('code').focus();
}
function toonWelkom() { $('login').hidden = true; $('welkom').hidden = false; welkomStap('w-stap1'); }

// ---------------------------------------------------------------- les van vandaag
// Zelfde keuze en opslag als de pop-up (app/dagelijkse-les.ps1): eerst je wachtrij (klaargezet door de generator),
// anders de gedeelde lessenpool. Het resultaat gaat zonder antwoord naar je logboek; je antwoord gaat apart naar je
// privébestand, versleuteld met een sleutel die alleen uit jouw eigen code volgt.
const L = { les: null, keuze: -1, antwoord: '', resultaat: '', uitlegGetoond: false, status: null };
const SOORTEN = ['meerkeuze', 'open', 'zoek-op', 'maak-met-claude'];
const TYPE = { basis: 'Basis', verdieping: 'Verdieping', herhaling: 'Herhaling', nieuws: 'Nieuws' };

function tekstHtml(t) {
  const inline = (s) => esc(s).replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/\*([^*\s][^*]*)\*/g, '<em>$1</em>');
  return String(t || '').split(/(?:\r?\n){2,}/).map((p) => p.trim()).filter(Boolean).map((p) => {
    const regels = p.split(/\r?\n/);
    if (regels.every((r) => /^- /.test(r))) return `<ul>${regels.map((r) => `<li>${inline(r.slice(2))}</li>`).join('')}</ul>`;
    return `<p>${regels.map(inline).join('<br>')}</p>`;
  }).join('');
}
const kader = (tekst, soort, label) => (tekst ? `<div class="kader ${soort}">${label ? `<div class="kader-label">${esc(label)}</div>` : ''}${tekstHtml(tekst)}</div>` : '');
const lesLabel = (t) => `<div class="les-label">${esc(t)}</div>`;
const knop = (actie, tekst, extra = '') => `<button type="button" class="knop ${extra}" data-actie="${actie}">${esc(tekst)}</button>`;

function magLessen() {
  const ik = S.leden[S.mij];
  if (!ik?.sl) return false;
  return !(S.org?.leden?.[S.mij]?.leren === 'optioneel' && ik.profiel?.lessen === false);
}
function geldigeLes(l, id) {
  const o = l?.opdracht;
  if (!l || l.id !== id || typeof l.titel !== 'string' || !o || !SOORTEN.includes(o.soort)) return false;
  if (o.soort === 'meerkeuze' && !(Array.isArray(o.opties) && o.opties.length === 4 && Number.isInteger(Number(o.juist)) && o.juist >= 0 && o.juist <= 3)) return false;
  return true;
}
const MIDDAG = '12:30';
async function kiesLes() {
  const ik = S.leden[S.mij];
  // Twee lessen per dag: één in de ochtend, de tweede vanaf 12:30 (zelfde regel als de pop-up). De reeks blijft per dag.
  const n = nu(), vandaagGedaan = ik.logs.filter((l) => l.datum.startsWith(dagKey(n))).length;
  const middag = `${String(n.getHours()).padStart(2, '0')}:${String(n.getMinutes()).padStart(2, '0')}` >= MIDDAG;
  if (vandaagGedaan >= 2) return { klaar: true, aantal: vandaagGedaan };
  if (vandaagGedaan === 1 && !middag) return { klaar: true, later: true, aantal: 1 };
  if (ronde(ik).teLaat) return { geblokkeerd: true };
  const gedaan = new Set(ik.logs.map((l) => l.id));
  const w = await leesEnc(S.mij, 'wachtrij', ik.sl);
  const kandidaten = [...(Array.isArray(w?.lessen) ? w.lessen.map(String) : []), ...Object.keys(S.lessen)];
  for (const id of kandidaten) {
    if (!id || gedaan.has(id) || !LES_ID.test(id) || S.lessen[id]?.actief === false) continue;
    const les = await haalLes(id);
    if (les && les.actief !== false) return { les };   // uit de roulatie gehaald: overslaan
  }
  return { leeg: true };
}

function toonLesStatus() {
  const ik = S.leden[S.mij], rk = reeks(ik.logs);
  const reeksTekst = `Reeks: ${rk} ${rk === 1 ? 'dag' : 'dagen'} · ${ik.logs.length} ${ik.logs.length === 1 ? 'les' : 'lessen'} afgerond`;
  if (L.status?.les) return startLes(L.status.les);
  if (L.status?.geblokkeerd) {
    const r = ronde(ik);
    $('les-kop').innerHTML = `<div class="les-meta"><span class="pill">Vandaag</span><span class="sub">${esc(reeksTekst)}</span></div><h2>Eerst je skilllijst bijwerken</h2>`;
    $('les-inhoud').innerHTML = `<p>De halfjaarlijkse check had vóór ${esc(r.tekst)} gedaan moeten zijn. Geef in een paar minuten per vaardigheid aan hoe je er nu voor staat; daarna staat je les meteen klaar.</p>`;
    $('les-knoppen').innerHTML = knop('naar-skilllijst', 'Skilllijst bijwerken', 'zwart');
    $('snel-hint').hidden = true; return;
  }
  const st = L.status || {};
  const kop = st.volgende ? 'Les klaar: je tweede les staat klaar' : st.later ? 'Je ochtendles is klaar' : st.klaar ? 'Je lessen van vandaag zijn klaar' : 'Er staat nu geen nieuwe les klaar';
  const tekst = st.volgende ? 'Goed bezig. Je kunt meteen door met je tweede les van vandaag.'
    : st.later ? `Goed bezig. Om ${MIDDAG}, na de lunch, staat je tweede les van vandaag klaar.`
    : st.klaar ? 'Goed bezig: twee lessen vandaag. Morgen staan er weer twee voor je klaar.'
    : 'Je hebt alle beschikbare lessen gedaan. De generator vult ze aan; kijk morgen weer.';
  $('les-kop').innerHTML = `<div class="les-meta"><span class="pill">Vandaag</span><span class="sub">${esc(reeksTekst)}</span></div><h2>${esc(kop)}</h2>`;
  $('les-inhoud').innerHTML = `<p>${esc(tekst)}</p>` + (st.later ? meldingUitleg() : '');
  $('les-knoppen').innerHTML = (st.volgende ? knop('volgende-les', 'Naar je tweede les →', 'zwart') : knop('naar-mij', 'Bekijk je voortgang', 'zwart'))
    + (st.later && meldingStand() === 'default' ? knop('melding-aan', `Stuur me om ${MIDDAG} een melding`) : '')
    + (st.klaar && L.les ? knop('feedback-les', 'Feedback over deze les') : '');
  $('snel-hint').hidden = false;
}

// ---------------------------------------------------------------- melding om 12:30 (alleen als de website openstaat)
// Na de ochtendles springt de kaart om 12:30 vanzelf naar de tweede les; met toestemming komt er ook een browsermelding.
// Geen pushdienst: met de pagina dicht komt er niets (daarvoor is de pop-up).
const meldingStand = () => ('Notification' in window ? Notification.permission : 'geen');   // granted | denied | default | geen
function meldingUitleg() {
  const s = meldingStand();
  if (s === 'granted') return `<p class="sub">Je krijgt om ${MIDDAG} een melding als deze pagina dan nog openstaat (ook op de achtergrond).</p>`;
  return `<p class="sub">Laat deze pagina openstaan, dan springt hij om ${MIDDAG} vanzelf naar je tweede les.${s === 'denied' ? ' Meldingen staan in je browser uit.' : ''}</p>`;
}
let middagBezig = false, middagGestart = false;
async function controleerMiddag() {
  if (middagBezig || !S.mij || !L.status?.later) return;
  const n = nu();
  if (`${String(n.getHours()).padStart(2, '0')}:${String(n.getMinutes()).padStart(2, '0')}` < MIDDAG) return;
  middagBezig = true;
  try {
    const st = await kiesLes().catch(() => null);
    if (!st || st.later || !L.status?.later) return;
    L.status = st.les ? { klaar: true, volgende: st.les } : st;
    toonLesStatus();
    if (st.les && meldingStand() === 'granted') {
      const m = new Notification('DoubleLeren: je tweede les staat klaar', { body: st.les.titel, tag: 'dl-middag-' + dagKey(n) });
      m.onclick = () => { window.focus(); tab('vandaag'); m.close(); };
    }
  } finally { middagBezig = false; }
}
function startMiddagWekker() {
  if (middagGestart) return; middagGestart = true;
  setInterval(controleerMiddag, 60000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) controleerMiddag(); });
  controleerMiddag();
}
function startLes(les) {
  Object.assign(L, { les, keuze: -1, antwoord: '', resultaat: '', uitlegGetoond: false });
  const ik = S.leden[S.mij], rk = reeks(ik.logs);
  $('les-kop').innerHTML = `<div class="les-meta"><span class="pill">${esc(les.vakgebied || '')}${les.type ? ' · ' + esc(TYPE[les.type] || les.type) : ''}</span>
    <span class="sub">Reeks: ${rk} ${rk === 1 ? 'dag' : 'dagen'}</span></div><h2>${esc(les.titel)}</h2>`;
  $('snel-hint').hidden = true;
  // Altijd eerst zelf nadenken: situatie → opdracht → waarom goed of fout → uitleg. Het oude veld 'volgorde'
  // (uitleg-eerst) wordt genegeerd: dan stond het antwoord al in beeld vóór de vraag.
  lesOpdracht();
}
function lesOpdracht() {
  const les = L.les, o = les.opdracht;
  const label = { meerkeuze: 'Vraag', open: 'Denk na', 'zoek-op': 'Zoek het op', 'maak-met-claude': 'Maak het met Claude' }[o.soort];
  let h = (!L.uitlegGetoond && les.intro ? `<div class="zacht">${tekstHtml(les.intro)}</div>` : '') + lesLabel(label) + `<div class="vraag">${tekstHtml(o.vraag)}</div>` + (o.hint ? `<p class="sub">Tip: ${esc(o.hint)}</p>` : '');
  if (o.soort === 'meerkeuze') {
    h += `<div class="opties" role="radiogroup">${o.opties.map((t, i) => `<label class="optie"><input type="radio" name="optie" value="${i}"><span>${esc(t)}</span></label>`).join('')}</div>`;
    $('les-knoppen').innerHTML = knop('controleer', 'Controleer', 'zwart');
  } else {
    const min = Number.isInteger(Number(o.minTekens)) && o.minTekens > 0 ? Number(o.minTekens) : 40;
    if (o.soort === 'maak-met-claude') h += '<p class="sub">Werk het uit in <a href="https://claude.ai/new" target="_blank" rel="noopener noreferrer">Claude</a> (nieuw tabblad) en vat hieronder samen wat je deed en leerde.</p>';
    if (o.soort === 'zoek-op') h += '<p class="sub">Zoek het op in een nieuw tabblad en schrijf hieronder wat je vond.</p>';
    h += `<textarea id="les-antwoord" class="antwoord" rows="7" data-min="${min}" maxlength="5000"></textarea><p class="sub num" id="les-teller">0 / ${min} tekens minimaal · alleen jij kunt dit antwoord lezen</p>`;
    $('les-knoppen').innerHTML = knop('indienen', 'Indienen', 'zwart');
  }
  $('les-inhoud').innerHTML = h;
  $('les-knoppen').querySelector('button').disabled = true;
}
function lesAfronding() {
  const les = L.les, o = les.opdracht;
  let h = '';
  if (o.soort === 'meerkeuze') {
    const juist = Number(o.juist); L.antwoord = String(o.opties[L.keuze]);
    L.resultaat = L.keuze === juist ? 'goed' : 'fout';
    h += L.resultaat === 'goed' ? kader(`**Goed!** ${o.opties[juist]}`, 'goed', '') : kader(`**Niet helemaal.** Jij koos: ${L.antwoord}\n\n**Juist is:** ${o.opties[juist]}`, 'fout', '');
  } else {
    h += kader(L.antwoord, 'neutraal', 'Jouw antwoord') + kader(les.modelantwoord, 'model', 'Zo zou een expert het doen');
  }
  h += tekstHtml(les.toelichting);
  if (!L.uitlegGetoond) h += lesLabel('Uitleg') + tekstHtml(les.uitleg);
  h += kader(les.kernpunt, 'onthoud', 'Onthoud') + kader(les.toepassing, 'probeer', 'Probeer vandaag') + bronHtml(les.bron) + videoHtml(les.video);
  if (o.soort !== 'meerkeuze') {
    h += lesLabel('Hoe ging het?') + `<div class="zelf" role="radiogroup">${[['goed', 'Wist ik goed'], ['deels', 'Deels'], ['fout', 'Wist ik niet']].map(([w, t]) => `<button type="button" class="knop" data-zelf="${w}" aria-pressed="false">${t}</button>`).join('')}</div>`;
  }
  $('les-inhoud').innerHTML = h;
  $('les-knoppen').innerHTML = knop('afronden', 'Afronden', 'zwart') + knop('feedback-les', 'Feedback over deze les');
  $('les-knoppen').querySelector('button').disabled = o.soort !== 'meerkeuze';
  $('les-inhoud').scrollIntoView({ block: 'start', behavior: 'smooth' });
}

// Lezen, wijzigen, schrijven; bij een conflict (andere laptop schreef net) opnieuw vanaf de nieuwste versie
async function werkBij(id, soort, sl, wijzig) {
  for (let poging = 1; poging <= 4; poging++) {
    const b = await S.data.ververs(`data/${id}/${soort}.enc`);
    const h = b ? await openEnc(id, soort, sl, b) : null;   // ongeldig: fout, nooit stilletjes overschrijven
    try { await schrijfEnc(id, soort, sl, wijzig(h), id, S.teken); return; }
    catch (e) { if (e.message !== 'conflict') throw e; await new Promise((r) => setTimeout(r, 400 * poging)); }
  }
  throw new Error('Opslaan lukt niet: het bestand werd steeds tegelijk gewijzigd. Probeer het zo opnieuw.');
}
async function lesOpslaan() {
  const les = L.les, o = les.opdracht, ik = S.leden[S.mij];
  const regel = { datum: lokaleTijd(), id: les.id, resultaat: L.resultaat, soort: o.soort, niveau: les.niveau ?? null,
    matrix: (Array.isArray(les.matrix) ? les.matrix : []).filter(Boolean), vakgebied: les.vakgebied, onderwerp: les.onderwerp, titel: les.titel, type: les.type };
  await werkBij(S.mij, `log-${regel.datum.slice(0, 7)}`, ik.sl, (h) => {
    const r = Array.isArray(h?.regels) ? h.regels : [];
    if (!r.some((x) => x.id === regel.id && x.datum === regel.datum)) r.push(regel);
    return { v: 1, regels: r };
  });
  if (o.soort !== 'meerkeuze' && L.antwoord) {
    await werkBij(S.mij, 'prive', S.ak, (h) => {
      const a = Array.isArray(h?.antwoorden) ? h.antwoorden : [];
      if (!a.some((x) => x.id === regel.id && x.datum === regel.datum)) a.push({ datum: regel.datum, id: regel.id, antwoord: L.antwoord });
      return { v: 1, antwoorden: a };
    });
  }
  const nieuw = await laadLid(S.mij); if (nieuw) S.leden[S.mij] = nieuw;
  toonMij(); toonSkilllijst();
  toonKennisbank();
  // Volgt er vandaag nog een les (bijv. na 12:30 of als de ochtendles werd overgeslagen)? Dan meteen de knop ernaartoe.
  const volgende = await kiesLes().catch(() => ({}));
  L.status = volgende.les ? { klaar: true, volgende: volgende.les } : volgende.later ? { klaar: true, later: true } : { klaar: true };
  toonLesStatus();
  werkScorebordBij().catch(() => {});   // het scorebord loopt bij de volgende keer inloggen alsnog bij
}

// Snelkoppeling om DoubleLeren elke ochtend te openen (Windows: map Opstarten; Mac: Inlogonderdelen)
function downloadTekst(naam, tekst, type) {
  const url = URL.createObjectURL(new Blob([tekst], { type }));
  const a = document.createElement('a'); a.href = url; a.download = naam; document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const lesAdres = () => `${location.origin}${location.pathname}${LOKAAL ? location.search : ''}#vandaag`;
function downloadSnelkoppeling() {
  downloadTekst('DoubleLeren.webloc', `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${esc(lesAdres())}</string></dict></plist>\n`, 'application/xml');
}

$('vandaag').addEventListener('click', async (e) => {
  const zelf = e.target.closest('[data-zelf]');
  if (zelf) {
    L.resultaat = zelf.dataset.zelf;
    $('les-inhoud').querySelectorAll('[data-zelf]').forEach((b) => b.setAttribute('aria-pressed', String(b === zelf)));
    $('les-knoppen').querySelector('button').disabled = false; return;
  }
  const b = e.target.closest('button[data-actie]'); if (!b || b.disabled) return;
  const actie = b.dataset.actie;
  if (actie === 'volgende-les' && L.status?.volgende) { const les = L.status.volgende; L.status = { les }; startLes(les); }
  else if (actie === 'controleer') lesAfronding();
  else if (actie === 'indienen') { L.antwoord = $('les-antwoord').value.trim(); lesAfronding(); }
  else if (actie === 'naar-mij') tab('mij');
  else if (actie === 'melding-aan') { try { await Notification.requestPermission(); } catch { /* browser weigert */ } toonLesStatus(); }
  else if (actie === 'naar-skilllijst') { tab('skilllijst'); toonSkillFormulier(); }
  else if (actie === 'feedback-les') openFeedback(L.les?.id);
  else if (actie === 'snel-win') { try { await navigator.clipboard.writeText(lesAdres()); b.textContent = 'Link gekopieerd'; } catch { b.textContent = lesAdres(); } }
  else if (actie === 'snel-mac') downloadSnelkoppeling();
  else if (actie === 'kopieer-popup') {
    const regel = `Set-ExecutionPolicy -Scope Process Bypass -Force; irm https://raw.githubusercontent.com/${S.eigenaar || 'doubleleren'}/${S.appRepo || 'doubleleren'}/main/app/start.ps1 | iex`;
    try { await navigator.clipboard.writeText(regel); b.textContent = 'Regel gekopieerd'; } catch { b.textContent = regel; }
  }
  else if (actie === 'afronden') {
    b.disabled = true; b.textContent = 'Versleuteld opslaan…'; $('les-fout').textContent = '';
    try { await lesOpslaan(); } catch (err) { $('les-fout').textContent = 'Opslaan mislukt: ' + err.message; b.disabled = false; b.textContent = 'Opnieuw proberen'; }
  }
});
$('vandaag').addEventListener('change', (e) => {
  if (e.target.name === 'optie') { L.keuze = Number(e.target.value); $('les-knoppen').querySelector('button').disabled = false; }
});
$('vandaag').addEventListener('input', (e) => {
  if (e.target.id !== 'les-antwoord') return;
  const n = e.target.value.trim().length, min = Number(e.target.dataset.min);
  $('les-teller').textContent = `${n} / ${min} tekens minimaal · alleen jij kunt dit antwoord lezen`;
  $('les-knoppen').querySelector('button').disabled = n < min;
});

// ---------------------------------------------------------------- les toevoegen (head of SEO en lesmakers)
// De les gaat ondertekend naar doubleleren-data/voorstellen/. De volgende generatorrun controleert de handtekening en
// de les (beheer/voorstellen-opnemen.ps1) en zet hem in de kennisbank; daarna kan hij in wachtrijen komen.
const magLesMaken = () => !!S.mij && !!S.teken && (headVakken(S.mij).length > 0 || S.org?.head === S.mij || (Array.isArray(S.org?.lesmakers) && S.org.lesmakers.includes(S.mij)));
const slug = (t) => t.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 50).replace(/-+$/, '') || 'les';
function verzamelLes() {
  const v = (id) => $(id).value.trim();
  const soort = v('m-soort'), fouten = [];
  const les = {
    id: `${dagKey(nu()).replace(/-/g, '')}-${slug(v('m-titel'))}`, herkomst: 'team',
    type: v('m-type'), niveau: v('m-niveau'), vakgebied: v('m-vakgebied'), onderwerp: v('m-onderwerp'),
    matrix: v('m-matrix').split(/[\s,;]+/).filter(Boolean), titel: v('m-titel'),
    opdracht: { soort, vraag: v('m-vraag') }, uitleg: v('m-uitleg'), kernpunt: v('m-kernpunt')
  };
  for (const [veld, id] of [['intro', 'm-intro'], ['toelichting', 'm-toelichting'], ['modelantwoord', 'm-model'], ['toepassing', 'm-toepassing']]) if (v(id)) les[veld] = v(id);
  if (v('m-hint')) les.opdracht.hint = v('m-hint');
  if (soort === 'meerkeuze') {
    les.opdracht.opties = [0, 1, 2, 3].map((i) => v('m-optie' + i));
    les.opdracht.juist = Number(document.querySelector('input[name="m-juist"]:checked')?.value ?? -1);
    if (les.opdracht.opties.some((o) => !o)) fouten.push('Vul alle vier de antwoordopties in.');
    if (!(les.opdracht.juist >= 0 && les.opdracht.juist <= 3)) fouten.push('Kies welk antwoord juist is.');
  } else {
    les.opdracht.minTekens = Math.min(1000, Math.max(20, Number(v('m-min')) || 80));
    if (!les.modelantwoord) fouten.push('Geef een modelantwoord: zo zou een expert het doen.');
  }
  if (v('m-bron-url')) {
    if (!veiligeLink(v('m-bron-url'))) fouten.push('De bron moet een https://-adres zijn.');
    les.bron = { titel: v('m-bron-titel') || v('m-bron-url'), url: v('m-bron-url') };
  }
  if (!les.titel) fouten.push('Geef de les een titel.');
  if (!les.opdracht.vraag) fouten.push('Vul de vraag of opdracht in.');
  if (!les.uitleg) fouten.push('Vul de uitleg in.');
  if (!les.kernpunt) fouten.push('Vul het kernpunt in.');
  const onbekend = les.matrix.filter((m) => !S.sjabloon.has(m));
  if (onbekend.length) fouten.push(`Onbekende vaardigheid-id's: ${onbekend.join(', ')} (zie de skilllijst, bijv. 1.3.3${meerVakken() ? ' of voor een ander vak cro:1.3.3' : ''}).`);
  if (JSON.stringify(les).length > 20000) fouten.push('De les is te lang.');
  return { les, fouten };
}
function toonMaakSoort() {
  const mk = $('m-soort').value === 'meerkeuze';
  $('m-mk').hidden = !mk; $('m-open').hidden = mk;
}
async function stuurLesIn() {
  const { les, fouten } = verzamelLes();
  if (fouten.length) throw new Error(fouten.join(' '));
  const inhoud = JSON.stringify(les);
  const env = { v: 2, door: S.mij, inhoud, sig: await K.onderteken(S.teken, `voorstel|${les.id}`, S.mij, inhoud) };
  try { await S.data.schrijf(`voorstellen/${les.id}.json`, K.tekst.naarBytes(JSON.stringify(env, null, 2))); }
  catch (e) { if (e.message === 'conflict') throw new Error('Er staat vandaag al een les met deze titel klaar. Kies een andere titel.'); throw e; }
  $('maak-form').reset(); toonMaakSoort();
  $('maak-status').textContent = `Ingediend: "${les.titel}". Bij de volgende generatorrun (elke ochtend) komt hij in de kennisbank en kan hij in wachtrijen komen.`;
}
$('m-soort').addEventListener('change', toonMaakSoort);
$('maak-form').addEventListener('submit', (e) => e.preventDefault());
$('maak-knop').addEventListener('click', async () => {
  const k = $('maak-knop'); k.disabled = true; $('maak-fout').textContent = ''; $('maak-status').textContent = '';
  try { await stuurLesIn(); } catch (e) { $('maak-fout').textContent = e.message; } finally { k.disabled = false; }
});

// ---------------------------------------------------------------- navigatie en start
const TABS = ['vandaag', 'mij', 'skilllijst', 'scorebord', 'team', 'kennisbank', 'maken', 'instellingen'];
const VIEWS = [...TABS, 'lesdetail', 'feedback'];
function toonView(naam) {
  for (const v of VIEWS) $(v).hidden = v !== naam;
  document.querySelectorAll('#tabs button').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === naam)));
  if (naam === 'instellingen') $('instellingen-knop').setAttribute('aria-current', 'page'); else $('instellingen-knop').removeAttribute('aria-current');
}
function magTab(t) {
  const ik = S.leden[S.mij];
  return t === 'mij' || t === 'kennisbank' || t === 'instellingen' || (t === 'skilllijst' && !!ik?.sl) || (t === 'vandaag' && magLessen())
    || (t === 'scorebord' && magLessen() && SB.zichtbaar) || (t === 'team' && teamLeden().length > 0) || (t === 'maken' && magLesMaken());
}
const standaardTab = () => (magLessen() && (L.status?.les || L.status?.geblokkeerd) ? 'vandaag' : !S.leden[S.mij]?.matrix && teamLeden().length ? 'team' : 'mij');
function tab(naam) {
  NAV.huidig = naam; NAV.geduwd = false; toonView(naam);
  if (location.hash !== '#' + naam) history.replaceState(null, '', location.pathname + location.search + '#' + naam);
  if (naam === 'instellingen') toonInstellingen();
  if (naam === 'scorebord') toonScorebord().catch((e) => { $('sb-tabel').innerHTML = `<tbody><tr><td class="fout">Scorebord laden mislukt: ${esc(e.message)}</td></tr></tbody>`; });
}
// Adresbalk volgen (ook terug/vooruit): #les/<id>, #feedback of een tab
function route() {
  let h = ''; try { h = decodeURIComponent(location.hash.slice(1)); } catch { /* kapot adres: standaardtab */ }
  if (h.startsWith('les/') && LES_ID.test(h.slice(4))) { if (NAV.huidig !== 'lesdetail' && NAV.huidig !== 'feedback') NAV.vorige = NAV.huidig; toonLesDetail(h.slice(4)); }
  else if (h === 'feedback') openFeedback();
  else tab(magTab(h) ? h : standaardTab());
}
async function naInloggen() {
  $('login').hidden = true; $('voet').textContent = 'Gegevens worden ontsleuteld en gecontroleerd…';
  S.org = await beheerJson('organisatie.json');
  const geladen = await Promise.all(Object.keys(S.org.leden || {}).map((id) => laadLid(id).catch(() => null)));
  S.leden = Object.fromEntries(geladen.filter(Boolean).map((l) => [l.id, l]));
  const ik = S.leden[S.mij];
  SB.zichtbaar = ik?.profiel?.scorebord !== false;
  $('wie').hidden = false; $('tabs').hidden = false;
  $('wie-naam').textContent = `Ingelogd als ${ik?.naam || S.mij}`;
  $('vak').textContent = vakNaam(eigenVak(S.mij));
  $('feedback-knop').hidden = !S.teken;
  $('tab-team').hidden = !magTab('team');
  if (ik) { toonMij(); toonSkilllijst(); }
  else $('kpis').innerHTML = '<div class="kpi" style="grid-column:1/-1"><span class="label">Geen eigen gegevens</span><span class="toel">Je account is nog niet volledig ingericht. Neem contact op met de beheerder.</span></div>';
  if (teamLeden().length) toonTeam();
  toonKennisbank();
  const lessen = magLessen();
  for (const t of ['vandaag', 'skilllijst', 'scorebord', 'maken']) $('tab-' + t).hidden = !magTab(t);
  if (lessen) { L.status = await kiesLes().catch(() => ({ leeg: true })); toonLesStatus(); startMiddagWekker(); }
  toonRonde();
  route();
  const n = Object.keys(S.leden).length;
  $('voet').textContent = `Gegevens ontsleuteld en gecontroleerd in je browser · ${n} ${n === 1 ? 'persoon' : 'personen'} zichtbaar voor jou${S.ongeldig ? ` · ${S.ongeldig} bestand(en) genegeerd: ongeldige handtekening` : ''}. Antwoorden zijn alleen zichtbaar voor de persoon zelf.`;
  werkScorebordBij().catch(() => {});   // eigen stand bijwerken (bijv. na een les in de pop-up of op een andere laptop)
}

document.addEventListener('mouseover', (e) => { const t = e.target.closest('[data-tip]'), tip = $('tip'); if (!t) { tip.hidden = true; return; } tip.textContent = t.dataset.tip; tip.hidden = false; });
document.addEventListener('mousemove', (e) => { const tip = $('tip'); if (tip.hidden) return; tip.style.left = Math.min(e.clientX + 14, innerWidth - tip.offsetWidth - 8) + 'px'; tip.style.top = e.clientY + 16 + 'px'; });
// Overal: [data-les] opent de les, [data-naar] gaat naar een tab (met data-formulier: meteen het skilllijstformulier)
document.addEventListener('click', (e) => {
  if (!S.org) return;
  const les = e.target.closest('[data-les]');
  if (les) { e.preventDefault(); $('tip').hidden = true; openLes(les.dataset.les, les.dataset.datum); return; }
  const naar = e.target.closest('[data-naar]');
  if (naar && magTab(naar.dataset.naar)) { tab(naar.dataset.naar); if (naar.dataset.formulier && naar.dataset.naar === 'skilllijst') toonSkillFormulier(naar.dataset.vak); }
});
window.addEventListener('popstate', () => { if (S.org) route(); });
$('tabs').addEventListener('click', (e) => { const b = e.target.closest('button[data-tab]'); if (b) tab(b.dataset.tab); });
$('heatmap').addEventListener('click', (e) => { const b = e.target.closest('button[data-lid]'); if (b) toonProfiel(b.dataset.lid); });
$('activiteit').addEventListener('click', (e) => { const b = e.target.closest('button[data-lid]'); if (b) toonProfiel(b.dataset.lid); });
$('ld-knoppen').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-actie]'); if (!b) return;
  if (b.dataset.actie === 'terug') terugUitDetail(); else if (b.dataset.actie === 'feedback-les') openFeedback(NAV.les);
});
$('mx-bijwerken').addEventListener('click', () => toonSkillFormulier());
$('team-vak').addEventListener('change', (e) => { S.teamVak = e.target.value; toonTeam(); });
$('mx-annuleer').addEventListener('click', () => { $('mx-form-paneel').hidden = true; window.scrollTo({ top: 0, behavior: 'smooth' }); });
$('mx-form').addEventListener('submit', (e) => e.preventDefault());
$('mx-opslaan').addEventListener('click', async () => {
  const k = $('mx-opslaan'); k.disabled = true; k.textContent = 'Versleuteld opslaan…'; $('mx-fout').textContent = '';
  try { await slaSkilllijstOp(); } catch (e) { $('mx-fout').textContent = e.message; } finally { k.disabled = false; k.textContent = 'Opslaan'; }
});
$('sb-keuze').addEventListener('change', () => toonScorebord().catch(() => {}));
$('sb-zichtbaar').addEventListener('change', (e) => zetZichtbaar(e.target.checked));
$('feedback-knop').addEventListener('click', () => openFeedback(NAV.huidig === 'lesdetail' ? NAV.les : undefined));
$('fb-form').addEventListener('submit', (e) => e.preventDefault());
$('fb-form').addEventListener('change', (e) => { if (e.target.name === 'fb-soort') $('fb-les-uitleg').textContent = e.target.value === 'fout' ? '(verplicht)' : '(optioneel)'; });
$('fb-terug').addEventListener('click', sluitFeedback);
$('fb-verstuur').addEventListener('click', async () => {
  const k = $('fb-verstuur'); k.disabled = true; $('fb-fout').textContent = ''; $('fb-status').textContent = '';
  try { await verstuurFeedback(); } catch (e) { $('fb-fout').textContent = e.message === 'conflict' ? 'Er ging iets mis bij het versturen. Probeer het opnieuw.' : e.message; } finally { k.disabled = false; }
});
$('expert').addEventListener('input', zoekExperts);
$('kb-zoek').addEventListener('input', toonKennisbank);
$('instellingen-knop').addEventListener('click', () => { if (S.mij) tab('instellingen'); });
$('uitloggen').addEventListener('click', async () => { await vergeetSessie(); location.replace(location.pathname + location.search); });
$('vergeet').addEventListener('click', async () => { try { localStorage.removeItem('dl-uitnodiging'); } catch {} await vergeetSessie(); $('uitnodiging-rij').hidden = false; $('vergeet-rij').hidden = true; });
for (const id of ['code', 'uitnodiging']) $(id).addEventListener('input', () => { $('login-fout').textContent = ''; });

let bewaard = null; try { bewaard = localStorage.getItem('dl-uitnodiging'); } catch { /* geen opslag */ }
if (bewaard && UITNODIGING.test(bewaard)) { $('uitnodiging-rij').hidden = true; $('vergeet-rij').hidden = false; }

$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const uitnodiging = $('uitnodiging-rij').hidden ? bewaard : $('uitnodiging').value;
  if (!uitnodiging || !uitnodiging.trim()) { $('login-fout').textContent = 'Vul je uitnodigingscode in.'; return; }
  if (!$('code').value.trim()) { $('login-fout').textContent = 'Vul je code van zes woorden in.'; return; }
  $('login-knop').disabled = true; $('login-knop').textContent = 'Controleren…';
  try {
    const id = await verbind(uitnodiging);
    const jwk = await inloggen(id, $('code').value);
    if ($('onthoud').checked) {
      try { localStorage.setItem('dl-uitnodiging', uitnodiging.trim()); } catch {}
      await bewaarSessie(id, jwk, uitnodiging.trim());
    }
    $('code').value = ''; $('uitnodiging').value = '';
    await naInloggen();
  } catch (err) { $('login').hidden = false; $('voet').textContent = ''; $('login-fout').textContent = err.message; }
  finally { $('login-knop').disabled = false; $('login-knop').textContent = 'Inloggen'; }
});

// Aanmelden
async function bezig(knop, fn) {
  const tekst = knop.textContent; knop.disabled = true;
  try { await fn(); } catch (e) { $('w-fout').textContent = e.message === 'conflict' ? 'Er schreef net iets anders tegelijk. Probeer het opnieuw.' : e.message; }
  finally { knop.disabled = false; knop.textContent = tekst; }
}
$('w-verder').addEventListener('click', () => bezig($('w-verder'), welkomVerbind));
$('w-uitnodiging').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); $('w-verder').click(); } });
$('w-xlsx').addEventListener('change', () => bezig($('w-maak'), welkomLeesXlsx));
$('w-maak').addEventListener('click', () => bezig($('w-maak'), welkomMaak));
$('w-bewaard').addEventListener('change', () => { $('w-klaar').disabled = !$('w-bewaard').checked; });
$('w-kopieer').addEventListener('click', async () => { try { await navigator.clipboard.writeText($('w-code').textContent); $('w-kopieer').textContent = 'Gekopieerd'; } catch { $('w-kopieer').textContent = 'Kopiëren lukte niet: selecteer de code'; } });
$('w-klaar').addEventListener('click', naarInloggen);
$('w-naar-login').addEventListener('click', naarInloggen);
$('w-herstel').addEventListener('click', () => welkomFormulier(true));
$('w-opnieuw').addEventListener('click', () => welkomFormulier(false));
$('naar-welkom').addEventListener('click', (e) => { e.preventDefault(); history.replaceState(null, '', location.pathname + location.search + '#welkom'); toonWelkom(); });
$('w-terug').addEventListener('click', (e) => { e.preventDefault(); naarInloggen(); });

laadOpenbaar().then(async () => { if (location.hash === '#welkom') toonWelkom(); else await probeerSessie(); })
  .catch((e) => { $('login-fout').textContent = 'DoubleLeren kon niet laden: ' + e.message; });
