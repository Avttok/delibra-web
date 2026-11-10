import type { Endereco, ProvedorGeo, Referencia, Rota } from "./provedor";
import { poisDoMapa } from "@/lib/mapa/registro";

const NOMINATIM = "https://nominatim.openstreetmap.org";
const OSRM = "https://router.project-osrm.org";
const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];
const VALHALLA = "https://valhalla1.openstreetmap.de";

/** Provedor e perfil das rotas (vem de Configurações → rota_provedor / rota_perfil). */
export const preferenciaRota: { provedor: "valhalla" | "osrm"; perfil: string } = { provedor: "valhalla", perfil: "motorcycle" };
export function definirPreferenciaRota(provedor?: unknown, perfil?: unknown) {
  preferenciaRota.provedor = provedor === "osrm" ? "osrm" : "valhalla";
  if (typeof perfil === "string" && perfil) preferenciaRota.perfil = perfil;
}

function decodificar6(s: string): [number, number][] {
  const out: [number, number][] = [];
  let i = 0, lat = 0, lng = 0;
  while (i < s.length) {
    for (const k of [0, 1]) {
      let b, sh = 0, r = 0;
      do { b = s.charCodeAt(i++) - 63; r |= (b & 0x1f) << sh; sh += 5; } while (b >= 0x20 && i < s.length);
      const d = r & 1 ? ~(r >> 1) : r >> 1;
      if (k === 0) lat += d; else lng += d;
    }
    out.push([lat / 1e6, lng / 1e6]);
  }
  return out;
}
/** Polyline precisão 5 (o formato que o resto do sistema guarda). */
export function codificarPolyline(pts: [number, number][]): string {
  let o = "", pl = 0, pg = 0;
  const v = (x: number) => { x = x < 0 ? ~(x << 1) : x << 1; let t = ""; while (x >= 0x20) { t += String.fromCharCode((0x20 | (x & 0x1f)) + 63); x >>= 5; } return t + String.fromCharCode(x + 63); };
  for (const [lat, lng] of pts) { const a = Math.round(lat * 1e5), g = Math.round(lng * 1e5); o += v(a - pl) + v(g - pg); pl = a; pg = g; }
  return o;
}

async function rotaValhalla(pontos: { lat: number; lng: number }[], perfil: string): Promise<Rota | null> {
  const r = await fetch(`${VALHALLA}/route`, {
    method: "POST", headers: { "content-type": "application/json" }, signal: AbortSignal.timeout(6000),
    body: JSON.stringify({ locations: pontos.map((p) => ({ lat: p.lat, lon: p.lng })), costing: ["motorcycle", "auto", "bicycle", "motor_scooter"].includes(perfil) ? perfil : "motorcycle",
      directions_options: { units: "kilometers" }, directions_type: "none" }),
  });
  if (!r.ok) return null;
  const j = (await r.json()) as { trip?: { legs?: { shape: string }[]; summary?: { length: number; time: number } } };
  const legs = j.trip?.legs;
  if (!legs?.length || !j.trip?.summary) return null;
  const linha = legs.flatMap((l) => decodificar6(l.shape));
  if (linha.length < 2) return null;
  return { distanciaM: Math.round(j.trip.summary.length * 1000), duracaoS: Math.round(j.trip.summary.time), polyline: codificarPolyline(linha) };
}

const CACHE_DIST = new Map<string, number>();
/**
 * Distância pelas ruas da coleta até cada entrega (a coleta anterior na lista; sem ela, a primeira).
 * Alinhado com `pontos`: null nas coletas e onde o mapa não respondeu. É a base do preço "soma das entregas".
 */
export async function distanciasColetaEntrega(pontos: { tipo: "coleta" | "entrega"; lat: number | null; lng: number | null }[]): Promise<(number | null)[]> {
  let col = pontos.find((p) => p.tipo === "coleta" && p.lat != null) ?? null;
  const pares = pontos.map((p) => { if (p.tipo === "coleta") { if (p.lat != null) col = p; return null; } return col && p.lat != null ? [col, p] as const : null; });
  return Promise.all(pares.map(async (par) => {
    if (!par) return null;
    const k = `${par[0].lat},${par[0].lng}>${par[1].lat},${par[1].lng}|${preferenciaRota.provedor}${preferenciaRota.perfil}`;
    const tem = CACHE_DIST.get(k);
    if (tem != null) return tem;
    const r = await provedorOsm.calcularRota([{ lat: par[0].lat!, lng: par[0].lng! }, { lat: par[1].lat!, lng: par[1].lng! }]).catch(() => null);
    if (!r) return null;
    CACHE_DIST.set(k, r.distanciaM);
    return r.distanciaM;
  }));
}

/** Transporte não serve de referência (nomes de parada/rua). */
const FORA = new Set(["bus", "bus_stop", "bus_station", "platform", "stop_position", "tram_stop", "subway", "subway_entrance", "taxi", "parking", "parking_entrance", "bicycle_parking", "motorcycle_parking", "bicycle_rental"]);

const TIPOS: Record<string, string> = {
  fuel: "Posto", pharmacy: "Farmácia", supermarket: "Mercado", bank: "Banco", restaurant: "Restaurante", school: "Escola",
  hospital: "Hospital", church: "Igreja", place_of_worship: "Igreja", bakery: "Padaria", cafe: "Café", fast_food: "Lanchonete",
  convenience: "Conveniência", park: "Praça/parque", police: "Polícia", post_office: "Correios",
  grocery: "Mercado", clothes: "Loja", hairdresser: "Salão", beauty: "Salão", dentist: "Dentista", doctors: "Clínica", clinic: "Clínica",
  bar: "Bar", pub: "Bar", ice_cream: "Sorveteria", hotel: "Hotel", lodging: "Hotel", hardware: "Ferragem", doityourself: "Material de construção",
  car_repair: "Oficina", car: "Concessionária", butcher: "Açougue", optician: "Ótica", mall: "Shopping", department_store: "Loja",
  kindergarten: "Escola", college: "Faculdade", university: "Faculdade", townhall: "Prefeitura", library: "Biblioteca", gym: "Academia",
  fitness_centre: "Academia", veterinary: "Veterinário", pet: "Pet shop", atm: "Caixa eletrônico", post: "Correios", playground: "Praça/parque",
};

function metros(a: { lat: number; lng: number }, b: { lat: number; lng: number }) {
  const r = 6371000, rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad, dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(h));
}

// ------------------------------------------------------------- referências inteligentes

type Xy = { x: number; y: number };
interface Via { id: number; nome: string; pontos: Xy[] }

/** Plano local em metros (precisão de sobra num raio de poucas centenas de metros). */
function plano(lat0: number, lng0: number) {
  const kx = Math.cos((lat0 * Math.PI) / 180) * 111_320, ky = 110_540;
  return (lat: number, lng: number): Xy => ({ x: (lng - lng0) * kx, y: (lat - lat0) * ky });
}

/** Ponto mais próximo da via: distância, posição ao longo dela (m) e direção do trecho. */
function projetar(p: Xy, via: Via) {
  let melhor: { dist: number; ao_longo: number; dir: Xy; pe: Xy } | null = null;
  let acumulado = 0;
  for (let i = 0; i + 1 < via.pontos.length; i++) {
    const a = via.pontos[i], b = via.pontos[i + 1];
    const dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy;
    const l = Math.sqrt(l2);
    if (l < 0.5) continue;
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2));
    const pe = { x: a.x + t * dx, y: a.y + t * dy };
    const dist = Math.hypot(p.x - pe.x, p.y - pe.y);
    if (!melhor || dist < melhor.dist) melhor = { dist, ao_longo: acumulado + t * l, dir: { x: dx / l, y: dy / l }, pe };
    acumulado += l;
  }
  return melhor;
}

/**
 * Onde a referência fica em relação ao destino, olhando da rua para o destino.
 * Só responde quando a geometria é clara: mesma rua, os dois perto dela e fora do eixo.
 */
export function relacaoNaRua(destino: Xy, ref: Xy, vias: Via[]): "frente" | "esquerda" | "direita" | null {
  if (!vias.length) return null;
  const proj = vias.map((v) => ({ v, p: projetar(destino, v) })).filter((x) => x.p).sort((a, b) => a.p!.dist - b.p!.dist);
  const rua = proj[0];
  if (!rua?.p || rua.p.dist > 45 || rua.p.dist < 4) return null;
  // a referência precisa estar na mesma rua (a mais próxima dela também)
  const daRef = vias.map((v) => ({ v, p: projetar(ref, v) })).filter((x) => x.p).sort((a, b) => a.p!.dist - b.p!.dist)[0];
  if (!daRef?.p || daRef.v.nome !== rua.v.nome || daRef.p.dist > 45 || daRef.p.dist < 4) return null;
  const pRef = projetar(ref, rua.v)!;
  const lado = (p: Xy, pe: Xy, dir: Xy) => Math.sign(dir.x * (p.y - pe.y) - dir.y * (p.x - pe.x));
  const ladoDestino = lado(destino, rua.p.pe, rua.p.dir), ladoRef = lado(ref, pRef.pe, pRef.dir);
  const aoLongo = pRef.ao_longo - rua.p.ao_longo;
  const separacao = Math.abs(aoLongo);
  if (separacao > 120) return null;
  if (ladoDestino !== ladoRef) return separacao <= 30 ? "frente" : null;
  if (separacao < 10) return null;
  // olhando da rua para o destino: a "frente" é (destino − pé); a direita é ela girada −90°
  const fx = destino.x - rua.p.pe.x, fy = destino.y - rua.p.pe.y;
  const direita = { x: fy, y: -fx };
  const v = { x: pRef.pe.x - rua.p.pe.x, y: pRef.pe.y - rua.p.pe.y };
  const refADireita = v.x * direita.x + v.y * direita.y > 0;
  // a referência está à direita do destino → o destino fica à esquerda dela
  return refADireita ? "esquerda" : "direita";
}

interface ResultadoNominatim {
  display_name: string;
  lat: string;
  lon: string;
}

function encurtar(nome: string): string {
  // "Rua X, 123, Bairro, Cidade, Região, SC, 89000-000, Brasil" → até a cidade
  return nome.split(", ").filter((p) => p !== "Brasil" && p !== "Região Sul").slice(0, 5).join(", ");
}

export const provedorOsm: ProvedorGeo = {
  async pontosProximos(lat, lng, raioM = 250) {
    const q = `[out:json][timeout:10];(nwr(around:${raioM},${lat},${lng})[name][~"^(amenity|shop|leisure|tourism|office|healthcare|craft)$"~"."];);out center 60;way(around:${Math.min(raioM, 180)},${lat},${lng})[highway][name];out geom 40;`;
    const xy = plano(lat, lng);
    const destino = xy(lat, lng);
    const montar = (itens: { nome: string; lat: number; lng: number; tipo: string }[], vias: Via[]) => {
      const vistos = new Set<string>();
      return itens
        .filter((x) => !FORA.has(x.tipo))
        .map<Referencia>((x) => {
          let relacao: string | null = null;
          try {
            const r = relacaoNaRua(destino, xy(x.lat, x.lng), vias);
            relacao = r === "frente" ? `Fica do outro lado da rua de ${x.nome}` : r ? `Fica à ${r} de ${x.nome} (olhando da rua)` : null;
          } catch { relacao = null; }
          return { nome: x.nome, lat: x.lat, lng: x.lng, tipo: TIPOS[x.tipo] ?? null, distancia_m: Math.round(metros({ lat, lng }, { lat: x.lat, lng: x.lng })), relacao };
        })
        .filter((x) => !vistos.has(x.nome.toLowerCase()) && Boolean(vistos.add(x.nome.toLowerCase())))
        .sort((a, b) => (a.distancia_m ?? 0) - (b.distancia_m ?? 0))
        .slice(0, 8);
    };
    // 1) Overpass (vários espelhos: o principal vive lotado)
    for (const url of OVERPASS) {
      try {
        const ctl = new AbortController();
        const t = setTimeout(() => ctl.abort(), 9000);
        const r = await fetch(url, { method: "POST", body: new URLSearchParams({ data: q }), signal: ctl.signal });
        clearTimeout(t);
        if (!r.ok) continue;
        const j = (await r.json()) as { elements: { type: string; id: number; lat?: number; lon?: number; center?: { lat: number; lon: number }; geometry?: { lat: number; lon: number }[]; tags: Record<string, string> }[] };
        const vias: Via[] = j.elements.filter((e) => e.type === "way" && e.tags?.highway && e.geometry?.length)
          .map((e) => ({ id: e.id, nome: e.tags.name, pontos: e.geometry!.map((g) => xy(g.lat, g.lon)) }));
        const itens = j.elements.filter((e) => !(e.type === "way" && e.tags?.highway) && e.tags?.name).flatMap((e) => {
          const p = e.center ?? (e.lat != null && e.lon != null ? { lat: e.lat, lon: e.lon } : null);
          return p ? [{ nome: e.tags.name, lat: p.lat, lng: p.lon, tipo: e.tags.amenity ?? e.tags.shop ?? e.tags.leisure ?? e.tags.tourism ?? e.tags.office ?? e.tags.healthcare ?? e.tags.craft ?? "" }] : [];
        });
        const lista = montar(itens, vias);
        if (lista.length) return lista;
        break; // respondeu e não há nada: tenta o mapa
      } catch { /* espelho fora ou lento: próximo */ }
    }
    // 2) Reserva: o que o próprio mapa já carregou
    const { pois, vias } = poisDoMapa(lat, lng, raioM);
    return montar(pois.map((p) => ({ nome: p.nome, lat: p.lat, lng: p.lng, tipo: p.classe })),
      vias.map((v, i) => ({ id: i, nome: v.nome, pontos: v.pontos.map((g) => xy(g.lat, g.lng)) })));
  },

  async buscarEnderecos(texto) {
    if (texto.trim().length < 4) return [];
    const url = `${NOMINATIM}/search?format=jsonv2&countrycodes=br&limit=6&accept-language=pt-BR&q=${encodeURIComponent(texto)}`;
    const r = await fetch(url);
    if (!r.ok) return [];
    const lista = (await r.json()) as ResultadoNominatim[];
    return lista.map<Endereco>((x) => ({ descricao: encurtar(x.display_name), lat: Number(x.lat), lng: Number(x.lon) }));
  },

  async enderecoDoPonto(lat, lng) {
    const url = `${NOMINATIM}/reverse?format=jsonv2&accept-language=pt-BR&lat=${lat}&lon=${lng}`;
    try {
      const r = await fetch(url);
      if (!r.ok) throw new Error();
      const j = (await r.json()) as ResultadoNominatim;
      return encurtar(j.display_name);
    } catch {
      return `${lat.toFixed(5)}, ${lng.toFixed(5)}`;
    }
  },

  async calcularRota(pontos) {
    if (pontos.length < 2) return null;
    // provedor escolhido em Configurações (Valhalla tem perfil de moto); se não responder, o OSRM
    if (preferenciaRota.provedor === "valhalla") {
      const v = await rotaValhalla(pontos, preferenciaRota.perfil).catch(() => null);
      if (v) return v;
    }
    const coords = pontos.map((p) => `${p.lng},${p.lat}`).join(";");
    const r = await fetch(`${OSRM}/route/v1/driving/${coords}?overview=full&geometries=polyline`);
    if (!r.ok) return null;
    const j = (await r.json()) as { code: string; routes?: { distance: number; duration: number; geometry: string }[] };
    const rota = j.routes?.[0];
    if (j.code !== "Ok" || !rota) return null;
    return { distanciaM: Math.round(rota.distance), duracaoS: Math.round(rota.duration), polyline: rota.geometry } satisfies Rota;
  },
};
