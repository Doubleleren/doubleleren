// Test van de portier (portier/portier.js) zonder internet: een nagebootst GitHub, een opslag in het geheugen en
// testsleutels. Draai:  node test/portier-test.mjs
import { generateKeyPairSync } from 'node:crypto';
import * as K from '../docs/krypto.js';
import portier, { Kluis } from '../portier/portier.js';

let fouten = 0;
const controleer = (ok, wat) => { if (ok) console.log(`  OK    ${wat}`); else { console.log(`  FOUT  ${wat}`); fouten++; } };

// ---------------------------------------------------------------- opslag en nep-GitHub
function opslag() {
  const m = new Map();
  return { m, async get(k) { return structuredClone(m.get(k)); }, async put(k, v) { m.set(k, structuredClone(v)); }, async delete(k) { m.delete(k); },
    async list({ prefix }) { return new Map([...m].filter(([k]) => k.startsWith(prefix))); } };
}
const bestanden = new Map();          // pad -> tekst (data-repo)
const log = [];
let tokenNr = 0;
async function nepGitHub(url, opties = {}) {
  const u = new URL(url); const m = opties.method || 'GET'; log.push(`${m} ${u.pathname}`);
  if (m === 'POST' && /\/app\/installations\/\d+\/access_tokens$/.test(u.pathname)) {
    const body = JSON.parse(opties.body);
    if (!String(opties.headers.Authorization).startsWith('Bearer ey')) return new Response('{}', { status: 401 });
    if (JSON.stringify(body.repositories) !== '["doubleleren-data-staging"]' || body.permissions.contents !== 'write') return new Response('{}', { status: 422 });
    tokenNr++; return Response.json({ token: `ghs_test${tokenNr}`, expires_at: new Date(nu + 3600e3).toISOString() });
  }
  if (m === 'DELETE' && u.pathname === '/installation/token') return new Response(null, { status: 204 });
  const p = decodeURIComponent(u.pathname.replace(/^\/repos\/Doubleleren\/doubleleren-data-staging\/contents\//, ''));
  if (!String(opties.headers?.Authorization).startsWith('Bearer ghs_test')) return new Response('{}', { status: 401 });
  if (m === 'GET') {
    if (bestanden.has(p)) return new Response(bestanden.get(p), { status: 200 });
    if ([...bestanden.keys()].some((k) => k.startsWith(`${p}/`))) return Response.json([]);      // map
    return new Response('Not Found', { status: 404 });
  }
  if (m === 'PUT') { const b = JSON.parse(opties.body); bestanden.set(p, atob(b.content)); return Response.json({ content: { sha: 'x' } }, { status: 201 }); }
  return new Response('?', { status: 400 });
}

// ---------------------------------------------------------------- testorganogram en sleutels
let nu = Date.parse('2026-11-20T10:00:00Z');
const [beheer, B, P, O, H, Pnieuw] = await Promise.all([1, 2, 3, 4, 5, 6].map(() => K.nieuwSleutelpaar(3072)));
const ids = { B: 'lid-0000b1', P: 'lid-0000d1', O: 'lid-0000d2', L: 'lid-0000e1', H: 'lid-0000a2', N: 'lid-0000e9' };
const org = {
  v: 1, vakgebied: 'seo', versie: 5, head: null, heads: { sea: ids.H }, beheerders: [ids.B],
  cellen: [{ id: 'ecom', leider: null, projecten: [{ id: 'ecom-b2b', leider: ids.P }, { id: 'lg-b2c', leider: ids.O }] }],
  leden: { [ids.B]: { naam: 'Beheer' }, [ids.P]: { naam: 'Pl', project: 'ecom-b2b' }, [ids.O]: { naam: 'Ander', project: 'lg-b2c' },
    [ids.L]: { naam: 'Lid', project: 'ecom-b2b' }, [ids.H]: { naam: 'HeadSea', vak: 'sea' }, [ids.N]: { naam: 'Nog', project: 'ecom-b2b' } }
};
async function zetBeheer(p, obj) {
  const inhoud = JSON.stringify(obj);
  bestanden.set(`beheer/${p}`, JSON.stringify({ v: 2, door: 'beheer', inhoud, sig: await K.onderteken(beheer.prive, `beheer|${p}`, 'beheer', inhoud) }));
}
await zetBeheer('organisatie.json', org);
for (const [n, kp] of [['B', B], ['P', P], ['O', O], ['H', H]]) await zetBeheer(`sleutels/${ids[n]}.json`, { v: 2, id: ids[n], publiek: kp.publiek, kluis: {} });
const appSleutel = generateKeyPairSync('rsa', { modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } }).privateKey;
const env = { APP_ID: '123', INSTALLATIE_ID: '456', APP_SLEUTEL: appSleutel, BEHEER_PUBLIEK: JSON.stringify(beheer.publiek), PORTIER_GEHEIM: 'beheergeheim-test',
  EIGENAAR: 'Doubleleren', DATA_REPO: 'doubleleren-data-staging', TOEGESTAAN: 'https://doubleleren.github.io', UITNODIGERS: 'heads-en-leiders',
  VAKKEN: JSON.stringify([{ id: 'seo' }, { id: 'sea' }, { id: 'coderen-met-ai', soort: 'onderwerp' }, { id: 'base', soort: 'groep' }]) };
const s = opslag();
const kluis = new Kluis({ storage: s }, env, { fetch: nepGitHub, nu: () => nu });
env.KLUIS = { idFromName: () => 'kluis', get: () => kluis };

const vraag = async (pad, body, kop = {}) => { const r = await portier.fetch(new Request(`https://portier.test${pad}`, { method: body === undefined ? 'GET' : 'POST', headers: { 'Content-Type': 'application/json', ...kop }, body: body === undefined ? undefined : JSON.stringify(body) }), env); return { status: r.status, j: await r.json().catch(() => null), r }; };
const beheerKop = { Authorization: 'Bearer beheergeheim-test' };
let nonceNr = 0;
async function verzoek(door, kp, context, extra, opties = {}) {
  const inhoud = JSON.stringify({ ...extra, datum: new Date(opties.datum ?? nu).toISOString(), nonce: opties.nonce || `nonce-test-${String(++nonceNr).padStart(6, '0')}` });
  return { v: 2, door, inhoud, sig: await K.onderteken(kp.prive, context, door, inhoud) };
}
const nodig = async (door, kp, id, opties) => vraag('/uitnodigen', { verzoek: await verzoek(door, kp, `uitnodiging|${id}`, { id }, opties) });
const vinger = async (kp) => [...await K.vingerafdruk(kp.publiek)].map((x) => x.toString(16).padStart(2, '0')).join('');

console.log('1. Uitnodigen: wie mag wie');
let r = await nodig(ids.P, P, ids.L);
const codeL = r.j?.code;
controleer(r.status === 200 && /^lid-0000e1:dl1_[A-Za-z0-9]{48}$/.test(codeL || ''), 'Projectleider nodigt een lid van zijn project uit: code in de vaste vorm');
controleer(![...s.m.values()].some((v) => JSON.stringify(v).includes(codeL.split(':')[1])), 'Alleen de hash van het geheim staat in de opslag');
r = await nodig(ids.O, O, ids.L); controleer(r.status === 403, 'Projectleider van een ander project: geweigerd');
r = await nodig(ids.P, P, ids.H); controleer(r.status === 403, 'Projectleider nodigt geen head uit');
r = await nodig(ids.B, B, ids.H); controleer(r.status === 200, 'De beheerder nodigt een head uit');
r = await vraag('/uitnodigen', { verzoek: { ...(await verzoek(ids.O, O, `uitnodiging|${ids.L}`, { id: ids.L })), door: ids.P } });
controleer(r.status === 403, 'Vervalste handtekening (ondertekend door een ander): geweigerd');
r = await vraag('/uitnodigen', { verzoek: await verzoek('generator', P, `uitnodiging|${ids.L}`, { id: ids.L }) }); controleer(r.status === 403, 'De generator kan niet uitnodigen');
r = await nodig(ids.P, P, ids.L, { datum: nu - 11 * 60e3 }); controleer(r.status === 400, 'Te oud verzoek: geweigerd');
await nodig(ids.P, P, ids.N, { nonce: 'nonce-herhaling-0001' });
r = await nodig(ids.P, P, ids.N, { nonce: 'nonce-herhaling-0001' }); controleer(r.status === 409, 'Hetzelfde verzoek opnieuw (nonce): geweigerd');
// Een oude sleutel (van vóór "code kwijt") telt niet meer
await zetBeheer(`sleutels/${ids.P}.json`, { v: 2, id: ids.P, publiek: Pnieuw.publiek, eerdere: [P.publiek], kluis: {} });
r = await nodig(ids.P, P, ids.L); controleer(r.status === 403, "Ondertekend met een 'eerdere' sleutel: geweigerd");
await zetBeheer(`sleutels/${ids.P}.json`, { v: 2, id: ids.P, publiek: P.publiek, kluis: {} });
env.UITNODIGERS = 'beheerders'; r = await nodig(ids.P, P, ids.L); controleer(r.status === 403, 'Schakelaar "beheerders": projectleider mag (nog) niet');
env.UITNODIGERS = JSON.stringify([ids.P]); r = await nodig(ids.P, P, ids.L); controleer(r.status === 200, 'Schakelaar met proeflijst: deze projectleider mag wel');
const codeL2 = r.j.code;
env.UITNODIGERS = 'heads-en-leiders';
r = await vraag('/token', { id: ids.L, geheim: codeL.split(':')[1] }); controleer(r.status === 403, 'Een nieuwe uitnodiging maakt de oude ongeldig (nog niet goedgekeurd)');

console.log('2. Organogramversie');
await s.put('orgversie', 9); r = await nodig(ids.P, P, ids.N); controleer(r.status === 409, 'Ouder organogram dan de portier ooit zag: geweigerd');
await s.put('orgversie', 5);
r = await vraag('/orgversie', { versie: 7 }, beheerKop); r = await vraag('/orgversie', { versie: 3 }, beheerKop); controleer(r.j?.orgversie === 7, '/orgversie verhoogt, maar verlaagt nooit');
await s.put('orgversie', 5);

console.log('3. Token en aanmelden');
const [id2, geheim2] = codeL2.split(':');
r = await vraag('/token', { id: id2, geheim: geheim2 }); controleer(r.status === 200 && r.j.token === 'ghs_test1', 'Met de code een installatietoken (alleen de data-repo, Contents: write)');
r = await vraag('/token', { id: id2, geheim: geheim2 }); controleer(r.j?.token === 'ghs_test1' && tokenNr === 1, 'Het token wordt hergebruikt tot 10 minuten voor het verloopt');
nu += 55 * 60e3; r = await vraag('/token', { id: id2, geheim: geheim2 }); controleer(r.j?.token === 'ghs_test2', 'Daarna haalt de portier een nieuw token'); nu -= 55 * 60e3;
const kpL = await K.nieuwSleutelpaar(3072), kpL2 = await K.nieuwSleutelpaar(3072);
r = await vraag('/aanmelden', { id: id2, geheim: geheim2, vingerafdruk: await vinger(kpL) }); controleer(r.status === 200, 'Aanmelden legt de vingerafdruk vast');
r = await vraag('/aanmelden', { id: id2, geheim: geheim2, vingerafdruk: await vinger(kpL2) });
let st = await vraag('/stand', undefined, beheerKop);
controleer(r.status === 200 && st.j.bindingen[id2] === await vinger(kpL2), 'Opnieuw aanmelden vóór goedkeuring: de laatste telt');
r = await vraag('/afgehandeld', { id: id2, soort: 'goedgekeurd' }, beheerKop);
st = await vraag('/stand', undefined, beheerKop);
r = await vraag('/aanmelden', { id: id2, geheim: geheim2, vingerafdruk: await vinger(kpL) });
controleer(r.status === 409 && !st.j.bindingen[id2], 'Na goedkeuring: geen binding meer in de stand, opnieuw aanmelden geweigerd');
r = await nodig(ids.P, P, ids.L); const codeExtra = r.j?.code;
r = await vraag('/token', { id: id2, geheim: geheim2 }); const r2 = await vraag('/token', { id: id2, geheim: codeExtra.split(':')[1] });
controleer(r.status === 200 && r2.status === 200, 'Goedgekeurd lid krijgt een extra code; de oude blijft werken');
r = await vraag('/token', { id: ids.H, geheim: 'dl1_' + 'x'.repeat(48) }); controleer(r.status === 403, 'Fout geheim: geweigerd');
for (let i = 0; i < 20; i++) await vraag('/token', { id: ids.N, geheim: 'dl1_' + 'y'.repeat(48) }, { 'CF-Connecting-IP': '1.2.3.4' });
r = await vraag('/token', { id: ids.N, geheim: 'dl1_' + 'y'.repeat(48) }, { 'CF-Connecting-IP': '1.2.3.4' });
const r3 = await vraag('/token', { id: ids.N, geheim: 'dl1_' + 'y'.repeat(48) }, { 'CF-Connecting-IP': '5.6.7.8' });
controleer(r.status === 429 && r3.status === 403, 'Na 20 foute pogingen: even geblokkeerd, maar alleen vanaf dat adres');
// Verlopen uitnodiging
r = await nodig(ids.B, B, ids.N); const [idN, gN] = r.j.code.split(':');
nu += 15 * 24 * 3600e3; r = await vraag('/token', { id: idN, geheim: gN }); controleer(r.status === 403, 'Ongebruikte uitnodiging verloopt na 14 dagen'); nu -= 15 * 24 * 3600e3;

console.log('4. Nieuwe collega');
const nieuwVerzoek = (door, kp, gegevens, opties) => verzoek(door, kp, 'nieuw', gegevens, opties).then((v) => vraag('/nieuw', { verzoek: v }));
r = await nieuwVerzoek(ids.P, P, { naam: 'Nieuwe Collega', project: 'ecom-b2b', vak: 'seo' });
const nieuwId = r.j?.id;
st = await vraag('/stand', undefined, beheerKop);
controleer(r.status === 200 && /^lid-[0-9a-f]{6}$/.test(nieuwId) && r.j.code.startsWith(`${nieuwId}:dl1_`) && st.j.nieuw[nieuwId]?.lid?.naam === 'Nieuwe Collega' && bestanden.has(`uitnodigingen/${nieuwId}.json`), 'Projectleider voegt iemand toe in zijn project: id, code, seintje en stand');
r = await nieuwVerzoek(ids.P, P, { naam: 'Elders', project: 'lg-b2c', vak: 'seo' }); controleer(r.status === 403, 'Projectleider in een ander project: geweigerd');
r = await nieuwVerzoek(ids.H, H, { naam: 'Sea Collega', project: 'lg-b2c', vak: 'sea' }); controleer(r.status === 200, 'Head SEA voegt een SEA-collega toe');
r = await nieuwVerzoek(ids.H, H, { naam: 'Geen Sea', project: 'lg-b2c', vak: 'seo' }); controleer(r.status === 403, 'Head SEA voegt geen SEO-collega toe');
r = await nieuwVerzoek(ids.P, P, { naam: 'Onderwerp', project: 'ecom-b2b', vak: 'coderen-met-ai' }); controleer(r.status === 400, 'Een onderwerp is geen vak: geweigerd');
r = await nieuwVerzoek(ids.P, P, { naam: 'X', project: 'ecom-b2b', vak: 'seo' }); controleer(r.status === 400, 'Te korte naam: geweigerd');
r = await nieuwVerzoek(ids.B, B, { naam: 'Onbekend', project: 'bestaat-niet', vak: 'seo' }); controleer(r.status === 400, 'Onbekend project: geweigerd');
r = await vraag('/afgehandeld', { id: nieuwId, soort: 'nieuw' }, beheerKop); st = await vraag('/stand', undefined, beheerKop);
controleer(!st.j.nieuw[nieuwId], '/afgehandeld haalt het verzoek uit de stand');

console.log('5. Beheer en intrekken');
r = await vraag('/stand'); controleer(r.status === 401, '/stand zonder beheergeheim: geweigerd');
r = await vraag('/intrekken', { id: id2 }, { Authorization: 'Bearer fout' }); controleer(r.status === 401, '/intrekken zonder beheergeheim: geweigerd');
r = await vraag('/intrekken', { id: id2 }, beheerKop);
const na = await vraag('/token', { id: id2, geheim: geheim2 });
controleer(r.status === 200 && na.status === 403 && log.includes('DELETE /installation/token'), 'Intrekken: de code werkt niet meer en het gedeelde token is ingetrokken');

console.log('6. CORS');
let c = await portier.fetch(new Request('https://portier.test/token', { method: 'OPTIONS', headers: { Origin: 'https://doubleleren.github.io' } }), env);
const c2 = await portier.fetch(new Request('https://portier.test/token', { method: 'OPTIONS', headers: { Origin: 'https://kwaad.example' } }), env);
controleer(c.headers.get('Access-Control-Allow-Origin') === 'https://doubleleren.github.io' && !c2.headers.get('Access-Control-Allow-Origin'), 'Alleen de eigen site mag de portier vanuit de browser aanroepen');

console.log(fouten ? `\n${fouten} fout(en)` : '\nPortiertest geslaagd');
process.exit(fouten ? 1 : 0);
