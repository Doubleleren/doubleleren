// DoubleLeren-krypto v1 (browser + Node). Spiegelbeeld van app/lib/krypto.ps1: wijzig nooit één kant alleen.
//
// Bestandsformaat (DL1):  "DL1" | iv(16) | AES-256-CBC-PKCS7(ct) | HMAC-SHA256 tag(32)
//   tag = HMAC(Kmac, utf8("DL1|" + context + "|") || iv || ct)       encrypt-then-MAC
//   context bindt het bestand aan lid en soort, bijv. "lid-7f3a|scores", zodat bestanden niet te verwisselen zijn.
// Datasleutel (DK, 32 bytes):  Kenc = HMAC(DK, "doubleleren-v1-enc"), Kmac = HMAC(DK, "doubleleren-v1-mac")
// Kluis v2 (privésleutel achter de inlogcode): k = PBKDF2-SHA256(code, salt16, iteraties, 32 bytes); Kenc/Kmac = HMAC(k, label)
// Antwoordensleutel AK: afgeleid uit de eigen privésleutel (HMAC(SHA256(d), label)), staat nergens als bestand.
// Handtekeningen: RSA-PSS-SHA256 (salt 32) over "DLSIG1|context|door|inhoud".
// Sleutelpaar: RSA-OAEP-SHA256, 3072 bit, uitgewisseld als JWK.

const S = globalThis.crypto.subtle;
const E = new TextEncoder();
const D = new TextDecoder();
const MAGIC = E.encode('DL1');
export const PBKDF2_ITERATIES = 600000;

export const b64u = {
  enc(bytes) {
    let s = '';
    const b = new Uint8Array(bytes);
    for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  },
  dec(str) {
    const s = str.replace(/-/g, '+').replace(/_/g, '/');
    const bin = atob(s + '==='.slice((s.length + 3) % 4));
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
};

const concat = (...delen) => {
  const n = delen.reduce((a, d) => a + d.length, 0), out = new Uint8Array(n);
  let o = 0; for (const d of delen) { out.set(d, o); o += d.length; }
  return out;
};
export const willekeurig = (n) => globalThis.crypto.getRandomValues(new Uint8Array(n));

async function hmac(sleutel, data) {
  const k = await S.importKey('raw', sleutel, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await S.sign('HMAC', k, data));
}

export async function pbkdf2(code, salt, iteraties = PBKDF2_ITERATIES, lengte = 32) {
  const basis = await S.importKey('raw', E.encode(code.normalize('NFC')), 'PBKDF2', false, ['deriveBits']);
  return new Uint8Array(await S.deriveBits({ name: 'PBKDF2', salt, iterations: iteraties, hash: 'SHA-256' }, basis, lengte * 8));
}

/** Kenc/Kmac uit een datasleutel van 32 bytes. */
export async function sleutelsUitDk(dk) {
  return { enc: await hmac(dk, E.encode('doubleleren-v1-enc')), mac: await hmac(dk, E.encode('doubleleren-v1-mac')) };
}
/** Kenc/Kmac uit 32 bytes PBKDF2-uitvoer (kluis v2). */
export async function sleutelsUitAfgeleid(k) {
  return { enc: await hmac(k, E.encode('doubleleren-v2-kluis-enc')), mac: await hmac(k, E.encode('doubleleren-v2-kluis-mac')) };
}
const zonderNullen = (b) => { let i = 0; while (i < b.length - 1 && b[i] === 0) i++; return b.slice(i); };
/** Antwoordensleutel uit de privé-JWK. */
export async function akUitJwk(priveJwk) {
  const h = new Uint8Array(await S.digest('SHA-256', zonderNullen(b64u.dec(priveJwk.d))));
  return sleutelsUitDk(await hmac(h, E.encode('doubleleren-v1-ak')));
}

export async function versleutel(sleutels, context, data, iv = willekeurig(16)) {
  const k = await S.importKey('raw', sleutels.enc, 'AES-CBC', false, ['encrypt']);
  const ct = new Uint8Array(await S.encrypt({ name: 'AES-CBC', iv }, k, typeof data === 'string' ? E.encode(data) : data));
  const tag = await hmac(sleutels.mac, concat(E.encode('DL1|' + context + '|'), iv, ct));
  return concat(MAGIC, iv, ct, tag);
}

export async function ontsleutel(sleutels, context, blob) {
  blob = new Uint8Array(blob);
  if (blob.length < 3 + 16 + 16 + 32 || D.decode(blob.subarray(0, 3)) !== 'DL1') throw new Error('Geen DL1-bestand');
  const iv = blob.subarray(3, 19), ct = blob.subarray(19, blob.length - 32), tag = blob.subarray(blob.length - 32);
  // WebCrypto verify vergelijkt in constante tijd
  const k = await S.importKey('raw', sleutels.mac, { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
  const ok = await S.verify('HMAC', k, tag, concat(E.encode('DL1|' + context + '|'), iv, ct));
  if (!ok) throw new Error('Controle mislukt: verkeerde sleutel, verkeerde context of aangepast bestand');
  const ak = await S.importKey('raw', sleutels.enc, 'AES-CBC', false, ['decrypt']);
  return new Uint8Array(await S.decrypt({ name: 'AES-CBC', iv }, ak, ct));
}

// --- RSA-OAEP-SHA256 -------------------------------------------------------
const RSA = { name: 'RSA-OAEP', hash: 'SHA-256' };
const PUB_VELDEN = ['kty', 'n', 'e'];
const PRIV_VELDEN = ['kty', 'n', 'e', 'd', 'p', 'q', 'dp', 'dq', 'qi'];
const kaal = (jwk, velden) => Object.fromEntries(velden.map((v) => [v, jwk[v]]));

export async function nieuwSleutelpaar(bits = 3072) {
  const kp = await S.generateKey({ ...RSA, modulusLength: bits, publicExponent: new Uint8Array([1, 0, 1]) }, true, ['encrypt', 'decrypt']);
  return {
    publiek: kaal(await S.exportKey('jwk', kp.publicKey), PUB_VELDEN),
    prive: kaal(await S.exportKey('jwk', kp.privateKey), PRIV_VELDEN)
  };
}

export async function verpak(publiekJwk, dk) {
  const k = await S.importKey('jwk', { ...publiekJwk, alg: 'RSA-OAEP-256', ext: true }, RSA, false, ['encrypt']);
  return new Uint8Array(await S.encrypt({ name: 'RSA-OAEP' }, k, dk));
}

/** Privésleutel als niet-exporteerbare CryptoKey (kan in IndexedDB bewaard worden, maar nooit uitgelezen). */
export const priveSleutel = (priveJwk) => S.importKey('jwk', { ...priveJwk, alg: 'RSA-OAEP-256', ext: false }, RSA, false, ['decrypt']);

/** DK uitpakken met een privésleutel (JWK of CryptoKey). */
export async function pakUit(prive, verpakt) {
  const k = prive instanceof CryptoKey ? prive : await priveSleutel(prive);
  return new Uint8Array(await S.decrypt({ name: 'RSA-OAEP' }, k, verpakt));
}

// --- Kluis: privésleutel achter de inlogcode --------------------------------
export async function sluitKluis(id, priveJwk, code, iteraties = PBKDF2_ITERATIES, salt = willekeurig(16)) {
  const s = await sleutelsUitAfgeleid(await pbkdf2(code, salt, iteraties));
  const blob = await versleutel(s, id + '|kluis', JSON.stringify(kaal(priveJwk, PRIV_VELDEN)));
  return { v: 2, salt: b64u.enc(salt), iteraties, kluis: b64u.enc(blob) };
}

export async function openKluis(id, kluis, code) {
  const it = Number(kluis?.iteraties);
  if (kluis?.v !== 2 || !Number.isInteger(it) || it < 1000 || it > 2000000) throw new Error('Ongeldige kluis');
  const s = await sleutelsUitAfgeleid(await pbkdf2(code, b64u.dec(kluis.salt), it));
  return JSON.parse(D.decode(await ontsleutel(s, id + '|kluis', b64u.dec(kluis.kluis))));
}

/** Vaste sleutelvorm: e = 65537, n = 3072 bit zonder voorloopnul. */
export function sleutelVorm(pub) {
  try { const n = b64u.dec(pub.n); return pub.kty === 'RSA' && pub.e === 'AQAB' && n.length === 384 && n[0] !== 0 && b64u.enc(n) === pub.n; } catch { return false; }
}

// --- Handtekeningen ----------------------------------------------------------------
const PSS = { name: 'RSA-PSS', hash: 'SHA-256' };
const tekenBytes = (context, door, inhoud) => E.encode(`DLSIG1|${context}|${door}|${inhoud}`);
export async function onderteken(priveJwk, context, door, inhoud) {
  const k = await S.importKey('jwk', { ...kaal(priveJwk, PRIV_VELDEN), alg: 'PS256', ext: false }, PSS, false, ['sign']);
  return b64u.enc(await S.sign({ name: 'RSA-PSS', saltLength: 32 }, k, tekenBytes(context, door, inhoud)));
}
export async function verifieer(publiekJwk, context, door, inhoud, sig) {
  if (!publiekJwk || !sig) return false;
  try {
    const k = await S.importKey('jwk', { kty: 'RSA', n: publiekJwk.n, e: publiekJwk.e, alg: 'PS256', ext: false }, PSS, false, ['verify']);
    return await S.verify({ name: 'RSA-PSS', saltLength: 32 }, k, b64u.dec(sig), tekenBytes(context, door, inhoud));
  } catch { return false; }
}

/** SHA-256 over "e.n" van de publieke sleutel: basis voor de controlewoorden. */
export async function vingerafdruk(publiekJwk) {
  return new Uint8Array(await S.digest('SHA-256', E.encode(publiekJwk.e + '.' + publiekJwk.n)));
}

export const tekst = { naarBytes: (s) => E.encode(s), uitBytes: (b) => D.decode(b) };

// Woordcodes: lijst van precies 1024 woorden, dus elk woord = 10 bits.
const woordUit = (b, i, woorden) => woorden[((b[2 * i] << 8) | b[2 * i + 1]) & 1023];
/** Nieuwe inlogcode van 6 willekeurige woorden (60 bits). */
export function nieuweCode(woorden) {
  const r = willekeurig(12);
  return Array.from({ length: 6 }, (_, i) => woordUit(r, i, woorden)).join('-');
}
/** 6 controlewoorden (60 bits) over de hele aanvraag; gelijk aan Get-DlControlewoorden in PowerShell. */
export async function controlewoorden(a, woorden) {
  const delen = ['DLAANVRAAG1', a.id, a.publiek.e, a.publiek.n, a.kluis.salt, a.kluis.kluis, String(a.kluis.iteraties),
    a.toegang?.[a.id] || '', a.toegang?.generator || '', a.herstel ? 'herstel' : 'nieuw'];
  const v = new Uint8Array(await S.digest('SHA-256', E.encode(delen.join('|'))));
  return Array.from({ length: 6 }, (_, i) => woordUit(v, i, woorden)).join(' ');
}
/** Code netjes maken: kleine letters, spaties/streepjes tussen woorden. */
export const normaliseerCode = (c) => c.trim().toLowerCase().split(/[\s\-_.,]+/).filter(Boolean).join('-');
