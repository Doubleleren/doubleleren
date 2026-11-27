// Node-deel van test\regelstest.ps1: dezelfde gevallen met docs/regels.js
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as R from '../docs/regels.js';

const map = process.argv[2];
const org = JSON.parse(readFileSync(join(map, 'org.json'), 'utf8').replace(/^﻿/, ''));
const ps = JSON.parse(readFileSync(join(map, 'ps.json'), 'utf8').replace(/^﻿/, ''));
const js = { kijkers: {}, rol: {}, uitnodigen: {}, toevoegen: {} };
for (const id of Object.keys(ps.kijkers)) { js.kijkers[id] = R.kijkers(org, id); js.rol[id] = R.heeftRol(org, id); }
for (const k of Object.keys(ps.uitnodigen)) { const [door, id] = k.split('>'); js.uitnodigen[k] = R.magUitnodigen(org, door, id); }
for (const k of Object.keys(ps.toevoegen)) {
  const [door, rest] = k.split('>'); const [p, c, vak] = rest.split('|');
  js.toevoegen[k] = R.magToevoegen(org, door, p ? { project: p } : c ? { cel: c } : null, vak || null);
}
writeFileSync(join(map, 'js.json'), JSON.stringify(js));
console.log('ok');
