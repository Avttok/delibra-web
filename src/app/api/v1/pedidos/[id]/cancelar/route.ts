import { uuidValido } from "@/lib/supabase/admin";
import { admin, falha, hashDaChave, resposta, semChave } from "@/lib/api/lojas";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** POST /api/v1/pedidos/{id}/cancelar  { "motivo": "…" } — vale a regra de cancelamento da transportadora. */
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const hash = hashDaChave(req);
  if (!hash) return semChave();
  const sb = admin();
  if (!sb) return resposta({ erro: "servidor_sem_chave" }, 503);
  const { id } = await ctx.params;
  if (!uuidValido(id)) return resposta({ erro: "pedido_inexistente", mensagem: "Pedido não encontrado." }, 404);
  const corpo = (await req.json().catch(() => ({}))) as { motivo?: string };
  const { data, error } = await sb.rpc("api_cancelar_pedido", { p_hash: hash, p_pedido: id, p_motivo: corpo.motivo ?? null });
  if (error) return falha(error.message);
  return resposta({ pedido: data });
}
