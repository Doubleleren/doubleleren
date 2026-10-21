// Node-kant van de kruistest: controleert ps-vectoren.json met docs/krypto.js (WebCrypto) en maakt node-vectoren.json.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as K from '../docs/krypto.js';
import { WOORDEN } from '../docs/woorden.js';

const map = process.argv[2];
const ps = JSON.parse(readFileSync(join(map, 'ps-vectoren.json'), 'utf8'));
let fouten = 0;
const controleer = (ok, wat) => { console.log(`  ${ok ? 'OK  ' : 'FOUT'}  ${wat}`); if (!ok) fouten++; };
const hex = (b) => Buffer.from(b).toString('hex');
const gelijk = (a, b) => hex(a) === hex(b);
const weigert = async (fn) => { try { await fn(); return false; } catch { return true; } };

const salt = K.b64u.dec(ps.salt);
controleer(hex(await K.pbkdf2(ps.code, salt, 1000, 64)) === ps.pbkdf2_1000, 'PBKDF2 (1000 rondes) gelijk aan PowerShell');
let t0 = performance.now();
controleer(hex(await K.pbkdf2(ps.code, salt, 600000, 64)) === ps.pbkdf2_600000, 'PBKDF2 (600k rondes) gelijk aan PowerShell');
console.log(`  PBKDF2 600k rondes in WebCrypto: ${Math.round(performance.now() - t0)} ms`);

const sl = await K.sleutelsUitDk(K.b64u.dec(ps.dk));
controleer(hex(sl.enc) === ps.kenc && hex(sl.mac) === ps.kmac, 'Kenc/Kmac uit datasleutel gelijk');
const zelf = await K.versleutel(sl, ps.context, ps.tekst, K.b64u.dec(ps.iv));
controleer(K.b64u.enc(zelf) === ps.blob, 'Zelfde iv geeft byte-voor-byte hetzelfde bestand');
controleer(K.tekst.uitBytes(await K.ontsleutel(sl, ps.context, K.b64u.dec(ps.blob))) === ps.tekst, 'PowerShell-bestand ontsleutelt in WebCrypto');
const knoei = K.b64u.dec(ps.blob); knoei[30] ^= 1;
controleer(await weigert(() => K.ontsleutel(sl, ps.context, knoei)), 'Aangepast bestand wordt geweigerd');
controleer(await weigert(() => K.ontsleutel(sl, 'lid-andere|scores', K.b64u.dec(ps.blob))), 'Verwisseld lid wordt geweigerd');

const jwk = await K.openKluis('lid-7f3a', ps.kluis, ps.code);
controleer(jwk.d === ps.paren[0].prive.d, 'PowerShell-kluis opent in WebCrypto met de juiste code');
controleer(await weigert(() => K.openKluis('lid-7f3a', ps.kluis, 'tafel-wolk-rivier-kompas-vijg-lantaren')), 'Code met Ã©Ã©n letter verschil wordt geweigerd');

controleer(await K.controlewoorden(ps.aanvraag, WOORDEN) === ps.controlewoorden, `Controlewoorden (6) gelijk: ${ps.controlewoorden}`);
controleer(await K.verifieer(ps.paren[0].publiek, ps.getekend.context, ps.getekend.door, ps.getekend.inhoud, ps.sig), 'PowerShell-handtekening klopt in WebCrypto');
controleer(!(await K.verifieer(ps.paren[0].publiek, ps.getekend.context, 'lid-ander', ps.getekend.inhoud, ps.sig)), 'Andere ondertekenaar: ongeldig');
controleer(hex((await K.akUitJwk(ps.paren[0].prive)).enc) === ps.ak, 'Antwoordensleutel gelijk aan PowerShell');
controleer(ps.vorm[0] === true && ps.vorm[1] === false && ps.vorm[2] === false && K.sleutelVorm(ps.paren[0].publiek) && !K.sleutelVorm({ kty: 'RSA', e: 'Aw', n: ps.paren[0].publiek.n }), 'Sleutelvorm: alleen e=65537 en n=3072 bit zonder opvulling');
controleer(/^[a-z]+(-[a-z]+){5}$/.test(ps.nieuweCode) && ps.nieuweCode.split('-').every((w) => WOORDEN.includes(w)), `PowerShell-code geldig: ${ps.nieuweCode}`);
controleer(K.normaliseerCode('  Tafel Wolk  rivier-kompas_vijg lantaarn ') === 'tafel-wolk-rivier-kompas-vijg-lantaarn', 'Code met spaties en hoofdletters wordt genormaliseerd');
let ok = 0, nul = 0; const terugNaarPs = [];
for (const p of ps.paren) {
  try { if (gelijk(await K.pakUit(p.prive, K.b64u.dec(p.verpakt)), K.b64u.dec(p.dk))) ok++; } catch (e) { console.log('   ', e.message); }
  if (p.voorloopnul) nul++;
  const dk = K.willekeurig(32);
  terugNaarPs.push({ dk: K.b64u.enc(dk), verpakt: K.b64u.enc(await K.verpak(p.publiek, dk)) });
}
controleer(ok === ps.paren.length, `PowerShell-sleutels in WebCrypto geopend: ${ok}/${ps.paren.length} (waarvan ${nul} met voorloopnullen)`);

// Feedback en scorebord van PowerShell (New-DlFeedback, scorebordhandtekening) lezen zoals de beheerder/website dat doet
{
  const f = JSON.parse(ps.feedback.bestand), ctx = `feedback|${ps.feedback.naam}`;
  const fsl = await K.sleutelsUitDk(await K.pakUit(await K.priveSleutel(ps.paren[1].prive), K.b64u.dec(f.kopieen.beheer)));
  const env = JSON.parse(K.tekst.uitBytes(await K.ontsleutel(fsl, ctx, K.b64u.dec(f.blob))).trim());
  const i = JSON.parse(env.inhoud);
  controleer(await K.verifieer(ps.paren[0].publiek, ctx, 'lid-7f3a00', env.inhoud, env.sig) && i.soort === 'toevoeging' && i.tekst === 'Meer over hreflang graag. Ë ✓ <b>', 'PowerShell-feedback ontsleutelt en klopt in WebCrypto');
  controleer(await K.verifieer(ps.paren[0].publiek, 'scorebord|2026-10|lid-7f3a00', 'lid-7f3a00', ps.scorebord.inhoud, ps.scorebord.sig), 'PowerShell-scorebord: handtekening klopt in WebCrypto');
  controleer(!(await K.verifieer(ps.paren[0].publiek, 'scorebord|2026-11|lid-7f3a00', 'lid-7f3a00', ps.scorebord.inhoud, ps.scorebord.sig)), 'Scorebord naar een andere maand verplaatst: ongeldig');
}

// Eigen gegevens voor de controle in PowerShell
const paren = []; let metNullen = 0;
while ((metNullen < 3 || paren.length < 8) && paren.length < 120) {
  const kp = await K.nieuwSleutelpaar(3072);
  const n = K.b64u.dec(kp.prive.n).length, h = n / 2;
  const kort = K.b64u.dec(kp.prive.d).length < n || ['p', 'q', 'dp', 'dq', 'qi'].some((v) => K.b64u.dec(kp.prive[v]).length < h);
  if (kort) metNullen++;
  const dk = K.willekeurig(32);
  paren.push({ publiek: kp.publiek, prive: kp.prive, dk: K.b64u.enc(dk), verpakt: K.b64u.enc(await K.verpak(kp.publiek, dk)), voorloopnul: kort });
}
console.log(`  ${paren.length} WebCrypto-sleutelparen, waarvan ${metNullen} met voorloopnullen`);
const ndk = K.willekeurig(32), nsl = await K.sleutelsUitDk(ndk);
const tekst = 'Gemaakt in WebCrypto: hreflang, GA4 en CRO. Ã‹ Ã¯ Ã© âœ“';
const uitvoer = {
  code: 'boomhut-anker-wafel-ster-nevel-fluit', dk: K.b64u.enc(ndk), context: 'lid-node|scores', tekst,
  blob: K.b64u.enc(await K.versleutel(nsl, 'lid-node|scores', tekst)),
  kluis: await K.sluitKluis('lid-node', paren[0].prive, 'boomhut-anker-wafel-ster-nevel-fluit', 1000),
  paren, terugNaarPs,
  aanvraag: await (async () => { const a = { v: 1, id: 'lid-node', publiek: paren[0].publiek, kluis: await K.sluitKluis('lid-node', paren[0].prive, 'boomhut-anker-wafel-ster-nevel-fluit', 1000), toegang: { 'lid-node': 'abc', generator: 'def' } }; return a; })(),
  getekend: { context: 'lid-node|log-2026-10', door: 'lid-node', inhoud: '{"v":1,"regels":[]}' },
  sig: await K.onderteken(paren[0].prive, 'lid-node|log-2026-10', 'lid-node', '{"v":1,"regels":[]}'),
  ak: hex((await K.akUitJwk(paren[0].prive)).enc)
};
uitvoer.controlewoorden = await K.controlewoorden(uitvoer.aanvraag, WOORDEN);
// Feedback precies zoals verstuurFeedback() in docs/app.js hem maakt (versleuteld naar PowerShell-sleutel paren[1] als 'beheer')
{
  const vulOp = (b) => { const doel = Math.max(1024, Math.ceil(b.length / 1024) * 1024); if (doel === b.length) return b; const o = new Uint8Array(doel).fill(0x20); o.set(b); return o; };
  const naam = `20261021T101500-${hex(K.willekeurig(4))}`, ctx = `feedback|${naam}`, door = 'lid-abcdef';
  const tekst = 'Het antwoord klopt niet helemaal: "zie bron" <script>alert(1)</script> ✓';
  const inhoud = JSON.stringify({ v: 1, soort: 'fout', les: '20261019-query-fan-out', tekst, datum: '2026-10-21T10:15:00' });
  const env = { v: 2, door, inhoud, sig: await K.onderteken(await K.tekenSleutel(paren[0].prive), ctx, door, inhoud) };
  const dk = K.willekeurig(32), fsl = await K.sleutelsUitDk(dk);
  const bestand = { v: 1, kopieen: { beheer: K.b64u.enc(await K.verpak(ps.paren[1].publiek, dk)) }, blob: K.b64u.enc(await K.versleutel(fsl, ctx, vulOp(K.tekst.naarBytes(JSON.stringify(env))))) };
  uitvoer.feedback = { naam, tekst, bestand: JSON.stringify(bestand) };
  const sb = JSON.stringify({ v: 1, maand: '2026-10', zichtbaar: true, goed: 5, langsteReeks: 3, huidigeReeks: 1, laatsteDag: '2026-10-21', bijgewerkt: '2026-10-21T10:00:00' });
  uitvoer.scorebord = JSON.stringify({ v: 2, door, inhoud: sb, sig: await K.onderteken(await K.tekenSleutel(paren[0].prive), `scorebord|2026-10|${door}`, door, sb) });
}
writeFileSync(join(map, 'node-vectoren.json'), JSON.stringify(uitvoer));
process.exit(fouten ? 1 : 0);
