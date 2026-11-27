// Skilllijst-Excel (.xlsx) lezen in de browser, zonder bibliotheek: zip uitpakken met DecompressionStream en de
// XML lezen met DOMParser. Spiegelbeeld van app/lib/skilllijst.ps1 (Read-DlXlsx + Import-DlSkilllijst).
// Opzet sheet: A = hoofdgebied, B = onderwerp, C = vaardigheid (of een inleidende zin zonder score),
// D..I = maand 1..6 (D1 = datum van maand 1), J = huidige score.

const MAX_BESTAND = 10 * 1024 * 1024;   // .xlsx zelf
const MAX_UITGEPAKT = 40 * 1024 * 1024; // alles samen na uitpakken (tegen zip-bommen)

async function inflate(data, max) {
  const s = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  const r = s.getReader(); const delen = []; let n = 0;
  for (;;) {
    const { done, value } = await r.read();
    if (done) break;
    n += value.length; if (n > max) { r.cancel(); throw new Error('Dit Excel-bestand is te groot.'); }
    delen.push(value);
  }
  const out = new Uint8Array(n); let o = 0; for (const d of delen) { out.set(d, o); o += d.length; }
  return out;
}

/** Alleen de gevraagde bestanden uit een zip halen. */
async function leesZip(buf, wil) {
  const b = new Uint8Array(buf), dv = new DataView(buf);
  let eocd = -1;
  for (let i = b.length - 22; i >= Math.max(0, b.length - 22 - 65535); i--) if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  if (eocd < 0) throw new Error('Dit is geen geldig Excel-bestand (.xlsx).');
  const aantal = dv.getUint16(eocd + 10, true); let p = dv.getUint32(eocd + 16, true);
  const uit = new Map(); let totaal = 0; const dec = new TextDecoder();
  for (let k = 0; k < aantal; k++) {
    if (p + 46 > b.length || dv.getUint32(p, true) !== 0x02014b50) throw new Error('Het Excel-bestand is beschadigd.');
    const methode = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true), usize = dv.getUint32(p + 24, true);
    const nl = dv.getUint16(p + 28, true), el = dv.getUint16(p + 30, true), cl = dv.getUint16(p + 32, true), lok = dv.getUint32(p + 42, true);
    const naam = dec.decode(b.subarray(p + 46, p + 46 + nl));
    p += 46 + nl + el + cl;
    if (!wil(naam)) continue;
    if (lok + 30 > b.length || dv.getUint32(lok, true) !== 0x04034b50) throw new Error('Het Excel-bestand is beschadigd.');
    const start = lok + 30 + dv.getUint16(lok + 26, true) + dv.getUint16(lok + 28, true);
    const ruw = b.subarray(start, start + csize);
    const rest = MAX_UITGEPAKT - totaal;
    const data = methode === 0 ? ruw.slice() : methode === 8 ? await inflate(ruw, Math.min(rest, usize || rest)) : null;
    if (!data) throw new Error('Onbekende compressie in het Excel-bestand.');
    totaal += data.length; if (totaal > MAX_UITGEPAKT) throw new Error('Dit Excel-bestand is te groot.');
    uit.set(naam, new TextDecoder().decode(data));
  }
  return uit;
}

const xml = (t) => { const d = new DOMParser().parseFromString(t, 'application/xml'); if (d.getElementsByTagName('parsererror').length) throw new Error('Het Excel-bestand kon niet gelezen worden.'); return d; };
const kind = (el, naam) => [...el.childNodes].find((n) => n.localName === naam);

/** Werkbladen in de volgorde van de tabbladen: [{ naam, pad }]. Zonder workbook.xml: op bestandsnaam. */
function bladenOpVolgorde(zip) {
  const bestanden = [...zip.keys()].filter((n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n)).sort();
  if (!zip.has('xl/workbook.xml') || !zip.has('xl/_rels/workbook.xml.rels')) return bestanden.map((pad) => ({ naam: pad, pad }));
  const doel = new Map([...xml(zip.get('xl/_rels/workbook.xml.rels')).getElementsByTagNameNS('*', 'Relationship')]
    .map((r) => { const t = r.getAttribute('Target') || ''; return [r.getAttribute('Id'), t.startsWith('/') ? t.slice(1) : `xl/${t}`]; }));
  const lijst = [...xml(zip.get('xl/workbook.xml')).getElementsByTagNameNS('*', 'sheet')]
    .map((s) => ({ naam: s.getAttribute('name') || '', pad: doel.get(s.getAttributeNS('http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id') || s.getAttribute('r:id')) }))
    .filter((b) => zip.has(b.pad));
  return lijst.length ? lijst : bestanden.map((pad) => ({ naam: pad, pad }));
}

/**
 * Rijen als Map(rijnummer -> { A: tekst, B: tekst, ... }) van het werkblad met de skilllijst. Heeft het bestand meer
 * tabbladen (bijv. uitleg + een blad per persoon), dan telt alleen een blad met vaardigheden ("- ..." in kolom C);
 * zijn dat er meer, dan het blad met de voornaam uit `naam` in de bladnaam, anders het blad met de meeste scores,
 * anders het eerste. Spiegelbeeld van Read-DlXlsx in app/lib/skilllijst.ps1.
 */
export async function leesXlsx(bestand, naam = '') {
  if (bestand.size > MAX_BESTAND) throw new Error('Dit Excel-bestand is te groot (max. 10 MB).');
  const zip = await leesZip(await bestand.arrayBuffer(), (n) => /^xl\/worksheets\/sheet\d+\.xml$/.test(n)
    || ['xl/sharedStrings.xml', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels'].includes(n));
  const gedeeld = [];
  if (zip.has('xl/sharedStrings.xml')) {
    for (const si of xml(zip.get('xl/sharedStrings.xml')).getElementsByTagNameNS('*', 'si'))
      gedeeld.push([...si.getElementsByTagNameNS('*', 't')].map((t) => t.textContent).join(''));
  }
  const leesBlad = (pad) => {
    const rijen = new Map();
    for (const rij of xml(zip.get(pad)).getElementsByTagNameNS('*', 'row')) {
      const cellen = {};
      for (const c of rij.getElementsByTagNameNS('*', 'c')) {
        const v = kind(c, 'v'), is = kind(c, 'is');
        if (!v && !is) continue;
        const kol = (c.getAttribute('r') || '').replace(/\d/g, '');
        const t = c.getAttribute('t');
        cellen[kol] = t === 's' ? (gedeeld[Number(v.textContent)] ?? '') : t === 'inlineStr' ? (is?.textContent ?? '') : (v?.textContent ?? '');
      }
      rijen.set(Number(rij.getAttribute('r')), cellen);
    }
    return rijen;
  };
  const bladen = bladenOpVolgorde(zip);
  if (!bladen.length) throw new Error('Geen werkblad gevonden in het Excel-bestand.');
  if (bladen.length === 1) return leesBlad(bladen[0].pad);
  const woorden = (t) => String(t).toLowerCase().match(/\p{L}+/gu) || [];
  const voornaam = woorden(naam)[0] || '';
  const kandidaten = bladen.map((b) => {
    const rijen = leesBlad(b.pad); let n = 0, scores = 0;
    for (const c of rijen.values()) {
      if (!/^\s*[-–•]/.test(c.C || '')) continue;
      n++; scores += ['D', 'E', 'F', 'G', 'H', 'I'].filter((k) => /^[1-5](\.0+)?$/.test(String(c[k] ?? ''))).length;
    }
    return { ...b, rijen, n, scores };
  }).filter((b) => b.n);
  if (!kandidaten.length) return leesBlad(bladen[0].pad);
  const metNaam = voornaam.length > 1 && kandidaten.find((b) => woorden(b.naam).includes(voornaam));
  return (metNaam || kandidaten.reduce((a, b) => (b.scores > a.scores ? b : a))).rijen;
}

const herstel = (t) => String(t).replaceAll('ici�n', 'iciën').replaceAll('be�nvl', 'beïnvl').replaceAll('ge�nd', 'geïnd').trim();
const sleutelTekst = (t) => herstel(t).toLowerCase().replace(/^[-\s]+/, '').replace(/[^a-z0-9ëïéèäöü]+/g, ' ').trim();
const maandVan = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;

/**
 * Skilllijst koppelen aan het sjabloon (Map id -> { id, onderwerp, vaardigheid, ... } in sjabloonvolgorde).
 * Geeft { matrix: { v, sjabloon, scores }, gekoppeld, totaal, nietGevonden }.
 */
export function importeerSkilllijst(rijen, sjabloon, vakgebied) {
  const sj = [...sjabloon.values()];
  const index = new Map(sj.map((s) => [`${sleutelTekst(s.onderwerp)}|${sleutelTekst(s.vaardigheid)}`, s.id]));
  // Maand 1 uit D1 (Excel-datum, dagen sinds 30-12-1899); E..I zijn de maanden erna
  const nu = new Date();
  let start = new Date(nu.getFullYear(), nu.getMonth(), 1);
  const d1 = String(rijen.get(1)?.D ?? '');
  if (/^\d+(\.0+)?$/.test(d1)) { const d = new Date(Date.UTC(1899, 11, 30) + Number(d1) * 864e5); start = new Date(d.getUTCFullYear(), d.getUTCMonth(), 1); }
  const maandKol = {}; ['D', 'E', 'F', 'G', 'H', 'I'].forEach((k, i) => { maandKol[k] = maandVan(new Date(start.getFullYear(), start.getMonth() + i, 1)); });
  const scoreVan = (x) => { const m = /^([1-5])(\.0+)?$/.exec(String(x ?? '')); return m ? Number(m[1]) : null; };

  const scores = {}; const nietGevonden = []; let onderwerp = ''; let volgorde = 0;
  for (const r of [...rijen.keys()].sort((a, b) => a - b)) {
    const c = rijen.get(r);
    if (r === 1) continue;
    if (c.B) { onderwerp = c.B; continue; }
    if (!c.C) continue;
    if (![...Object.keys(maandKol), 'J'].some((k) => scoreVan(c[k]))) continue;   // inleidende zin of voortgangsregel
    volgorde++;
    let id = index.get(`${sleutelTekst(onderwerp)}|${sleutelTekst(c.C)}`);
    if (!id && volgorde <= sj.length) { id = sj[volgorde - 1].id; nietGevonden.push(`rij ${r} gekoppeld op volgorde aan ${id} (${herstel(c.C)})`); }
    if (!id) { nietGevonden.push(`rij ${r} niet gekoppeld: ${herstel(c.C)}`); continue; }
    const s = {};
    for (const [k, m] of Object.entries(maandKol)) { const n = scoreVan(c[k]); if (n) s[m] = n; }
    if (!Object.keys(s).length && scoreVan(c.J)) s[maandVan(nu)] = scoreVan(c.J);
    scores[id] = s;
  }
  return { matrix: { v: 1, sjabloon: vakgebied, scores }, gekoppeld: Object.keys(scores).length, totaal: sj.length, nietGevonden };
}
