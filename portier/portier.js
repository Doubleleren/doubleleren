// DoubleLeren-portier (Cloudflare Worker + Durable Object). Deelt namens de GitHub App "DoubleLeren portier" toegang tot
// de data-repo uit, zodat de beheerder geen persoonlijke tokens meer hoeft te maken, en onthoudt wie door wie is
// uitgenodigd. Zie Leren\plannen\goedkeuren-in-de-cloud.md, deel 2 (D en E).
//
// Uitnodigingscode: lid-xxxxxx:dl1_<48 tekens>. Alleen de hash van het geheim staat hier. Met het geheim krijg je via
// /token een installatietoken van de app (alleen de data-repo, Contents: write, een uur geldig). Bij /aanmelden legt de
// site of pop-up de vingerafdruk van de nieuwe sleutel vast: de cloud keurt een uitgenodigd lid alleen goed als de
// aanvraag die sleutel heeft. Zo kan iemand met alleen een token zich niet voor een ander aanmelden.
//
// Wie mag uitnodigen: docs/regels.js (zelfde regels als app/lib/organisatie.ps1), plus de schakelaar UITNODIGERS:
//   "beheerders" (alleen beheerders), een JSON-lijst met ids (proef, plus beheerders), of "heads-en-leiders".
// Alles wat de portier leest uit de data-repo (organogram, sleutels) controleert hij met de publieke beheersleutel.
//
// Omgeving (wrangler.toml en secrets): APP_ID, INSTALLATIE_ID, APP_SLEUTEL (PKCS#8 PEM), BEHEER_PUBLIEK (JWK),
// PORTIER_GEHEIM, EIGENAAR, DATA_REPO, TOEGESTAAN (origin van de site), UITNODIGERS, VAKKEN (JSON), KLUIS (Durable Object).
import * as K from '../docs/krypto.js';
import * as R from '../docs/regels.js';

const GEHEIM_VORM = /^dl1_[A-Za-z0-9]{48}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const DAG = 24 * 3600 * 1000;
const GELDIG = 14 * DAG;              // een uitnodiging die nog niet gebruikt is, verloopt na 14 dagen
const VERZOEK_MAX_OUD = 10 * 60 * 1000;
const NAAM_VORM = /^[^\u0000-\u001f<>"\\]{2,60}$/;

class Fout extends Error { constructor(status, tekst) { super(tekst); this.status = status; } }
const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
const sha256 = async (s) => hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
const vingerafdrukHex = async (pub) => hex(await K.vingerafdruk(pub));
function nieuwGeheim() {
  const tekens = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  const r = crypto.getRandomValues(new Uint8Array(64)); let s = '';
  for (const x of r) { if (x < 248) s += tekens[x % 62]; if (s.length === 48) break; }      // 248 = 4 × 62: geen voorkeur
  if (s.length < 48) return nieuwGeheim();
  return `dl1_${s}`;
}
const nieuwId = () => `lid-${hex(crypto.getRandomValues(new Uint8Array(3)))}`;

// Worker: alles naar één Durable Object, zodat alles in één volgorde en overal meteen gelijk is
export default {
  async fetch(request, env) {
    const kop = cors(env, request);
    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: kop });
    const kluis = env.KLUIS.get(env.KLUIS.idFromName('kluis'));
    const r = await kluis.fetch(request);
    const h = new Headers(r.headers); for (const [k, v] of Object.entries(kop)) h.set(k, v);
    return new Response(r.body, { status: r.status, headers: h });
  }
};
function cors(env, request) {
  const o = request.headers.get('Origin');
  return o && o === env.TOEGESTAAN
    ? { 'Access-Control-Allow-Origin': o, 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '600', Vary: 'Origin' }
    : {};
}
const antwoord = (status, obj) => new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' } });

export class Kluis {
  constructor(state, env, opties = {}) { this.s = state.storage; this.env = env; this.fetchGitHub = opties.fetch || ((...a) => fetch(...a)); this.nu = opties.nu || (() => Date.now()); }

  async fetch(request) {
    try {
      const pad = new URL(request.url).pathname;
      if (request.method !== 'POST' && !(request.method === 'GET' && pad === '/stand')) throw new Fout(405, 'Alleen POST');
      const body = request.method === 'POST' ? await request.json().catch(() => { throw new Fout(400, 'Geen geldige JSON'); }) : {};
      const ip = request.headers.get('CF-Connecting-IP') || 'onbekend';
      const beheer = () => { if (!this.env.PORTIER_GEHEIM || request.headers.get('Authorization') !== `Bearer ${this.env.PORTIER_GEHEIM}`) throw new Fout(401, 'Geen toegang'); };
      switch (pad) {
        case '/token': return antwoord(200, await this.token(body, ip));
        case '/uitnodigen': return antwoord(200, await this.uitnodigen(body));
        case '/nieuw': return antwoord(200, await this.nieuw(body));
        case '/aanmelden': return antwoord(200, await this.aanmelden(body, ip));
        case '/stand': beheer(); return antwoord(200, await this.stand());
        case '/afgehandeld': beheer(); return antwoord(200, await this.afgehandeld(body));
        case '/orgversie': beheer(); return antwoord(200, await this.orgversie(body));
        case '/intrekken': beheer(); return antwoord(200, await this.intrekken(body));
        default: throw new Fout(404, 'Onbekend');
      }
    } catch (e) {
      if (e instanceof Fout) return antwoord(e.status, { fout: e.message });
      console.log(`portier: fout ${e?.message}`);       // nooit geheimen of tokens loggen
      return antwoord(500, { fout: 'Er ging iets mis bij de portier' });
    }
  }

  // ---------------------------------------------------------------- GitHub (namens de app)
  async appJwt() {
    const pem = String(this.env.APP_SLEUTEL || '').replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
    const sleutel = await crypto.subtle.importKey('pkcs8', K.b64u.dec(pem.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')), { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
    const b = (o) => K.b64u.enc(new TextEncoder().encode(JSON.stringify(o)));
    const t = Math.floor(this.nu() / 1000);
    const deel = `${b({ alg: 'RS256', typ: 'JWT' })}.${b({ iat: t - 60, exp: t + 540, iss: String(this.env.APP_ID) })}`;
    return `${deel}.${K.b64u.enc(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', sleutel, new TextEncoder().encode(deel)))}`;
  }
  // Eén installatietoken voor iedereen (alleen de data-repo, Contents: write); vernieuwd 10 minuten voor het verloopt
  async installatieToken() {
    const t = await this.s.get('token');
    if (t && Date.parse(t.verloopt) - this.nu() > 10 * 60 * 1000) return t;
    const r = await this.fetchGitHub(`https://api.github.com/app/installations/${this.env.INSTALLATIE_ID}/access_tokens`, {
      method: 'POST', headers: { Authorization: `Bearer ${await this.appJwt()}`, Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'doubleleren-portier' },
      body: JSON.stringify({ repositories: [this.env.DATA_REPO], permissions: { contents: 'write' } })
    });
    if (!r.ok) throw new Error(`installatietoken: ${r.status}`);
    const j = await r.json(); const nieuw = { token: j.token, verloopt: j.expires_at };
    await this.s.put('token', nieuw);
    return nieuw;
  }
  async gh(pad, opties = {}) {
    const { token } = await this.installatieToken();
    return this.fetchGitHub(`https://api.github.com/repos/${this.env.EIGENAAR}/${this.env.DATA_REPO}/contents/${pad}${opties.method ? '' : `?t=${this.nu()}`}`, {
      ...opties, headers: { Authorization: `Bearer ${token}`, Accept: opties.method ? 'application/vnd.github+json' : 'application/vnd.github.raw+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'doubleleren-portier', ...(opties.headers || {}) }
    });
  }
  async bestaat(pad) { const r = await this.gh(pad); if (r.status === 404) return false; if (!r.ok) throw new Error(`${pad}: ${r.status}`); return true; }
  // Beheerbestand lezen en de handtekening van de beheersleutel controleren (zelfde regel als beheerJson op de site)
  async beheerJson(p) {
    const r = await this.gh(`beheer/${p}`);
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`beheer/${p}: ${r.status}`);
    const env = JSON.parse(await r.text());
    if (env.v !== 2 || env.door !== 'beheer' || typeof env.inhoud !== 'string' || !(await K.verifieer(this.beheerPubliek(), `beheer|${p}`, 'beheer', env.inhoud, env.sig)))
      throw new Fout(409, `Beheerbestand ${p} heeft geen geldige handtekening`);
    return JSON.parse(env.inhoud);
  }
  beheerPubliek() { const j = typeof this.env.BEHEER_PUBLIEK === 'string' ? JSON.parse(this.env.BEHEER_PUBLIEK) : this.env.BEHEER_PUBLIEK; if (!K.sleutelVorm(j)) throw new Error('BEHEER_PUBLIEK ontbreekt'); return j; }
  // Organogram met versiecontrole: nooit een ouder organogram dan het hoogste dat de portier zag
  async organogram() {
    const org = await this.beheerJson('organisatie.json'); if (!org) throw new Fout(409, 'Geen organogram');
    const v = Number(org.versie || 0), hoogste = Number((await this.s.get('orgversie')) || 0);
    if (v < hoogste) throw new Fout(409, `Het organogram is teruggezet naar een oudere versie (${v} < ${hoogste})`);
    if (v > hoogste) await this.s.put('orgversie', v);
    return org;
  }

  // ---------------------------------------------------------------- uitnodigen
  // Verzoek van de site: envelop { v: 2, door, inhoud, sig } met de eigen sleutel van 'door' ondertekend
  async controleerVerzoek(verzoek, context, org) {
    if (!verzoek || verzoek.v !== 2 || typeof verzoek.inhoud !== 'string' || typeof verzoek.sig !== 'string') throw new Fout(400, 'Ongeldig verzoek');
    const door = String(verzoek.door);
    if (!R.ID_VORM.test(door) || !org.leden?.[door]) throw new Fout(403, 'Onbekende afzender');
    const s = await this.beheerJson(`sleutels/${door}.json`);
    if (!s?.publiek || !K.sleutelVorm(s.publiek)) throw new Fout(403, 'Afzender is nog niet goedgekeurd');
    // Alleen de huidige sleutel (niet 'eerdere'): een sleutel van vóór "code kwijt" telt niet meer
    if (!(await K.verifieer(s.publiek, context, door, verzoek.inhoud, verzoek.sig))) throw new Fout(403, 'Handtekening klopt niet');
    let inhoud; try { inhoud = JSON.parse(verzoek.inhoud); } catch { throw new Fout(400, 'Ongeldige inhoud'); }
    const t = Date.parse(inhoud.datum);
    if (!Number.isFinite(t) || Math.abs(this.nu() - t) > VERZOEK_MAX_OUD) throw new Fout(400, 'Verzoek is te oud: probeer het opnieuw');
    if (!/^[A-Za-z0-9_-]{16,64}$/.test(String(inhoud.nonce))) throw new Fout(400, 'Ongeldig verzoek');
    if (await this.s.get(`nonce:${inhoud.nonce}`)) throw new Fout(409, 'Dit verzoek is al gebruikt');
    await this.s.put(`nonce:${inhoud.nonce}`, this.nu());
    await this.opruimen();
    return { door, inhoud };
  }
  magVanSchakelaar(org, door) {
    if (R.isBeheerder(org, door)) return true;
    const u = String(this.env.UITNODIGERS || 'beheerders');
    if (u === 'heads-en-leiders') return true;
    if (u.startsWith('[')) { try { return JSON.parse(u).includes(door); } catch { return false; } }
    return false;
  }
  async geefCode(id, door, goedgekeurd) {
    const geheim = nieuwGeheim(), hash = await sha256(geheim);
    const oud = await this.s.get(`uitn:${id}`);
    const record = goedgekeurd
      // Al goedgekeurd (code kwijt, tweede laptop): een extra code erbij; de bestaande blijft werken
      ? { ...(oud || {}), door, goedgekeurd: true, geheimHashes: [...(oud?.geheimHashes || []), hash].slice(-5) }
      // Nog niet goedgekeurd: een nieuwe uitnodiging vervangt de oude (en de binding)
      : { door, datum: new Date(this.nu()).toISOString(), geldigTot: this.nu() + GELDIG, geheimHashes: [hash], vingerafdruk: null, goedgekeurd: false };
    await this.s.put(`uitn:${id}`, record);
    return `${id}:${geheim}`;
  }
  async uitnodigen({ verzoek }) {
    const org = await this.organogram();
    let id; try { id = JSON.parse(verzoek?.inhoud || '{}').id; } catch { throw new Fout(400, 'Ongeldige inhoud'); }
    if (!R.ID_VORM.test(String(id))) throw new Fout(400, 'Ongeldig id');
    const { door } = await this.controleerVerzoek(verzoek, `uitnodiging|${id}`, org);
    if (!this.magVanSchakelaar(org, door) || !R.magUitnodigen(org, door, id)) throw new Fout(403, 'Je mag deze collega niet uitnodigen');
    const goedgekeurd = !!org.leden[id]?.goedgekeurd || !!(await this.s.get(`uitn:${id}`))?.goedgekeurd;
    return { code: await this.geefCode(id, door, goedgekeurd), goedgekeurd };
  }
  async nieuw({ verzoek }) {
    const org = await this.organogram();
    const { door, inhoud } = await this.controleerVerzoek(verzoek, 'nieuw', org);
    const naam = String(inhoud.naam || '').trim();
    if (!NAAM_VORM.test(naam)) throw new Fout(400, 'Vul een naam in van 2 tot 60 tekens');
    const vakken = JSON.parse(this.env.VAKKEN || '[]');
    const vak = inhoud.vak ? String(inhoud.vak) : String(org.vakgebied);
    const v = vakken.find((x) => x.id === vak);
    if (!v || v.soort === 'onderwerp') throw new Fout(400, 'Onbekend vak');
    const plek = inhoud.project ? { project: String(inhoud.project) } : inhoud.cel ? { cel: String(inhoud.cel) } : null;
    const cellen = Array.isArray(org.cellen) ? org.cellen : [];
    if (plek?.project && !cellen.some((c) => (c.projecten || []).some((p) => p.id === plek.project))) throw new Fout(400, 'Onbekend project');
    if (plek?.cel && !cellen.some((c) => c.id === plek.cel)) throw new Fout(400, 'Onbekende cel');
    if (!this.magVanSchakelaar(org, door) || !R.magToevoegen(org, door, plek, vak)) throw new Fout(403, 'Je mag op deze plek geen collega toevoegen');
    // Een echt vrij id: niet in het organogram, niet in een lopende uitnodiging, en geen restanten in de data-repo
    let id = null;
    for (let i = 0; i < 6 && !id; i++) {
      const k = nieuwId();
      if (org.leden?.[k] || (await this.s.get(`uitn:${k}`)) || (await this.s.get(`nieuw:${k}`))) continue;
      if ((await this.bestaat(`beheer/sleutels/${k}.json`)) || (await this.bestaat(`beheer/toegang/${k}.json`)) || (await this.bestaat(`aanvragen/${k}.json`)) || (await this.bestaat(`data/${k}`))) continue;
      id = k;
    }
    if (!id) throw new Error('geen vrij id');
    const lid = { naam, ...(plek || {}), ...(vak !== org.vakgebied ? { vak } : {}), ...(inhoud.leren === 'optioneel' ? { leren: 'optioneel' } : {}) };
    await this.s.put(`nieuw:${id}`, { lid, door, datum: new Date(this.nu()).toISOString() });
    const code = await this.geefCode(id, door, false);
    // Seintje voor de cloud (de inhoud wordt nooit vertrouwd: de cloud vraagt de gegevens hier op via /stand)
    const r = await this.gh(`uitnodigingen/${id}.json`, { method: 'PUT', body: JSON.stringify({ message: 'sync', branch: 'main', committer: { name: 'doubleleren', email: 'sync@doubleleren.invalid' }, content: btoa(JSON.stringify({ id })) }) });
    if (!r.ok) console.log(`portier: seintje niet gezet (${r.status}); het vangnet pakt het op`);
    return { code, id };
  }

  // ---------------------------------------------------------------- inloggen en aanmelden
  // Foute pogingen tellen per lid én netwerkadres: zo kan niemand een collega buitensluiten met expres foute codes
  async metGeheim(id, geheim, ip) {
    if (!R.ID_VORM.test(String(id)) || !GEHEIM_VORM.test(String(geheim))) throw new Fout(400, 'Ongeldige code');
    const sleutel = `fout:${id}:${ip}`;
    const fouten = (await this.s.get(sleutel)) || { n: 0, t: 0 };
    if (fouten.n >= 20 && this.nu() - fouten.t < 3600 * 1000) throw new Fout(429, 'Te vaak een verkeerde code: probeer het over een uur opnieuw');
    const u = await this.s.get(`uitn:${id}`);
    const hash = await sha256(geheim);
    if (!u || !(u.geheimHashes || []).includes(hash)) { await this.s.put(sleutel, { n: fouten.n + 1, t: this.nu() }); throw new Fout(403, 'Deze uitnodigingscode klopt niet (meer)'); }
    if (!u.goedgekeurd && this.nu() > u.geldigTot) throw new Fout(403, 'Deze uitnodiging is verlopen: vraag om een nieuwe');
    return u;
  }
  async token({ id, geheim }, ip) {
    await this.metGeheim(id, geheim, ip);
    const t = await this.installatieToken();
    return { token: t.token, verloopt: t.verloopt };
  }
  async aanmelden({ id, geheim, vingerafdruk }, ip) {
    const u = await this.metGeheim(id, geheim, ip);
    if (u.goedgekeurd) throw new Fout(409, 'Je bent al aangemeld');
    if (!HEX64.test(String(vingerafdruk))) throw new Fout(400, 'Ongeldige sleutel');
    // Zolang er niet is goedgekeurd, telt de laatste aanmelding (iemand die halverwege stopte, kan opnieuw beginnen)
    await this.s.put(`uitn:${id}`, { ...u, vingerafdruk: String(vingerafdruk), aangemeld: new Date(this.nu()).toISOString() });
    return { ok: true };
  }

  // ---------------------------------------------------------------- voor de cloud (met PORTIER_GEHEIM)
  async stand() {
    const nieuw = {}, bindingen = {};
    for (const [k, v] of await this.s.list({ prefix: 'nieuw:' })) nieuw[k.slice(6)] = v;
    for (const [k, v] of await this.s.list({ prefix: 'uitn:' })) if (!v.goedgekeurd && v.vingerafdruk) bindingen[k.slice(5)] = v.vingerafdruk;
    return { orgversie: Number((await this.s.get('orgversie')) || 0), nieuw, bindingen };
  }
  async afgehandeld({ id, soort }) {
    if (!R.ID_VORM.test(String(id))) throw new Fout(400, 'Ongeldig id');
    if (soort === 'nieuw') await this.s.delete(`nieuw:${id}`);
    else if (soort === 'goedgekeurd') { const u = await this.s.get(`uitn:${id}`); if (u) await this.s.put(`uitn:${id}`, { ...u, goedgekeurd: true }); }
    else throw new Fout(400, 'Onbekende soort');
    return { ok: true };
  }
  async orgversie({ versie }) {
    const v = Number(versie); if (!Number.isInteger(v) || v < 0) throw new Fout(400, 'Ongeldige versie');
    const h = Number((await this.s.get('orgversie')) || 0);
    if (v > h) await this.s.put('orgversie', v);          // nooit verlagen
    return { orgversie: Math.max(v, h) };
  }
  async intrekken({ id }) {
    if (!R.ID_VORM.test(String(id))) throw new Fout(400, 'Ongeldig id');
    await this.s.delete(`uitn:${id}`); await this.s.delete(`nieuw:${id}`);
    // Het gedeelde token meteen intrekken: iedereen haalt dan een nieuw token, behalve wie is ingetrokken
    const t = await this.s.get('token');
    if (t) {
      await this.fetchGitHub('https://api.github.com/installation/token', { method: 'DELETE', headers: { Authorization: `Bearer ${t.token}`, Accept: 'application/vnd.github+json', 'User-Agent': 'doubleleren-portier' } }).catch(() => {});
      await this.s.delete('token');
    }
    return { ok: true };
  }
  // Oude nonces en foutentellers weg (een dag na gebruik)
  async opruimen() {
    const grens = this.nu() - DAG;
    for (const [k, v] of await this.s.list({ prefix: 'nonce:' })) if (v < grens) await this.s.delete(k);
    for (const [k, v] of await this.s.list({ prefix: 'fout:' })) if (v.t < grens) await this.s.delete(k);
  }
}
