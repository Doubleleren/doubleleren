// DoubleLeren: wie mag wie zien (kijkers) en wie mag wie uitnodigen, volgens organisatie.json. Eén bron voor de site en
// de portier; dezelfde regels staan in PowerShell in app/lib/organisatie.ps1 (test\regelstest.ps1 vergelijkt ze).
//   kijkers van een lid: het lid zelf · projectleider van het project · celleider van de cel · head van het vak · generator
//   uitnodigen: de beheerder iedereen; een kijker (projectleider, celleider, head) alleen gewone leden die hij ziet.
//   Heads, leiders en beheerders nodigt alleen de beheerder uit: wie uitnodigt, ziet de code en kan zich anders als
//   een leider aanmelden en dan diens hele cel of vak zien.
export const ID_VORM = /^lid-[0-9a-f]{6}$/;
const lijst = (x) => (Array.isArray(x) ? x : []);

export function celVanLid(org, id) {
  const lid = org?.leden?.[id]; if (!lid) return null;
  if (lid.cel) return lijst(org.cellen).find((c) => c.id === lid.cel) || null;
  if (lid.project) return lijst(org.cellen).find((c) => lijst(c.projecten).some((p) => p.id === lid.project)) || null;
  return null;
}
export function projectVanLid(org, id) {
  const lid = org?.leden?.[id]; if (!lid?.project) return null;
  for (const c of lijst(org.cellen)) for (const p of lijst(c.projecten)) if (p.id === lid.project) return p;
  return null;
}
export const vakVanLid = (org, id) => { const v = org?.leden?.[id]?.vak; return v ? String(v) : String(org?.vakgebied ?? ''); };
export function headVanVak(org, vak) {
  if (org?.heads && org.heads[vak]) return String(org.heads[vak]);
  if (vak === org?.vakgebied) return org?.head || null;
  return null;
}
export const heads = (org) => [...new Set([org?.head, ...Object.values(org?.heads || {})].filter(Boolean))];
export const isBeheerder = (org, id) => lijst(org?.beheerders).includes(id);
// Head, celleider, projectleider of beheerder: ziet anderen of beheert, dus nooit automatisch goedkeuren
export function heeftRol(org, id) {
  if (heads(org).includes(id)) return true;
  for (const c of lijst(org?.cellen)) { if (c.leider === id) return true; for (const p of lijst(c.projecten)) if (p.leider === id) return true; }
  return isBeheerder(org, id);
}
export function kijkers(org, id) {
  const k = [];
  const voeg = (x) => { if (x && !k.includes(x)) k.push(x); };
  voeg(id);
  voeg(projectVanLid(org, id)?.leider);
  voeg(celVanLid(org, id)?.leider);
  voeg(headVanVak(org, vakVanLid(org, id)));
  voeg('generator');
  return k;
}
// Mag 'door' het bestaande lid 'id' uitnodigen?
export function magUitnodigen(org, door, id) {
  if (!ID_VORM.test(String(door)) || !ID_VORM.test(String(id)) || door === id) return false;
  if (!org?.leden?.[door] || !org?.leden?.[id]) return false;
  if (isBeheerder(org, door)) return true;
  if (heeftRol(org, id)) return false;
  return kijkers(org, id).includes(door);
}
// Mag 'door' een nieuw gewoon lid toevoegen op deze plek ({ project } of { cel } of niets) met dit vak?
// Zelfde regel als hierboven, voor een lid dat er nog niet is: als hij er stond, zou 'door' hem dan mogen uitnodigen?
export function magToevoegen(org, door, plek, vak) {
  const proef = 'lid-000000';
  const lid = {}; if (plek?.project) lid.project = String(plek.project); else if (plek?.cel) lid.cel = String(plek.cel);
  if (vak && vak !== org?.vakgebied) lid.vak = String(vak);
  const kopie = { ...org, leden: { ...(org?.leden || {}), [proef]: lid } };
  return magUitnodigen(kopie, door, proef);
}
