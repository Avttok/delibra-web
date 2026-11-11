import { randomUUID } from "node:crypto";
import { adminConfigurado, clienteDoUsuario, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";
import { criarPix, criarPreferencia } from "@/lib/pagamentos/mercadopago";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const ERROS: Record<string, string> = {
  nada_a_pagar: "Este pedido não está esperando pagamento.",
  sem_valor: "O pedido ainda não tem valor.",
  sem_permissao: "Você não pode pagar este pedido.",
  conta_nao_ligada: "A empresa ainda não ligou o recebimento online. Fale com ela.",
};

/** Cliente (ou gestor) pede para pagar um pedido pré-pago ou uma fatura: PIX (QR na hora) ou cartão (página do Mercado Pago). */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "O site ainda não está configurado para pagamentos." }, { status: 500 });
  const sbUser = clienteDoUsuario(req);
  const jwt = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!sbUser || !jwt) return Response.json({ erro: "Entre na sua conta para pagar." }, { status: 401 });
  const { data: u } = await sbUser.auth.getUser(jwt);
  if (!u.user) return Response.json({ erro: "Sessão expirada. Entre de novo." }, { status: 401 });

  let corpo: { alvo?: string; id?: string; metodo?: string } = {};
  try { corpo = await req.json(); } catch { /* vazio */ }
  const alvo = corpo.alvo === "fatura" ? "fatura" : "pedido";
  const metodo = corpo.metodo === "cartao" ? "cartao" : "pix";
  if (!uuidValido(corpo.id)) return Response.json({ erro: "Pedido inválido." }, { status: 400 });

  const sb = supabaseAdmin();
  const { data, error } = await sb.rpc("pag_preparar", { p_alvo: alvo, p_id: corpo.id, p_usuario: u.user.id });
  if (error) return Response.json({ erro: error.message }, { status: 500 });
  const p = data as { erro?: string; token: string; destino: string; organizacao_id: string; empresa_id: string; valor: number; descricao: string; email: string | null;
    pix_aberto: { id: string; qr_code: string; qr_base64: string; expira_em: string; valor: number } | null };
  if (p.erro) return Response.json({ erro: ERROS[p.erro] ?? p.erro }, { status: 400 });

  // PIX ainda válido para o mesmo valor: reaproveita (não gera outro QR)
  if (metodo === "pix" && p.pix_aberto) return Response.json({ id: p.pix_aberto.id, metodo, qr_code: p.pix_aberto.qr_code, qr_base64: p.pix_aberto.qr_base64, expira_em: p.pix_aberto.expira_em, valor: p.pix_aberto.valor });

  const origem = process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") || new URL(req.url).origin;
  const ref = randomUUID();
  const notificar = `${origem}/api/pagamentos/webhook?ref=${ref}`;
  const email = p.email || "cliente@delibra.app";
  const base = { id: ref, organizacao_id: p.organizacao_id, empresa_id: p.empresa_id, alvo, pedido_id: alvo === "pedido" ? corpo.id : null, fatura_id: alvo === "fatura" ? corpo.id : null,
    metodo, destino: p.destino, valor: p.valor };

  if (metodo === "pix") {
    const r = await criarPix(p.token, { valor: Number(p.valor), descricao: p.descricao, email, referencia: ref, notificar, expiraMin: 30 });
    const t = r.dados?.point_of_interaction?.transaction_data;
    if (!r.ok || !t?.qr_code) return Response.json({ erro: `Não deu para gerar o PIX: ${r.erro ?? "tente de novo"}.` }, { status: 502 });
    const { error: e } = await sb.rpc("pag_registrar", { p: { ...base, provedor_id: String(r.dados!.id), qr_code: t.qr_code, qr_base64: t.qr_code_base64, expira_em: r.expira.toISOString() } });
    if (e) return Response.json({ erro: e.message }, { status: 500 });
    return Response.json({ id: ref, metodo, qr_code: t.qr_code, qr_base64: t.qr_code_base64, expira_em: r.expira.toISOString(), valor: p.valor });
  }
  const voltar = `${origem}/cliente?pagamento=${ref}`;
  const r = await criarPreferencia(p.token, { valor: Number(p.valor), descricao: p.descricao, email, referencia: ref, notificar, voltar });
  const link = r.dados?.init_point;
  if (!r.ok || !link) return Response.json({ erro: `Não deu para abrir o pagamento com cartão: ${r.erro ?? "tente de novo"}.` }, { status: 502 });
  const { error: e } = await sb.rpc("pag_registrar", { p: { ...base, link, detalhe: { preferencia: r.dados!.id } } });
  if (e) return Response.json({ erro: e.message }, { status: 500 });
  return Response.json({ id: ref, metodo, link, valor: p.valor });
}
