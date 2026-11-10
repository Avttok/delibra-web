import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";

const OSRM = "https://router.project-osrm.org";
interface Parada { id: string; ordem: number; tipo: "coleta" | "entrega"; lat: number; lng: number; status: string }

async function json<T>(url: string): Promise<T | null> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(12000), headers: { "User-Agent": "Delibra-rotas" } });
    if (!r.ok) return null;
    const j = (await r.json()) as T & { code?: string };
    return j.code && j.code !== "Ok" ? null : j;
  } catch { return null; }
}
const coords = (ps: { lat: number; lng: number }[]) => ps.map((p) => `${p.lng},${p.lat}`).join(";");

const VALHALLA = "https://valhalla1.openstreetmap.de";
function dec6(s: string): [number, number][] {
  const out: [number, number][] = [];
  let i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    for (const k of [0, 1]) {
      let b, sh = 0, x = 0;
      do { b = s.charCodeAt(i++) - 63; x |= (b & 0x1f) << sh; sh += 5; } while (b >= 0x20 && i < s.length);
      const d = x & 1 ? ~(x >> 1) : x >> 1;
      if (k === 0) lat += d; else lng += d;
    }
    out.push([lat / 1e6, lng / 1e6]);
  }
  return out;
}
function enc5(pts: [number, number][]): string {
  let o = "", pl = 0, pg = 0;
  const v = (x: number) => { x = x < 0 ? ~(x << 1) : x << 1; let t = ""; while (x >= 0x20) { t += String.fromCharCode((0x20 | (x & 0x1f)) + 63); x >>= 5; } return t + String.fromCharCode(x + 63); };
  for (const [lat, lng] of pts) { const a = Math.round(lat * 1e5), g = Math.round(lng * 1e5); o += v(a - pl) + v(g - pg); pl = a; pg = g; }
  return o;
}
async function rotaValhalla(seq: { lat: number; lng: number }[], perfil: string): Promise<{ distance: number; duration: number; geometry: string; legs: { distance: number }[] } | null> {
  try {
    const resp = await fetch(`${VALHALLA}/route`, { method: "POST", headers: { "content-type": "application/json", "User-Agent": "Delibra-rotas" }, signal: AbortSignal.timeout(9000),
      body: JSON.stringify({ locations: seq.map((p) => ({ lat: p.lat, lon: p.lng })), costing: ["motorcycle", "auto", "bicycle", "motor_scooter"].includes(perfil) ? perfil : "motorcycle",
        directions_options: { units: "kilometers" }, directions_type: "none" }) });
    if (!resp.ok) return null;
    const j = (await resp.json()) as { trip?: { legs?: { shape: string; summary: { length: number } }[]; summary?: { length: number; time: number } } };
    const legs = j.trip?.legs;
    if (!legs || legs.length !== seq.length - 1 || !j.trip?.summary) return null;
    return { distance: j.trip.summary.length * 1000, duration: j.trip.summary.time, geometry: enc5(legs.flatMap((l) => dec6(l.shape))), legs: legs.map((l) => ({ distance: l.summary.length * 1000 })) };
  } catch { return null; }
}

/**
 * Otimiza uma rota pelas ruas: mantém as coletas primeiro (na ordem do roteirizador), acha a melhor
 * ordem das entregas (OSRM trip), calcula a distância por ruas da 1ª coleta até cada entrega (OSRM table)
 * e os km acumulados na rota (OSRM route). Devolve false se o mapa não respondeu.
 */
export async function otimizarRota(sb: SupabaseClient, corridaId: string, paradas: Parada[]): Promise<boolean> {
  const ord = [...paradas].sort((a, b) => a.ordem - b.ordem);
  if (ord.some((p) => p.status !== "pendente")) return true;
  const coletas = ord.filter((p) => p.tipo === "coleta");
  let entregas = ord.filter((p) => p.tipo === "entrega");
  if (!coletas.length || !entregas.length) return true;

  // melhor ordem das entregas saindo da última coleta
  if (entregas.length > 1) {
    const ultima = coletas[coletas.length - 1];
    const trip = await json<{ waypoints: { waypoint_index: number }[] }>(
      `${OSRM}/trip/v1/driving/${coords([ultima, ...entregas])}?source=first&destination=any&roundtrip=false&overview=false`);
    if (trip?.waypoints?.length === entregas.length + 1) {
      const pos = trip.waypoints.slice(1).map((w, i) => ({ p: entregas[i], k: w.waypoint_index }));
      entregas = pos.sort((a, b) => a.k - b.k).map((x) => x.p);
    }
  }
  const seq = [...coletas, ...entregas];
  // traçado e distâncias: o provedor escolhido (Valhalla com perfil de moto evita caminhos onde moto não passa); senão OSRM
  const { data: cfg } = await sb.from("configuracoes").select("chave,valor").in("chave", ["rota_provedor", "rota_perfil"]);
  const conf = Object.fromEntries((cfg ?? []).map((x) => [x.chave, x.valor])) as Record<string, unknown>;
  let r = conf.rota_provedor === "osrm" ? null : await rotaValhalla(seq, typeof conf.rota_perfil === "string" ? conf.rota_perfil : "motorcycle");
  if (!r) {
    const rota = await json<{ routes: { distance: number; duration: number; geometry: string; legs: { distance: number }[] }[] }>(
      `${OSRM}/route/v1/driving/${coords(seq)}?overview=full&geometries=polyline`);
    r = rota?.routes?.[0] ?? null;
  }
  if (!r) return false;
  const tabela = await json<{ distances: (number | null)[][] }>(
    `${OSRM}/table/v1/driving/${coords([coletas[0], ...entregas])}?sources=0&annotations=distance`);
  const diretas = tabela?.distances?.[0]?.slice(1) ?? null;

  const acum: number[] = [];
  let soma = 0;
  seq.forEach((_, i) => { if (i > 0) soma += r.legs[i - 1]?.distance ?? 0; acum.push(Math.round(soma)); });
  const rua = seq.map((p) => {
    if (p.tipo !== "entrega") return null;
    const d = diretas?.[entregas.indexOf(p)];
    return d == null ? null : Math.round(d);
  });
  const { error } = await sb.rpc("aplicar_otimizacao", {
    p_corrida: corridaId, p_ordem: seq.map((p) => p.id), p_rua: rua, p_acum: acum,
    p_total: Math.round(r.distance), p_duracao: Math.round(r.duration) + seq.length * 180, p_polyline: r.geometry,
  });
  if (error) console.error("aplicar_otimizacao", corridaId, error.message);
  return !error;
}
