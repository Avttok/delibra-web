import "server-only";
import { supabaseAdmin } from "@/lib/supabase/admin";
import { buscarPagamento, buscarPorReferencia, traduzirStatus } from "./mercadopago";

/**
 * Confere um pagamento nosso no Mercado Pago e grava o resultado. Serve para o aviso do
 * Mercado Pago (webhook) e para o "Verificar agora". Nunca confia no que chegou: busca de novo.
 */
export async function conferirPagamento(ref: string, idNotificado?: string | null): Promise<{ status: string; erro?: string }> {
  const sb = supabaseAdmin();
  const { data: info, error } = await sb.rpc("pag_token_de", { p_pagamento: ref });
  const g = info as { token: string | null; provedor_id: string | null; status: string; valor: number; metodo: string } | null;
  if (error || !g) return { status: "desconhecido", erro: error?.message ?? "pagamento_nao_encontrado" };
  if (!g.token) return { status: g.status, erro: "conta_desligada" };
  if (g.status === "aprovado") return { status: "aprovado" };

  let pag = null;
  const id = idNotificado || g.provedor_id;
  if (id && g.metodo === "pix") pag = (await buscarPagamento(g.token, id)).dados;
  if (!pag) pag = await buscarPorReferencia(g.token, ref);
  if (!pag) return { status: g.status };
  // o pagamento tem que ser deste pedido e do valor certo
  if (pag.external_reference !== ref) return { status: g.status, erro: "referencia_diferente" };
  const novo = traduzirStatus(pag.status);
  if (novo === "aprovado" && Math.abs(Number(pag.transaction_amount) - Number(g.valor)) > 0.01) return { status: g.status, erro: "valor_diferente" };
  if (novo === g.status && String(pag.id) === g.provedor_id) return { status: novo };
  const { error: e2 } = await sb.rpc("pag_atualizar", {
    p_pagamento: ref, p_status: novo, p_provedor_id: String(pag.id),
    p_detalhe: { status_mp: pag.status, detalhe_mp: pag.status_detail ?? null, tipo_mp: pag.payment_type_id ?? null, aprovado_em: pag.date_approved ?? null },
  });
  return { status: novo, erro: e2?.message };
}
