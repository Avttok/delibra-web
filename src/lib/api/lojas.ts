import "server-only";
import { createHash } from "node:crypto";
import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";

/**
 * API pública para as lojas (clientes da transportadora): criar, consultar e cancelar pedidos.
 * A chave (dlb_…) vem em "Authorization: Bearer". Guardamos só o hash dela; o banco confere a chave
 * e age como a conta de cliente da loja, então valem as mesmas regras do site do cliente.
 */
export const VERSAO_API = "v1";

const STATUS_DO_ERRO: Record<string, number> = {
  limite_excedido: 429, chave_invalida: 401, api_desligada: 403, empresa_sem_acesso: 403, pedido_inexistente: 404, apenas_servidor: 500,
};
const TEXTO_DO_ERRO: Record<string, string> = {
  limite_excedido: "Chamadas demais neste minuto. Espere o minuto virar e tente de novo.",
  veiculo_nao_serve: "Veículo não aceito para este pedido.",
  chave_invalida: "Chave de API inválida ou cancelada.",
  api_desligada: "A API está desligada para esta transportadora.",
  empresa_sem_acesso: "A loja não tem uma conta de cliente ativa na transportadora.",
  pedido_inexistente: "Pedido não encontrado.",
  cliente_so_agendado: "Esta loja só pode fazer pedidos agendados: envie \"quando\".",
  cliente_sem_agendado: "Esta loja não pode agendar pedidos.",
  agendamento_longe_demais: "Data de agendamento além do limite da transportadora.",
  cliente_sem_urgente: "Esta loja não pode pedir urgência.",
  entregas_demais: "Entregas demais para um pedido.",
  coletas_demais: "Coletas demais para um pedido.",
  tipo_pedido_invalido: "Tipo de pedido inválido.",
};

export function resposta(dados: unknown, status = 200) {
  return Response.json(dados, { status, headers: { "cache-control": "no-store", "x-delibra-api": VERSAO_API } });
}

/** Erro do banco → resposta com o código e um texto em português. */
export function falha(mensagem: string) {
  const campo = /campo_(obrigatorio|invalido):([^\n]+)/.exec(mensagem);
  if (campo) return resposta({ erro: `campo_${campo[1]}`, mensagem: campo[1] === "obrigatorio" ? `Falta o campo "${campo[2].trim()}".` : `Valor inválido no campo "${campo[2].trim()}".` }, 422);
  const codigo = Object.keys({ ...STATUS_DO_ERRO, ...TEXTO_DO_ERRO }).find((k) => mensagem.includes(k)) ?? "pedido_invalido";
  return resposta({ erro: codigo, mensagem: TEXTO_DO_ERRO[codigo] ?? mensagem.slice(0, 200) }, STATUS_DO_ERRO[codigo] ?? 422);
}

/** Hash da chave enviada; null = sem chave no formato certo. */
export function hashDaChave(req: Request): string | null {
  const m = /^Bearer\s+(dlb_[a-f0-9]{64})\s*$/i.exec(req.headers.get("authorization") ?? "");
  return m ? createHash("sha256").update(m[1]).digest("hex") : null;
}

export function semChave() {
  return resposta({ erro: "chave_invalida", mensagem: "Envie a chave em Authorization: Bearer dlb_…" }, 401);
}

export function admin() {
  return adminConfigurado() ? supabaseAdmin() : null;
}

type PontoEntrada = { tipo?: string; endereco?: string; lat?: number; lng?: number; [k: string]: unknown };

let servidores: Promise<{ osrm: string; nominatim: string }> | null = null;
/** Servidores de mapa escolhidos pelo Dev (ou os públicos). */
function mapas() {
  servidores ??= (async () => {
    const padrao = { osrm: "https://router.project-osrm.org", nominatim: "https://nominatim.openstreetmap.org" };
    try { const { data } = await supabaseAdmin().rpc("servidores_mapa"); return { ...padrao, ...(data as object ?? {}) }; } catch { return padrao; }
  })();
  return servidores;
}

/** Endereço sem coordenadas: procura no mapa (Brasil). */
async function localizar(endereco: string): Promise<{ lat: number; lng: number } | null> {
  try {
    const r = await fetch(`${(await mapas()).nominatim}/search?format=json&limit=1&countrycodes=br&q=${encodeURIComponent(endereco)}`,
      { headers: { "User-Agent": "Delibra API (delibra.vercel.app)", "Accept-Language": "pt-BR" }, signal: AbortSignal.timeout(6000) });
    const j = (await r.json()) as { lat: string; lon: string }[];
    return j[0] ? { lat: Number(j[0].lat), lng: Number(j[0].lon) } : null;
  } catch { return null; }
}

/** Distância da rota passando pelos pontos na ordem (para o preço). */
async function distancia(pontos: { lat: number; lng: number }[]): Promise<number | null> {
  if (pontos.length < 2) return null;
  try {
    const coords = pontos.map((p) => `${p.lng.toFixed(6)},${p.lat.toFixed(6)}`).join(";");
    const r = await fetch(`${(await mapas()).osrm}/route/v1/driving/${coords}?overview=false`, { headers: { "User-Agent": "Delibra API" }, signal: AbortSignal.timeout(6000) });
    const j = (await r.json()) as { code?: string; routes?: { distance: number }[] };
    return j.code === "Ok" && j.routes?.[0] ? Math.round(j.routes[0].distance) : null;
  } catch { return null; }
}

/** Confere e completa o corpo do pedido vindo da loja. Retorna o texto do problema, se houver. */
export async function prepararPedido(corpo: Record<string, unknown>): Promise<{ dados?: Record<string, unknown>; problema?: string }> {
  const pontos = Array.isArray(corpo.pontos) ? (corpo.pontos as PontoEntrada[]) : [];
  if (pontos.length < 2) return { problema: "Envie pelo menos dois pontos: uma coleta e uma entrega." };
  if (pontos.length > 50) return { problema: "No máximo 50 pontos por pedido." };
  if (!pontos.some((p) => p.tipo === "coleta") || !pontos.some((p) => p.tipo === "entrega")) return { problema: "O pedido precisa de pelo menos uma coleta e uma entrega." };
  const prontos: PontoEntrada[] = [];
  for (const [i, p] of pontos.entries()) {
    if (p.tipo !== "coleta" && p.tipo !== "entrega") return { problema: `Ponto ${i + 1}: tipo deve ser "coleta" ou "entrega".` };
    let lat = Number(p.lat), lng = Number(p.lng);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      if (!p.endereco) return { problema: `Ponto ${i + 1}: envie o endereço ou lat e lng.` };
      const achou = await localizar(String(p.endereco));
      if (!achou) return { problema: `Ponto ${i + 1}: não achamos o endereço "${String(p.endereco).slice(0, 80)}". Envie lat e lng.` };
      ({ lat, lng } = achou);
    }
    prontos.push({ ...p, lat, lng, endereco: String(p.endereco ?? "").slice(0, 300), extras: p.extras && typeof p.extras === "object" ? p.extras : undefined });
  }
  const dist = Number(corpo.distancia_m);
  const dados: Record<string, unknown> = {
    quando: corpo.quando ?? null, urgente: corpo.urgente === true, tipo_pedido: corpo.tipo_pedido ?? undefined,
    metodo: corpo.metodo ?? null, observacoes: typeof corpo.observacoes === "string" ? corpo.observacoes.slice(0, 1000) : null,
    referencia_externa: typeof corpo.referencia_externa === "string" ? corpo.referencia_externa : null,
    extras: corpo.extras && typeof corpo.extras === "object" ? corpo.extras : {},
    veiculo: typeof corpo.veiculo === "string" ? corpo.veiculo : null,
    distancia_m: Number.isFinite(dist) && dist > 0 ? Math.round(dist) : await distancia(prontos as { lat: number; lng: number }[]),
    pontos: prontos,
    itens: Array.isArray(corpo.itens) ? corpo.itens.slice(0, 200) : [],
  };
  return { dados };
}
