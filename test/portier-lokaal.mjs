// De echte portier (portier/portier.js) lokaal, voor de e2e-test en een preview: zelfde code, maar met een opslag in het
// geheugen en een nagebootst GitHub dat de testdata uit een map leest en schrijft. Nooit tegen echte data.
//   node test/portier-lokaal.mjs --poort 8790 --werk %TEMP%\doubleleren-e2e [--doel http://localhost:8768] [--geheim x]
// /portier/... gaat naar de portier; met --doel gaat al het andere door naar die (statische) testserver, zodat de site en
// de portier op hetzelfde adres staan (de site gebruikt dan "portier": "/portier" in instellingen.json).
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync } from 'node:fs';
import { join, dirname, resolve, sep } from 'node:path';
import { generateKeyPairSync } from 'node:crypto';
import portier, { Kluis } from '../portier/portier.js';

const arg = (n, std) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : std; };
const poort = Number(arg('poort', '8790')), werk = resolve(arg('werk', '.')), doel = arg('doel', ''), geheim = arg('geheim', 'lokaal-beheergeheim');
const data = join(werk, 'data');
const lees = (p) => JSON.parse(readFileSync(p, 'utf8').replace(/^﻿/, ''));
const inst = lees(join(werk, 'app', 'instellingen.json'));
const vertrouwd = lees(join(werk, 'app', 'vertrouwd.json')).beheer;

// Alleen paden binnen de testmap
const veilig = (p) => { const f = resolve(data, p); if (f !== data && !f.startsWith(data + sep)) throw new Error('pad buiten de testmap'); return f; };
async function nepGitHub(url, opties = {}) {
  const u = new URL(url), m = opties.method || 'GET';
  if (m === 'POST' && u.pathname.endsWith('/access_tokens')) return Response.json({ token: 'ghs_lokaal', expires_at: new Date(Date.now() + 3600e3).toISOString() });
  if (m === 'DELETE' && u.pathname === '/installation/token') return new Response(null, { status: 204 });
  const p = decodeURIComponent(u.pathname.replace(/^\/repos\/[^/]+\/[^/]+\/contents\//, ''));
  const f = veilig(p);
  if (m === 'GET') {
    if (!existsSync(f)) return new Response('Not Found', { status: 404 });
    if (statSync(f).isDirectory()) return Response.json([]);
    return new Response(readFileSync(f), { status: 200 });
  }
  if (m === 'PUT') { const b = JSON.parse(opties.body); mkdirSync(dirname(f), { recursive: true }); writeFileSync(f, Buffer.from(b.content, 'base64')); return Response.json({ content: { sha: 'lokaal' } }, { status: 201 }); }
  return new Response('?', { status: 400 });
}
const opslag = new Map();
const s = { async get(k) { return structuredClone(opslag.get(k)); }, async put(k, v) { opslag.set(k, structuredClone(v)); }, async delete(k) { opslag.delete(k); },
  async list({ prefix }) { return new Map([...opslag].filter(([k]) => k.startsWith(prefix))); } };
const env = {
  APP_ID: '1', INSTALLATIE_ID: '1', APP_SLEUTEL: generateKeyPairSync('rsa', { modulusLength: 2048, privateKeyEncoding: { type: 'pkcs8', format: 'pem' }, publicKeyEncoding: { type: 'spki', format: 'pem' } }).privateKey,
  BEHEER_PUBLIEK: JSON.stringify(vertrouwd), PORTIER_GEHEIM: geheim, EIGENAAR: 'lokaal', DATA_REPO: 'testdata', TOEGESTAAN: `http://localhost:${poort}`,
  UITNODIGERS: Array.isArray(inst.uitnodigers) ? JSON.stringify(inst.uitnodigers) : String(inst.uitnodigers || 'heads-en-leiders'),
  VAKKEN: JSON.stringify((inst.vakken || [{ id: inst.vakgebied }]).map((v) => ({ id: v.id, soort: v.soort })))
};
const kluis = new Kluis({ storage: s }, env, { fetch: nepGitHub });
env.KLUIS = { idFromName: () => 'kluis', get: () => kluis };

http.createServer(async (req, res) => {
  try {
    if (req.url.startsWith('/portier/')) {
      const delen = []; for await (const c of req) delen.push(c);
      const r = await portier.fetch(new Request(`http://localhost:${poort}${req.url.slice(8)}`, { method: req.method, headers: req.headers, body: ['GET', 'HEAD', 'OPTIONS'].includes(req.method) ? undefined : Buffer.concat(delen) }), env);
      res.writeHead(r.status, Object.fromEntries(r.headers)); res.end(Buffer.from(await r.arrayBuffer())); return;
    }
    if (!doel) { res.writeHead(404); res.end(); return; }
    const d = new URL(doel);
    const p = http.request({ host: d.hostname, port: d.port, path: req.url, method: req.method, headers: req.headers }, (r) => { res.writeHead(r.statusCode, r.headers); r.pipe(res); });
    p.on('error', () => { res.writeHead(502); res.end(); }); req.pipe(p);
  } catch (e) { res.writeHead(500); res.end(String(e.message)); }
}).listen(poort, () => console.log(`portier lokaal klaar op http://localhost:${poort}/portier`));
