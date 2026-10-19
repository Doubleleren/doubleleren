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
      const r = await fetch(url(p), { headers: kop, cache: 'no-store' });
      if (r.status === 404) return null; if (!r.ok) throw new Error(`${p}: ${r.status}`); return new Uint8Array(await r.arrayBuffer());
    },
    // Nieuwste versie en sha ophalen (na een conflict: een andere laptop schreef net)
    async ververs(p) {
      const r = await fetch(url(p), { headers: { ...kop, Accept: 'application/vnd.github+json' }, cache: 'no-store' });
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
const S = { bron: null, mij: null, prive: null, ak: null, org: null, lessen: {}, sjabloon: new Map(), leden: {}, sleutels: new Map(), ongeldig: 0 };

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
  const csv = K.tekst.uitBytes((await S.app.bytes(`sjablonen/${S.inst.vakgebied}/skilllijst.csv`)) || new Uint8Array());
  const [kop, ...regels] = csv.replace(/^﻿/, '').trim().split(/\r?\n/).map((r) => r.split(';'));
  for (const r of regels) { const o = Object.fromEntries(kop.map((k, i) => [k, r[i] || ''])); if (/^\d+\.\d+\.\d+$/.test(o.id)) S.sjabloon.set(o.id, o); }
  $('vak').textContent = String(S.inst.vakgebied).toUpperCase();
}

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
  S.mij = id; S.ak = await K.akUitJwk(jwk); S.prive = await K.priveSleutel(jwk); S.teken = await K.tekenSleutel(jwk);
}

// Publieke sleutels (huidig + eerdere) voor het controleren van handtekeningen
async function sleutelsVan(id) {
  if (id === 'generator') return [S.vertrouwd];
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
function schoonLog(r) {
  if (!r || typeof r !== 'object' || !/^\d{4}-\d{2}-\d{2}T/.test(String(r.datum))) return null;
  return { datum: String(r.datum), id: String(r.id || ''), resultaat: RES[r.resultaat] ? r.resultaat : null, niveau: ['basis', 'gevorderd', 'expert'].includes(r.niveau) ? r.niveau : 'basis',
    matrix: Array.isArray(r.matrix) ? r.matrix.map(String).filter((x) => S.sjabloon.has(x)) : [], titel: String(r.titel || ''), vakgebied: String(r.vakgebied || '') };
}
const logMaanden = (id) => {
  const p = S.data.paden;
  if (p) return p.filter((x) => x.startsWith(`data/${id}/log-`)).map((x) => x.slice(-11, -4)).filter((m) => /^\d{4}-\d{2}$/.test(m));
  const m = []; const d = new Date(); for (let i = 0; i < 12; i++) { m.push(dagKey(d).slice(0, 7)); d.setMonth(d.getMonth() - 1); } return m;
};
async function laadLid(id) {
  const t = await beheerJson(`toegang/${id}.json`);
  const kopie = t?.kopieen?.[S.mij];
  if (!kopie) return null;
  const sl = await K.sleutelsUitDk(await K.pakUit(S.prive, K.b64u.dec(kopie)));
  const profiel = await leesEnc(id, 'profiel', sl);
  const lid = { id, naam: String(S.org.leden[id]?.naam || profiel?.naam || id), matrix: null, logs: [] };
  const m = await leesEnc(id, 'matrix', sl); if (m) lid.matrix = schoonMatrix(m);
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
  const dagen = new Set(logs.map((l) => l.datum.slice(0, 10))); const d = new Date(); let n = 0;
  if (!dagen.has(dagKey(d))) d.setDate(d.getDate() - 1);
  for (let i = 0; i < 3650; i++) { const w = d.getDay(); if (dagen.has(dagKey(d))) n++; else if (w !== 0 && w !== 6) break; d.setDate(d.getDate() - 1); }
  return n;
}
// Bewijs per vaardigheid: goed +1, deels 0, fout -1; gevorderd x1,5, expert x2; recenter weegt zwaarder (halfwaarde 60 dagen)
function bewijs(lid) {
  const per = new Map(), nu = Date.now();
  for (const l of lid.logs) {
    const w = (l.niveau === 'expert' ? 2 : l.niveau === 'gevorderd' ? 1.5 : 1) * Math.pow(0.5, (nu - new Date(l.datum)) / (60 * 864e5));
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
function groepeer(lid) {
  const g = new Map();
  for (const it of S.sjabloon.values()) {
    if (!g.has(it.hoofdgebied)) g.set(it.hoofdgebied, new Map());
    const o = g.get(it.hoofdgebied); if (!o.has(it.onderwerp)) o.set(it.onderwerp, []);
    o.get(it.onderwerp).push({ ...it, scores: scoresVan(lid, it.id) });
  }
  return g;
}
const gem = (xs) => { const v = xs.filter((x) => typeof x === 'number'); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : 0; };

// ---------------------------------------------------------------- weergave: mij
function toonMij() {
  const lid = S.leden[S.mij], logs = lid.logs;
  const tel = { goed: 0, deels: 0, fout: 0 }; logs.forEach((l) => { if (l.resultaat) tel[l.resultaat]++; });
  const beoordeeld = tel.goed + tel.deels + tel.fout, maanden = maandenVan(lid), totaal = S.sjabloon.size;
  const items = [...(lid.matrix?.values() || [])];
  const nu = items.filter((s) => (laatste(s)?.s || 0) >= 3).length, start = items.filter((s) => (eerste(s) || 0) >= 3).length;
  const delta = pct(nu, totaal) - pct(start, totaal), rk = reeks(logs);
  $('kpis').innerHTML =
    `<div class="kpi accent"><span class="label">Lessen afgerond</span><span class="waarde num">${logs.length}</span><span class="toel">${logs.filter((l) => l.datum.startsWith(dagKey(new Date()).slice(0, 7))).length} deze maand</span></div>` +
    `<div class="kpi"><span class="label">Reeks</span><span class="waarde num">${rk}<small> ${rk === 1 ? 'dag' : 'dagen'}</small></span><span class="toel">Weekenden tellen niet als onderbreking</span></div>` +
    `<div class="kpi"><span class="label">Goed beantwoord</span><span class="waarde num">${pct(tel.goed, beoordeeld)}<small>%</small></span><span class="toel num">${tel.goed} goed · ${tel.deels} deels · ${tel.fout} fout</span></div>` +
    `<div class="kpi"><span class="label">Skilllijst op niveau</span><span class="waarde num">${pct(nu, totaal)}<small>%</small></span><span class="toel num">${nu} van ${totaal} op 3–5${maanden.length > 1 ? ` · ${delta >= 0 ? '+' : ''}${delta} pt sinds ${esc(fmtMaand(maanden[0]))}` : maanden.length ? ` · meting ${esc(fmtMaand(maanden[0]))}` : ''}</span></div>`;

  const sig = signalen(lid);
  $('signalen').innerHTML = sig.length ? sig.slice(0, 8).map((x) => { const it = S.sjabloon.get(x.id) || {}; return `<div class="rij"><span><b>${esc(it.vaardigheid || x.id)}</b><br><span class="sub">${esc(it.onderwerp)} · jij ${Number(x.zelf)}${x.van ? ` (was ${Number(x.van)})` : ''}${x.n ? ` · ${Number(x.n)} les${x.n === 1 ? '' : 'sen'}` : ''}</span></span>${sigChip(x.s)}</div>`; }).join('')
    : '<p class="leeg">Nog te weinig lessen om iets over te zeggen. Na een paar weken zie je hier waar je eigen score en je resultaten uit elkaar lopen.</p>';

  $('mx-sub').textContent = maanden.length ? `${totaal} vaardigheden · laatste meting ${fmtMaand(maanden[maanden.length - 1])}. Klik op een onderwerp voor details.` : 'Nog geen scores.';
  const b = bewijs(lid), sigPer = new Map(sig.map((x) => [x.id, x.s]));
  $('matrix').innerHTML = [...groepeer(lid)].map(([hg, onderwerpen]) => `<div class="mx-groep"><h3>${esc(hg)}</h3>${[...onderwerpen].map(([o, its]) => {
    const nuG = gem(its.map((i) => laatste(i.scores)?.s)), startG = gem(its.map((i) => eerste(i.scores)));
    return `<details class="mx"><summary><span class="mx-naam"><i class="pijl"></i>${esc(o)}</span><span class="balk" data-tip="${esc(`${o}: ${komma(nuG)}${maanden.length > 1 ? ` (eerste meting ${komma(startG)})` : ''}`)}"><i style="width:${((nuG / 5) * 100).toFixed(1)}%"></i>${maanden.length > 1 ? `<b style="left:calc(${((startG / 5) * 100).toFixed(1)}% - 1px)"></b>` : ''}</span><span class="mx-score num">${komma(nuG)}</span></summary><div class="mx-items">${its.map((i) => {
      const hist = Object.keys(i.scores).sort().map((m) => Number(i.scores[m])).join(' → '); const bi = b.get(i.id);
      return `<div class="mx-item"><span class="id num">${esc(i.id)}</span><span>${esc(i.vaardigheid)} ${sigChip(sigPer.get(i.id))}${bi ? ` <span class="tag">${Number(bi.n)} les${bi.n === 1 ? '' : 'sen'}</span>` : ''}${i.notitie ? `<span class="noot">${esc(i.notitie)}</span>` : ''}</span><span class="num" style="font-weight:600">${esc(hist || '–')}</span></div>`;
    }).join('')}</div></details>`;
  }).join('')}</div>`).join('');

  const gedaan = new Map(logs.map((l) => [l.datum.slice(0, 10), l]));
  const vandaag = new Date(); vandaag.setHours(12, 0, 0, 0);
  const d = new Date(vandaag); d.setDate(d.getDate() - 7 * 25 - ((d.getDay() + 6) % 7));
  const cellen = []; let n26 = 0;
  while (d <= vandaag || (d.getDay() + 6) % 7 !== 0) {
    const k = dagKey(d), l = gedaan.get(k), toekomst = d > vandaag; if (l && !toekomst) n26++;
    cellen.push(`<div class="${toekomst ? 'buiten' : l ? 'gedaan' : ''}${k === dagKey(vandaag) ? ' vandaag' : ''}"${toekomst ? '' : ` data-tip="${esc(fmtDatum(k) + (l ? `: ${S.lessen[l.id]?.titel || l.titel || l.id}` : ': geen les'))}"`}></div>`);
    d.setDate(d.getDate() + 1);
  }
  $('kal').innerHTML = cellen.join(''); $('kal').parentNode.scrollLeft = 1e6;
  $('kal-sub').textContent = `${n26} ${n26 === 1 ? 'les' : 'lessen'} in de afgelopen 26 weken`;

  const antw = new Map((lid.antwoorden || []).map((a) => [String(a.id) + String(a.datum), a.antwoord]));
  $('recent').innerHTML = logs.length ? logs.slice(0, 8).map((l) => lesHtml(l, antw.get(l.id + l.datum))).join('') : '<p class="leeg">Nog geen lessen afgerond. Je eerste les verschijnt vanzelf op je laptop.</p>';
}

function bronHtml(bron) { const u = veiligeLink(bron?.url); return u ? `<div class="bron">Bron: <a href="${esc(u)}" target="_blank" rel="noopener noreferrer">${esc(bron.titel || u)}</a></div>` : ''; }
function lesHtml(l, antwoord) {
  const les = S.lessen[l.id] || {};
  return `<article class="les"><div class="datum num">${esc(fmtDatum(l.datum))}</div><div><h3>${esc(les.titel || l.titel || l.id)}</h3><div class="meta"><span class="tag">${esc(les.vakgebied || l.vakgebied)}</span>${chip(l.resultaat)}</div>${les.kernpunt ? `<p>${esc(les.kernpunt)}</p>` : ''}${bronHtml(les.bron)}${antwoord ? `<details><summary>Jouw antwoord</summary><blockquote>${esc(antwoord)}</blockquote></details>` : ''}</div></article>`;
}

// ---------------------------------------------------------------- weergave: team
const HEAT = ['#F8F6FD', '#E1D3EF', '#C4A8E0', '#9C7CC4', '#6B4E9B'];
function teamLeden() { return Object.values(S.leden).filter((l) => l.id !== S.mij && (l.matrix || l.logs.length)); }
function rolTitel() {
  if (S.org.head === S.mij) return `Heel ${String(S.inst.vakgebied).toUpperCase()}`;
  const cel = S.org.cellen.find((c) => c.leider === S.mij); if (cel) return `Cel ${cel.naam}`;
  const p = S.org.cellen.flatMap((c) => c.projecten).find((x) => x.leider === S.mij); if (p) return p.naam;
  return 'Mijn team';
}
function plekVan(id) {
  const l = S.org.leden[id] || {};
  for (const c of S.org.cellen) { if (l.cel === c.id) return String(c.naam); const p = c.projecten.find((x) => x.id === l.project); if (p) return String(p.naam); }
  return S.org.head === id ? 'Head' : '';
}
function toonTeam() {
  const leden = teamLeden().sort((a, b) => plekVan(a.id).localeCompare(plekVan(b.id)) || a.naam.localeCompare(b.naam));
  $('team-titel').textContent = rolTitel();
  const hgs = [...new Set([...S.sjabloon.values()].map((i) => i.hoofdgebied))];
  const gemHg = (lid, hg) => gem([...S.sjabloon.values()].filter((i) => i.hoofdgebied === hg).map((i) => laatste(scoresVan(lid, i.id))?.s));
  $('heatmap').innerHTML = `<thead><tr><th style="width:150px"></th>${hgs.map((h) => `<th title="${esc(h)}">${esc(h)}</th>`).join('')}</tr></thead><tbody>${leden.map((l) => `<tr><td class="naam"><button type="button" data-lid="${esc(l.id)}">${esc(l.naam)}</button><br><span class="sub" style="font-weight:400">${esc(plekVan(l.id))}</span></td>${hgs.map((h) => { const v = gemHg(l, h); const i = Math.max(0, Math.min(4, Math.round(v) - 1)); return v ? `<td style="background:${HEAT[i]};color:${i >= 3 ? '#fff' : '#000'}" data-tip="${esc(`${l.naam} · ${h}: ${komma(v)}`)}">${komma(v)}</td>` : '<td style="background:var(--cool-50)">–</td>'; }).join('')}</tr>`).join('')}</tbody>`;
  $('hm-legenda').innerHTML = [1, 2, 3, 4, 5].map((s) => `<span><i class="sw" style="background:${HEAT[s - 1]};border:1px solid var(--cool)"></i>${s}</span>`).join('') + '<span>gemiddelde laatste score</span>';

  const aandacht = hgs.map((h) => ({ h, v: gem(leden.map((l) => gemHg(l, h)).filter((x) => x)), sterk: leden.filter((l) => gemHg(l, h) >= 3.5) })).filter((x) => x.v && x.v < 2.5).sort((a, b) => a.v - b.v);
  $('aandacht').innerHTML = aandacht.length ? aandacht.map((x) => `<div class="rij"><span><b>${esc(x.h)}</b> · gemiddeld ${komma(x.v)}<br><span class="sub">${x.sterk.length ? `Sterk: ${x.sterk.map((l) => esc(l.naam)).join(', ')} (kennis delen?)` : 'Niemand scoort hier hoog: training of kennissessie?'}</span></span><span class="chip deels">Aandacht</span></div>`).join('') : '<p class="leeg">Geen hoofdgebieden onder de 2,5. Mooi.</p>';

  const maand = dagKey(new Date()).slice(0, 7);
  $('activiteit').innerHTML = `<thead><tr><th>Naam</th><th>Plek</th><th class="r">Deze maand</th><th class="r">Reeks</th><th class="r">Goed</th><th>Laatste les</th></tr></thead><tbody>${leden.map((l) => { const t = l.logs.filter((x) => x.resultaat); return `<tr><td>${esc(l.naam)}</td><td>${esc(plekVan(l.id))}</td><td class="r num">${l.logs.filter((x) => x.datum.startsWith(maand)).length}</td><td class="r num">${reeks(l.logs)}</td><td class="r num">${t.length ? pct(t.filter((x) => x.resultaat === 'goed').length, t.length) + '%' : '–'}</td><td class="num">${l.logs[0] ? esc(fmtDatum(l.logs[0].datum)) : '–'}</td></tr>`; }).join('')}</tbody>`;
  zoekExperts();
}
function zoekExperts() {
  const q = $('expert').value.trim().toLowerCase();
  if (!q) { $('experts').innerHTML = '<p class="leeg">Typ een vaardigheid of onderwerp.</p>'; return; }
  const iedereen = teamLeden().concat(S.leden[S.mij] ? [S.leden[S.mij]] : []);
  const items = [...S.sjabloon.values()].filter((i) => `${i.vaardigheid} ${i.onderwerp} ${i.context}`.toLowerCase().includes(q)).slice(0, 12);
  const rijen = items.map((i) => ({ i, wie: iedereen.map((l) => ({ l, s: laatste(scoresVan(l, i.id))?.s || 0 })).filter((x) => x.s >= 4).sort((a, b) => b.s - a.s) })).filter((r) => r.wie.length);
  $('experts').innerHTML = rijen.length ? rijen.map((r) => `<div class="rij"><span><b>${esc(r.i.vaardigheid)}</b><br><span class="sub">${esc(r.i.onderwerp)}</span></span><span style="text-align:right">${r.wie.map((x) => `${esc(x.l.naam)} <b class="num">${Number(x.s)}</b>`).join('<br>')}</span></div>`).join('') : `<p class="leeg">Niemand in je team scoort 4 of 5 op "${esc(q)}".</p>`;
}
function toonProfiel(id) {
  const l = S.leden[id]; if (!l) return;
  const sig = signalen(l), p = $('profiel');
  const ond = [...groepeer(l)].flatMap(([hg, os]) => [...os].map(([o, its]) => ({ hg, o, v: gem(its.map((i) => laatste(i.scores)?.s)) }))).sort((a, b) => a.v - b.v);
  p.hidden = false;
  p.innerHTML = `<div class="paneel-kop"><div><h2>${esc(l.naam)}</h2><p class="sub">${esc(plekVan(id))} · ${l.logs.length} lessen · reeks ${reeks(l.logs)} · scores en resultaten, geen antwoorden</p></div><button class="knop" type="button" id="profiel-sluit" style="background:var(--cool-50)">Sluiten</button></div>
  <div class="twee"><div><h3 style="font-size:15px;margin-bottom:6px">Laagste onderwerpen</h3>${ond.slice(0, 6).map((x) => `<div class="rij"><span>${esc(x.o)}<br><span class="sub">${esc(x.hg)}</span></span><b class="num">${komma(x.v)}</b></div>`).join('')}
  <h3 style="font-size:15px;margin:16px 0 6px">Sterkste onderwerpen</h3>${ond.slice(-4).reverse().map((x) => `<div class="rij"><span>${esc(x.o)}</span><b class="num">${komma(x.v)}</b></div>`).join('')}</div>
  <div><h3 style="font-size:15px;margin-bottom:6px">Signalen</h3>${sig.length ? sig.slice(0, 6).map((x) => `<div class="rij"><span>${esc(S.sjabloon.get(x.id)?.vaardigheid || x.id)}</span>${sigChip(x.s)}</div>`).join('') : '<p class="leeg">Nog geen signalen.</p>'}
  <h3 style="font-size:15px;margin:16px 0 6px">Recente lessen</h3>${l.logs.slice(0, 6).map((x) => `<div class="rij"><span>${esc(S.lessen[x.id]?.titel || x.titel || x.id)}<br><span class="sub">${esc(fmtDatum(x.datum))}</span></span>${chip(x.resultaat)}</div>`).join('') || '<p class="leeg">Nog geen lessen.</p>'}</div></div>`;
  $('profiel-sluit').onclick = () => { p.hidden = true; };
  p.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// ---------------------------------------------------------------- kennisbank
function toonKennisbank() {
  const q = $('kb-zoek').value.trim().toLowerCase();
  const alle = Object.values(S.lessen);
  const res = alle.filter((l) => !q || [l.titel, l.kernpunt, l.onderwerp, l.vakgebied, l.bron?.titel].join(' ').toLowerCase().includes(q));
  $('kb-teller').textContent = q ? `${res.length} van ${alle.length} lessen` : `${alle.length} lessen`;
  $('kb-lijst').innerHTML = res.map((l) => `<article class="les"><div class="datum">${esc(l.niveau || 'basis')}</div><div><h3>${esc(l.titel)}</h3><div class="meta"><span class="tag">${esc(l.vakgebied)}</span>${Array.isArray(l.matrix) && l.matrix.length ? `<span class="tag" style="background:var(--smart-50)">${esc(l.matrix.join(', '))}</span>` : ''}</div>${l.kernpunt ? `<p>${esc(l.kernpunt)}</p>` : ''}${bronHtml(l.bron)}</div></article>`).join('') || `<p class="leeg">Niets gevonden voor "${esc(q)}".</p>`;
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
const lokaleTijd = (d = new Date()) => `${dagKey(d)}T${[d.getHours(), d.getMinutes(), d.getSeconds()].map((x) => String(x).padStart(2, '0')).join(':')}`;

// ---------------------------------------------------------------- aanmelden (#welkom)
// Alles gebeurt in deze browser: sleutelpaar, code van zes woorden, kluis, datasleutel, versleuteld profiel en
// skilllijst. Naar de privé-repo gaan alleen versleutelde bestanden en een aanvraag; de beheerder keurt die goed
// nadat de controlewoorden via Teams zijn vergeleken. Spiegelbeeld van Install-Nieuw in app/installeer.ps1.
const W = { id: null, uitnodiging: null, leren: 'verplicht', naam: '', matrix: null, herstel: false };
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
  if ($('w-onthoud').checked) { try { localStorage.setItem('dl-uitnodiging', uitnodiging); } catch {} }
  if (await beheerJson(`sleutels/${W.id}.json`)) { welkomStap('w-bestaand'); return; }
  const a = await json(S.data, `aanvragen/${W.id}.json`);
  if (a && a.id === W.id && a.publiek && a.kluis) {
    $('w-wacht-woorden').textContent = await K.controlewoorden(a, WOORDEN);
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
  $('w-naam').value = W.naam; $('w-naam-rij').hidden = herstel; $('w-xlsx-rij').hidden = herstel;
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
    const res = importeerSkilllijst(await leesXlsx(f), S.sjabloon, S.inst.vakgebied);
    if (!res.gekoppeld) throw new Error('Geen vaardigheden met een score (1–5) gevonden. Is dit de skilllijst?');
    W.matrix = res.matrix;
    $('w-xlsx-info').textContent = `${res.gekoppeld} van ${res.totaal} vaardigheden herkend.` + (res.nietGevonden.length ? ` ${res.nietGevonden.length} regel(s) op volgorde gekoppeld.` : '');
  } catch (e) { $('w-xlsx').value = ''; $('w-xlsx-info').textContent = ''; throw e; }
}
async function welkomMaak() {
  const naam = $('w-naam').value.trim();
  if (!W.herstel && !naam) throw new Error('Vul je naam in.');
  if (!W.herstel && W.leren === 'verplicht' && !W.matrix) throw new Error('Kies je ingevulde skilllijst (Excel).');
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
    await schrijfEnc(W.id, 'profiel', sl, { v: 1, naam, sinds: dagKey(new Date()), lessen }, W.id, teken);
    if (W.matrix) await schrijfEnc(W.id, 'matrix', sl, W.matrix, W.id, teken);
    aanvraag.toegang = { [W.id]: K.b64u.enc(await K.verpak(kp.publiek, dk)), generator: K.b64u.enc(await K.verpak(S.vertrouwd, dk)) };
  }
  await S.data.schrijf(`aanvragen/${W.id}.json`, K.tekst.naarBytes(JSON.stringify(aanvraag, null, 2)));
  $('w-code').textContent = code.replace(/-/g, ' ');
  $('w-controle').textContent = await K.controlewoorden(aanvraag, WOORDEN);
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
const TYPE = { basis: 'Basis', nieuws: 'Nieuws', herhaling: 'Herhaling' };

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
async function kiesLes() {
  const ik = S.leden[S.mij];
  if (ik.logs.some((l) => l.datum.startsWith(dagKey(new Date())))) return { klaar: true };
  const gedaan = new Set(ik.logs.map((l) => l.id));
  const w = await leesEnc(S.mij, 'wachtrij', ik.sl);
  const kandidaten = [...(Array.isArray(w?.lessen) ? w.lessen.map(String) : []), ...Object.keys(S.lessen)];
  for (const id of kandidaten) {
    if (!id || gedaan.has(id) || !/^[0-9a-z][0-9a-z-]{0,80}$/.test(id)) continue;
    const les = await json(S.app, `lessen/${id}.json`).catch(() => null);
    if (geldigeLes(les, id)) return { les };
  }
  return { leeg: true };
}

function toonLesStatus() {
  const ik = S.leden[S.mij], rk = reeks(ik.logs);
  const reeksTekst = `Reeks: ${rk} ${rk === 1 ? 'dag' : 'dagen'} · ${ik.logs.length} ${ik.logs.length === 1 ? 'les' : 'lessen'} afgerond`;
  if (L.status?.les) return startLes(L.status.les);
  $('les-kop').innerHTML = `<div class="les-meta"><span class="pill">Vandaag</span><span class="sub">${esc(reeksTekst)}</span></div>
    <h2>${L.status?.klaar ? 'Je les van vandaag is klaar' : 'Er staat nu geen nieuwe les klaar'}</h2>`;
  $('les-inhoud').innerHTML = `<p>${L.status?.klaar ? 'Goed bezig. Morgen staat er een nieuwe les voor je klaar.' : 'Je hebt alle beschikbare lessen gedaan. De generator vult ze aan; kijk morgen weer.'}</p>`;
  $('les-knoppen').innerHTML = knop('naar-mij', 'Bekijk je voortgang', 'zwart');
  $('snelkoppeling').hidden = false;
}
function startLes(les) {
  Object.assign(L, { les, keuze: -1, antwoord: '', resultaat: '', uitlegGetoond: false });
  const ik = S.leden[S.mij], rk = reeks(ik.logs);
  $('les-kop').innerHTML = `<div class="les-meta"><span class="pill">${esc(les.vakgebied || '')}${les.type ? ' · ' + esc(TYPE[les.type] || les.type) : ''}</span>
    <span class="sub">Reeks: ${rk} ${rk === 1 ? 'dag' : 'dagen'}</span></div><h2>${esc(les.titel)}</h2>`;
  $('snelkoppeling').hidden = true;
  if (les.volgorde === 'uitleg-eerst') lesUitleg(); else lesOpdracht();
}
function lesUitleg() {
  L.uitlegGetoond = true;
  $('les-inhoud').innerHTML = lesLabel('Uitleg') + tekstHtml(L.les.intro) + tekstHtml(L.les.uitleg);
  $('les-knoppen').innerHTML = knop('opdracht', 'Naar de opdracht →', 'zwart');
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
  h += kader(les.kernpunt, 'onthoud', 'Onthoud') + kader(les.toepassing, 'probeer', 'Probeer vandaag') + bronHtml(les.bron);
  if (o.soort !== 'meerkeuze') {
    h += lesLabel('Hoe ging het?') + `<div class="zelf" role="radiogroup">${[['goed', 'Wist ik goed'], ['deels', 'Deels'], ['fout', 'Wist ik niet']].map(([w, t]) => `<button type="button" class="knop" data-zelf="${w}" aria-pressed="false">${t}</button>`).join('')}</div>`;
  }
  $('les-inhoud').innerHTML = h;
  $('les-knoppen').innerHTML = knop('afronden', 'Afronden', 'zwart');
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
  if (S.leden[S.mij].matrix) toonMij();
  L.status = { klaar: true }; toonLesStatus();
}

// Snelkoppeling om DoubleLeren elke ochtend te openen (Windows: map Opstarten; Mac: Inlogonderdelen)
function downloadTekst(naam, tekst, type) {
  const url = URL.createObjectURL(new Blob([tekst], { type }));
  const a = document.createElement('a'); a.href = url; a.download = naam; document.body.append(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
const lesAdres = () => `${location.origin}${location.pathname}${LOKAAL ? location.search : ''}#vandaag`;
function downloadSnelkoppeling(mac) {
  if (mac) downloadTekst('DoubleLeren.webloc', `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>URL</key><string>${esc(lesAdres())}</string></dict></plist>\n`, 'application/xml');
  else downloadTekst('DoubleLeren.url', `[InternetShortcut]\r\nURL=${lesAdres()}\r\n`, 'application/octet-stream');
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
  if (actie === 'opdracht') lesOpdracht();
  else if (actie === 'controleer') lesAfronding();
  else if (actie === 'indienen') { L.antwoord = $('les-antwoord').value.trim(); lesAfronding(); }
  else if (actie === 'naar-mij') tab('mij');
  else if (actie === 'snel-win') downloadSnelkoppeling(false);
  else if (actie === 'snel-mac') downloadSnelkoppeling(true);
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

// ---------------------------------------------------------------- navigatie en start
function tab(naam) {
  for (const t of ['vandaag', 'mij', 'team', 'kennisbank']) $(t).hidden = t !== naam;
  document.querySelectorAll('#tabs button').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.tab === naam)));
  if (location.hash !== '#' + naam) history.replaceState(null, '', location.pathname + location.search + '#' + naam);
}
async function naInloggen() {
  $('login').hidden = true; $('voet').textContent = 'Gegevens worden ontsleuteld en gecontroleerd…';
  S.org = await beheerJson('organisatie.json');
  const geladen = await Promise.all(Object.keys(S.org.leden || {}).map((id) => laadLid(id).catch(() => null)));
  S.leden = Object.fromEntries(geladen.filter(Boolean).map((l) => [l.id, l]));
  const ik = S.leden[S.mij];
  $('wie').hidden = false; $('tabs').hidden = false;
  $('wie-naam').textContent = `Ingelogd als ${ik?.naam || S.mij}`;
  $('tab-team').hidden = teamLeden().length === 0;
  if (ik?.matrix) toonMij();
  else $('kpis').innerHTML = '<div class="kpi" style="grid-column:1/-1"><span class="label">Geen eigen skilllijst</span><span class="toel">Je hebt (nog) geen skilllijst toegevoegd. Wil je je eigen voortgang zien of lessen volgen? Neem contact op met de beheerder.</span></div>';
  if (teamLeden().length) toonTeam();
  toonKennisbank();
  const lessen = magLessen();
  $('tab-vandaag').hidden = !lessen;
  if (lessen) { L.status = await kiesLes().catch(() => ({ leeg: true })); toonLesStatus(); }
  const voorkeur = location.hash.slice(1);
  const open = lessen && L.status?.les;
  tab(voorkeur === 'kennisbank' || (voorkeur === 'team' && teamLeden().length) || (voorkeur === 'vandaag' && lessen) || (voorkeur === 'mij') ? voorkeur
    : open ? 'vandaag' : (!ik?.matrix && teamLeden().length ? 'team' : 'mij'));
  const n = Object.keys(S.leden).length;
  $('voet').textContent = `Gegevens ontsleuteld en gecontroleerd in je browser · ${n} ${n === 1 ? 'persoon' : 'personen'} zichtbaar voor jou${S.ongeldig ? ` · ${S.ongeldig} bestand(en) genegeerd: ongeldige handtekening` : ''}. Antwoorden zijn alleen zichtbaar voor de persoon zelf.`;
}

document.addEventListener('mouseover', (e) => { const t = e.target.closest('[data-tip]'), tip = $('tip'); if (!t) { tip.hidden = true; return; } tip.textContent = t.dataset.tip; tip.hidden = false; });
document.addEventListener('mousemove', (e) => { const tip = $('tip'); if (tip.hidden) return; tip.style.left = Math.min(e.clientX + 14, innerWidth - tip.offsetWidth - 8) + 'px'; tip.style.top = e.clientY + 16 + 'px'; });
$('tabs').addEventListener('click', (e) => { const b = e.target.closest('button[data-tab]'); if (b) tab(b.dataset.tab); });
$('heatmap').addEventListener('click', (e) => { const b = e.target.closest('button[data-lid]'); if (b) toonProfiel(b.dataset.lid); });
$('expert').addEventListener('input', zoekExperts);
$('kb-zoek').addEventListener('input', toonKennisbank);
$('uitloggen').addEventListener('click', () => { location.replace(location.pathname + location.search); });
$('vergeet').addEventListener('click', () => { try { localStorage.removeItem('dl-uitnodiging'); } catch {} $('uitnodiging-rij').hidden = false; $('vergeet-rij').hidden = true; });
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
    await inloggen(id, $('code').value);
    if (!$('uitnodiging-rij').hidden && $('onthoud').checked) { try { localStorage.setItem('dl-uitnodiging', uitnodiging.trim()); } catch {} }
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

laadOpenbaar().then(() => { if (location.hash === '#welkom') toonWelkom(); })
  .catch((e) => { $('login-fout').textContent = 'DoubleLeren kon niet laden: ' + e.message; });
