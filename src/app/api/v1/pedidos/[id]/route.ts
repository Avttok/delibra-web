import { uuidValido } from "@/lib/supabase/admin";
import { admin, falha, hashDaChave, resposta, semChave } from "@/lib/api/lojas";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /api/v1/pedidos/{id} — também aceita a referência da loja: /api/v1/pedidos/ref:PED-123 */
export async function GET(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const hash = hashDaChave(req);
  if (!hash) return semChave();
  const sb = admin();
  if (!sb) return resposta({ erro: "servidor_sem_chave" }, 503);
  const { id } = await ctx.params;
  const ref = decodeURIComponent(id).startsWith("ref:") ? decodeURIComponent(id).slice(4) : null;
  if (!ref && !uuidValido(id)) return resposta({ erro: "pedido_inexistente", mensagem: "Pedido não encontrado." }, 404);
  const { data, error } = await sb.rpc("api_pedido", { p_hash: hash, p_pedido: ref ? null : id, p_referencia: ref });
  if (error) return falha(error.message);
  return resposta({ pedido: data });
}
