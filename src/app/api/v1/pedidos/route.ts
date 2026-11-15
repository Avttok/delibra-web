import { admin, falha, hashDaChave, prepararPedido, resposta, semChave } from "@/lib/api/lojas";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /api/v1/pedidos?desde=ISO&status=…&limite=50 — pedidos da loja (30 dias por padrão). */
export async function GET(req: Request) {
  const hash = hashDaChave(req);
  if (!hash) return semChave();
  const sb = admin();
  if (!sb) return resposta({ erro: "servidor_sem_chave" }, 503);
  const u = new URL(req.url);
  const desde = u.searchParams.get("desde");
  const { data, error } = await sb.rpc("api_pedidos", {
    p_hash: hash, p_desde: desde && !Number.isNaN(Date.parse(desde)) ? new Date(desde).toISOString() : null,
    p_status: u.searchParams.get("status") || null, p_limite: Number(u.searchParams.get("limite")) || 50,
  });
  if (error) return falha(error.message);
  return resposta({ pedidos: data });
}

/** POST /api/v1/pedidos — cria um pedido. Mesmo "referencia_externa" não cria outro (devolve o que já existe). */
export async function POST(req: Request) {
  const hash = hashDaChave(req);
  if (!hash) return semChave();
  const sb = admin();
  if (!sb) return resposta({ erro: "servidor_sem_chave" }, 503);
  let corpo: Record<string, unknown>;
  try { corpo = (await req.json()) as Record<string, unknown>; } catch { return resposta({ erro: "json_invalido", mensagem: "O corpo precisa ser JSON." }, 400); }
  const { dados, problema } = await prepararPedido(corpo ?? {});
  if (problema) return resposta({ erro: "pedido_invalido", mensagem: problema }, 422);
  const { data, error } = await sb.rpc("api_criar_pedido", { p_hash: hash, p_dados: dados });
  if (error) return falha(error.message);
  const repetido = (data as { repetido?: boolean })?.repetido === true;
  return resposta({ pedido: data }, repetido ? 200 : 201);
}
