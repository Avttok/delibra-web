import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Histórico de percurso traçado pelas ruas.
 * Os pings chegam de tempos em tempos, então a linha reta entre eles corta quarteirões. Aqui cada
 * registro é casado com o mapa de ruas ("map matching") em trechos; cada trecho fica guardado
 * (trechos_ajustados) e o app e o site reaproveitam. Sem resposta do mapa, o trecho fica com os pings.
 *
 * Tudo é ajustável em Configurações → Rastreamento e percurso:
 *  - percurso_provedor: "valhalla" (perfil de moto, penaliza curvas sem sentido) ou "osrm"
 *  - percurso_perfil: motorcycle | auto | bicycle (só no Valhalla)
 *  - percurso_raio_m: até que distância da rua um ping ainda "gruda" nela
 *  - percurso_filtro_m: pings mais próximos que isso do anterior são ignorados (tremido de quem está parado)
 *  - percurso_vel_max_kmh: salto impossível entre dois pings é descartado
 *  - percurso_tira_voltas / percurso_volta_max_m: corta voltas no quarteirão que começam e terminam no mesmo ponto
 *
 * Mesmo arquivo nos dois sites (gestor e cliente).
 */

const OSRM = "https://router.project-osrm.org";
const VALHALLA = "https://valhalla1.openstreetmap.de";
const LACUNA_MS = 20 * 60_000;
const MAX_TRECHOS_NOVOS = 30;

/** [motoboy, lat, lng, status, corrida, ms, precisão] — como o banco devolve. */
export type PingBruto = [string, number, number, string, string | null, number, number];
interface Legado { motoboy: string; corrida: string; trajeto: string; ini: number; fim: number }
export interface Ajuste { ate: number; caminho: [number, number][] }
export interface RespostaPercursos {
  pings: PingBruto[];
  /** chave "motoboy|inicioMs" de cada registro → caminho pelas ruas até o ping `ate` (ms). */
  ajustes: Record<string, Ajuste>;
  /** Linha única (lat, lng) de tudo, na ordem: útil para a trilha de uma corrida. */
  linha: [number, number][];
  /** Faltou ajustar algum trecho (o mapa demorou): vale pedir de novo daqui a pouco. */
  parcial: boolean;
}
interface Opcoes { provedor: "valhalla" | "osrm"; perfil: string; raio: number; filtro: number; velMax: number; tiraVoltas: boolean; voltaMax: number }
const PADRAO: Opcoes = { provedor: "valhalla", perfil: "motorcycle", raio: 30, filtro: 12, velMax: 160, tiraVoltas: true, voltaMax: 450 };

const valida = (lat: number, lng: number) => Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180 && !(lat === 0 && lng === 0);

function metros(a: [number, number], b: [number, number]) {
  const r = Math.PI / 180;
  const h = Math.sin(((b[0] - a[0]) * r) / 2) ** 2 + Math.cos(a[0] * r) * Math.cos(b[0] * r) * Math.sin(((b[1] - a[1]) * r) / 2) ** 2;
  return 2 * 6371000 * Math.asin(Math.sqrt(h));
}
const comprimento = (l: [number, number][]) => l.slice(1).reduce((s, p, i) => s + metros(l[i], p), 0);

function decodificar(s: string, precisao = 1e5): [number, number][] {
  const out: [number, number][] = [];
  let i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    for (const k of [0, 1]) {
      let b, sh = 0, r = 0;
      do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << sh; sh += 5; } while (b >= 0x20 && i < s.length);
      const d = r & 1 ? ~(r >> 1) : r >> 1;
      if (k === 0) lat += d; else lng += d;
    }
    out.push([lat / precisao, lng / precisao]);
  }
  return out;
}

/** Corrida compactada antes de guardarmos os pings: vira pings com horários distribuídos. */
function pingsDoLegado(l: Legado): PingBruto[] {
  const pts = decodificar(l.trajeto).filter(([a, b]) => valida(a, b));
  const passo = pts.length > 1 ? (l.fim - l.ini) / (pts.length - 1) : 0;
  return pts.map(([a, b], k) => [l.motoboy, a, b, "em_corrida", l.corrida, Math.round(l.ini + k * passo), 0]);
}

/** Mesma separação do app e do site: muda de status, de corrida ou fica 20 min sem ping. */
function registros(pings: PingBruto[]) {
  const out: PingBruto[][] = [];
  let atual: PingBruto[] | null = null;
  let tipo = "", corrida: string | null = null, ant = 0;
  for (const p of pings) {
    if (p[3] === "offline") { atual = null; continue; }
    const t = p[3] === "em_corrida" ? "corrida" : "procurando";
    const c = t === "corrida" ? p[4] ?? null : null;
    if (!atual || tipo !== t || corrida !== c || p[5] - ant > LACUNA_MS) { atual = []; out.push(atual); tipo = t; corrida = c; }
    atual.push(p); ant = p[5];
  }
  return out;
}

/** Limpa os pings antes de casar: tremido de quem está parado, leituras ruins e saltos impossíveis. */
function enxugar(pts: PingBruto[], o: Opcoes) {
  const out: PingBruto[] = [];
  for (const p of pts) {
    const u = out[out.length - 1];
    if (u) {
      const d = metros([u[1], u[2]], [p[1], p[2]]);
      if (d < o.filtro) continue;
      if (p[6] > Math.max(120, o.raio * 4) && pts.length > 2) continue; // leitura ruim demais
      const dt = (p[5] - u[5]) / 1000;
      if (dt > 0 && o.velMax > 0 && (d / dt) * 3.6 > o.velMax) continue; // salto impossível (GPS perdido)
    }
    out.push(p);
  }
  const ult = pts[pts.length - 1];
  if (ult && out.length > 0 && out[out.length - 1] !== ult && metros([out[out.length - 1][1], out[out.length - 1][2]], [ult[1], ult[2]]) >= o.filtro) out.push(ult);
  return out;
}

/**
 * Corta as "voltas no quarteirão": quando a linha sai de um ponto e volta praticamente a ele pouco depois
 * (um ping fora da rua faz o mapa dar a volta para "passar" por ele). Voltas maiores que `voltaMax` ficam.
 */
export function tirarVoltas(l: [number, number][], voltaMax: number): [number, number][] {
  if (l.length < 4 || voltaMax <= 0) return l;
  const out: [number, number][] = [];
  let i = 0;
  while (i < l.length) {
    out.push(l[i]);
    let acum = 0, corte = -1;
    for (let j = i + 1; j < l.length && acum <= voltaMax; j++) {
      acum += metros(l[j - 1], l[j]);
      if (acum > 40 && acum <= voltaMax && metros(l[i], l[j]) < 14) corte = j;
    }
    i = corte > i ? corte : i + 1;
  }
  return out;
}

async function pedir(url: string, corpo?: unknown): Promise<Record<string, unknown> | null> {
  try {
    const r = await fetch(url, {
      method: corpo ? "POST" : "GET",
      headers: { "User-Agent": "Delibra (delibra.vercel.app)", ...(corpo ? { "content-type": "application/json" } : {}) },
      body: corpo ? JSON.stringify(corpo) : undefined, signal: AbortSignal.timeout(7000), cache: "no-store",
    });
    if (!r.ok && r.status !== 400) return null;
    return (await r.json()) as Record<string, unknown>;
  } catch { return null; }
}

/** Valhalla: casa a sequência com as ruas no perfil escolhido; curvas sem sentido custam caro. undefined = sem resposta. */
async function casarValhalla(pts: PingBruto[], o: Opcoes): Promise<[number, number][] | null | undefined> {
  const t0 = Math.round(pts[0][5] / 1000);
  let ant = -1;
  const j = await pedir(`${VALHALLA}/trace_route`, {
    shape: pts.map((p) => { const t = Math.max(Math.round(p[5] / 1000) - t0, ant + 1); ant = t; return { lat: p[1], lon: p[2], time: t }; }),
    costing: ["motorcycle", "auto", "bicycle", "motor_scooter"].includes(o.perfil) ? o.perfil : "motorcycle",
    shape_match: "map_snap", use_timestamps: true,
    trace_options: { search_radius: Math.min(100, Math.max(10, o.raio)), gps_accuracy: Math.min(60, Math.max(5, o.raio / 2)), turn_penalty_factor: 400, breakage_distance: 3000 },
    directions_options: { units: "kilometers" },
  });
  if (j === null) return undefined;
  const legs = (j.trip as { legs?: { shape?: string }[] } | undefined)?.legs;
  if (!legs?.length) return null;
  const linha: [number, number][] = [];
  for (const leg of legs) for (const [lat, lng] of decodificar(leg.shape ?? "", 1e6)) linha.push([+lat.toFixed(6), +lng.toFixed(6)]);
  return linha.length >= 2 ? linha : null;
}

/** OSRM: casamento em blocos de até 50 pings; sem casamento, a rota passando pelos pings. undefined = sem resposta. */
async function casarOsrm(pts: PingBruto[], o: Opcoes): Promise<[number, number][] | null | undefined> {
  const linha: [number, number][] = [];
  for (let i = 0; i < pts.length - 1; i += 49) {
    const parte = pts.slice(i, i + 50);
    const coords = parte.map((p) => `${p[2].toFixed(6)},${p[1].toFixed(6)}`).join(";");
    const ts: number[] = [];
    for (const p of parte) ts.push(Math.max(Math.round(p[5] / 1000), (ts[ts.length - 1] ?? 0) + 1));
    const raios = parte.map((p) => Math.min(60, Math.max(10, Math.round(Math.max(o.raio, (p[6] || 0) * 1.2))))).join(";");
    const j = await pedir(`${OSRM}/match/v1/driving/${coords}?overview=full&geometries=geojson&gaps=ignore&tidy=true&timestamps=${ts.join(";")}&radiuses=${raios}`);
    if (!j) return undefined;
    let pedaco: [number, number][] = [];
    if (j.code === "Ok" && Array.isArray(j.matchings)) {
      for (const m of j.matchings as { geometry?: { coordinates?: [number, number][] } }[]) for (const [lng, lat] of m.geometry?.coordinates ?? []) pedaco.push([+lat.toFixed(6), +lng.toFixed(6)]);
    }
    if (pedaco.length < 2) {
      pedaco = [];
      for (let k = 0; k < parte.length - 1; k += 24) {
        const sub = parte.slice(k, k + 25);
        const r = await pedir(`${OSRM}/route/v1/driving/${sub.map((p) => `${p[2].toFixed(6)},${p[1].toFixed(6)}`).join(";")}?overview=full&geometries=geojson`);
        const cs = (r?.code === "Ok" ? (r.routes as { geometry: { coordinates: [number, number][] } }[])[0]?.geometry.coordinates : null);
        if (!cs) return r ? null : undefined;
        for (const [lng, lat] of cs) pedaco.push([+lat.toFixed(6), +lng.toFixed(6)]);
      }
    }
    linha.push(...pedaco);
  }
  return linha.length >= 2 ? linha : null;
}

/** Casa um trecho com as ruas. null = o mapa não respondeu (tenta de novo depois); [] = não deu (fica com os pings). */
async function casar(pts: PingBruto[], o: Opcoes): Promise<[number, number][] | null> {
  const crus = pts.map((p) => [p[1], p[2]] as [number, number]);
  const real = comprimento(crus);
  if (real < 60) return [];
  // o provedor escolhido primeiro; se ele não responder ou não casar, o outro
  const ordem = o.provedor === "osrm" ? [casarOsrm, casarValhalla] : [casarValhalla, casarOsrm];
  let semResposta = false;
  for (const f of ordem) {
    const r = await f(pts, o);
    if (r === undefined) { semResposta = true; continue; }
    if (!r) continue;
    const linha = o.tiraVoltas ? tirarVoltas(r, o.voltaMax) : r;
    // traçado absurdo (desvio enorme perto do que os pings mostram): tenta o outro provedor
    if (comprimento(linha) > real * 2.2 + 600) continue;
    return linha;
  }
  return semResposta ? null : [];
}

const tamanhoTrecho = (o: Opcoes) => (o.provedor === "valhalla" ? 180 : 50);
const chaveTrecho = (pts: PingBruto[], o: Opcoes) =>
  `${pts[0][0]}|${pts[0][5]}|${pts[pts.length - 1][5]}|${pts.length}|v3${o.provedor[0]}${o.perfil[0]}${o.raio}${o.tiraVoltas ? "t" + o.voltaMax : "f"}`;

async function lerOpcoes(sb: SupabaseClient): Promise<Opcoes> {
  try {
    const { data } = await sb.from("configuracoes").select("chave,valor").in("chave",
      ["percurso_provedor", "percurso_perfil", "percurso_raio_m", "percurso_filtro_m", "percurso_vel_max_kmh", "percurso_tira_voltas", "percurso_volta_max_m"]);
    const c = Object.fromEntries((data ?? []).map((x) => [x.chave, x.valor])) as Record<string, unknown>;
    const n = (k: string, p: number) => (Number.isFinite(Number(c[k])) && c[k] != null ? Number(c[k]) : p);
    return {
      provedor: c.percurso_provedor === "osrm" ? "osrm" : "valhalla", perfil: typeof c.percurso_perfil === "string" ? c.percurso_perfil : PADRAO.perfil,
      raio: n("percurso_raio_m", PADRAO.raio), filtro: Math.max(3, n("percurso_filtro_m", PADRAO.filtro)), velMax: n("percurso_vel_max_kmh", PADRAO.velMax),
      tiraVoltas: c.percurso_tira_voltas !== false, voltaMax: n("percurso_volta_max_m", PADRAO.voltaMax),
    };
  } catch { return PADRAO; }
}

/** Monta a resposta: pings (com os das corridas antigas) e o caminho de cada registro pelas ruas. */
export async function montarPercursos(sb: SupabaseClient, dados: { pings?: PingBruto[]; legado?: Legado[] }, ajustar = true): Promise<RespostaPercursos> {
  const o = ajustar ? await lerOpcoes(sb) : PADRAO;
  const TAM = tamanhoTrecho(o);
  const pings = [...(dados.pings ?? []), ...(dados.legado ?? []).flatMap(pingsDoLegado)]
    .filter((p) => valida(p[1], p[2]))
    .sort((a, b) => (a[0] === b[0] ? a[5] - b[5] : a[0] < b[0] ? -1 : 1));
  const porMotoboy = new Map<string, PingBruto[]>();
  for (const p of pings) { const l = porMotoboy.get(p[0]); if (l) l.push(p); else porMotoboy.set(p[0], [p]); }

  // cada registro em trechos (o último ping de um é o primeiro do próximo)
  const regs = [...porMotoboy.values()].flatMap(registros).filter((r) => r.length >= 2);
  const trechosDe = regs.map((r) => {
    const e = enxugar(r, o);
    const t: PingBruto[][] = [];
    for (let i = 0; i < e.length - 1; i += TAM - 1) t.push(e.slice(i, i + TAM));
    return t.filter((x) => x.length >= 2);
  });

  const todas = trechosDe.flat().map((t) => chaveTrecho(t, o));
  const guardados: Record<string, [number, number][]> = {};
  for (let i = 0; ajustar && i < todas.length; i += 300) {
    const { data } = await sb.rpc("ler_trechos", { p_chaves: todas.slice(i, i + 300) });
    Object.assign(guardados, (data ?? {}) as Record<string, [number, number][]>);
  }

  let parcial = false;
  const faltam = ajustar ? trechosDe.flat().filter((t) => !(chaveTrecho(t, o) in guardados)) : [];
  if (faltam.length > MAX_TRECHOS_NOVOS) parcial = true;
  const novos: { chave: string; motoboy: string; caminho: [number, number][] }[] = [];
  const fila = faltam.slice(-MAX_TRECHOS_NOVOS).reverse(); // os mais recentes primeiro (é o que se olha)
  const prazo = Date.now() + 18_000; // responde a tempo (o app espera até 30 s); o resto fica para a próxima
  await Promise.all(Array.from({ length: 3 }, async () => {
    for (let t = fila.shift(); t; t = fila.shift()) {
      if (Date.now() > prazo) { parcial = true; break; }
      const c = await casar(t, o);
      if (c == null) { parcial = true; continue; }
      const chave = chaveTrecho(t, o);
      guardados[chave] = c;
      // o último trecho de um registro ainda em andamento muda: guarda só os trechos cheios ou já parados
      if (t.length === TAM || Date.now() - t[t.length - 1][5] > 30 * 60_000) novos.push({ chave, motoboy: t[0][0], caminho: c });
    }
  }));
  if (novos.length) await sb.rpc("guardar_trechos", { p_itens: novos });

  const ajustes: Record<string, Ajuste> = {};
  const linha: [number, number][] = [];
  regs.forEach((r, i) => {
    const partes = trechosDe[i].map((t) => {
      const c = guardados[chaveTrecho(t, o)];
      return c && c.length >= 2 ? c : t.map((p) => [p[1], p[2]] as [number, number]);
    });
    const caminho = partes.flat();
    const final = trechosDe[i].length ? trechosDe[i][trechosDe[i].length - 1] : r;
    if (caminho.length >= 2 && partes.some((_, k) => (guardados[chaveTrecho(trechosDe[i][k], o)]?.length ?? 0) >= 2)) {
      ajustes[`${r[0][0]}|${r[0][5]}`] = { ate: final[final.length - 1][5], caminho };
    }
    const ultimo = final[final.length - 1][5];
    linha.push(...(caminho.length >= 2 ? caminho : r.map((p) => [p[1], p[2]] as [number, number])));
    // pings depois do último usado no caminho (ex.: parado no fim) entram crus
    for (const p of r) if (p[5] > ultimo && metros(linha[linha.length - 1], [p[1], p[2]]) >= o.filtro) linha.push([p[1], p[2]]);
  });
  return { pings, ajustes, linha, parcial };
}
