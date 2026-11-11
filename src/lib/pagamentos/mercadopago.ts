import "server-only";

/**
 * Mercado Pago, só no servidor. O token de cada conta vem do banco (privado.pagamento_contas),
 * nunca do navegador. Toda notificação é conferida buscando o pagamento de novo na API.
 */
const API = "https://api.mercadopago.com";

async function chamar<T>(token: string, caminho: string, init?: RequestInit & { idem?: string }): Promise<{ ok: boolean; status: number; dados: T | null; erro?: string }> {
  const r = await fetch(`${API}${caminho}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`, "Content-Type": "application/json",
      ...(init?.idem ? { "X-Idempotency-Key": init.idem } : {}),
      ...(init?.headers ?? {}),
    },
    cache: "no-store",
  });
  const texto = await r.text();
  let dados: T | null = null;
  try { dados = texto ? (JSON.parse(texto) as T) : null; } catch { /* corpo não é JSON */ }
  const msg = (dados as { message?: string } | null)?.message;
  return { ok: r.ok, status: r.status, dados, erro: r.ok ? undefined : msg ?? `Mercado Pago respondeu ${r.status}` };
}

export interface PagamentoMp {
  id: number; status: string; status_detail?: string; transaction_amount: number; external_reference?: string;
  payment_type_id?: string; date_approved?: string | null;
  point_of_interaction?: { transaction_data?: { qr_code?: string; qr_code_base64?: string; ticket_url?: string } };
}

/** PIX: cria o pagamento e devolve o QR (copia e cola e a imagem). */
export async function criarPix(token: string, p: { valor: number; descricao: string; email: string; referencia: string; notificar: string; expiraMin: number }) {
  const expira = new Date(Date.now() + p.expiraMin * 60_000);
  return chamar<PagamentoMp>(token, "/v1/payments", {
    method: "POST", idem: p.referencia,
    body: JSON.stringify({
      transaction_amount: p.valor, description: p.descricao.slice(0, 250), payment_method_id: "pix",
      payer: { email: p.email }, external_reference: p.referencia, notification_url: p.notificar,
      date_of_expiration: expira.toISOString().replace("Z", "-00:00"),
    }),
  }).then((r) => ({ ...r, expira }));
}

/** Cartão: página segura do Mercado Pago (o cartão nunca passa por nós). */
export async function criarPreferencia(token: string, p: { valor: number; descricao: string; email: string; referencia: string; notificar: string; voltar: string }) {
  return chamar<{ id: string; init_point: string; sandbox_init_point?: string }>(token, "/checkout/preferences", {
    method: "POST", idem: p.referencia,
    body: JSON.stringify({
      items: [{ title: p.descricao.slice(0, 250), quantity: 1, unit_price: p.valor, currency_id: "BRL" }],
      payer: { email: p.email }, external_reference: p.referencia, notification_url: p.notificar,
      back_urls: { success: p.voltar, pending: p.voltar, failure: p.voltar }, auto_return: "approved",
      payment_methods: { excluded_payment_types: [{ id: "ticket" }, { id: "atm" }], installments: 12 },
      statement_descriptor: p.descricao.slice(0, 13),
    }),
  });
}

export const buscarPagamento = (token: string, id: string) => chamar<PagamentoMp>(token, `/v1/payments/${encodeURIComponent(id)}`);

/** O pagamento feito numa página de cartão (só se sabe pela referência). */
export async function buscarPorReferencia(token: string, referencia: string) {
  const r = await chamar<{ results: PagamentoMp[] }>(token, `/v1/payments/search?external_reference=${encodeURIComponent(referencia)}&sort=date_created&criteria=desc`);
  const lista = r.dados?.results ?? [];
  return lista.find((x) => x.status === "approved") ?? lista[0] ?? null;
}

export const testarConta = (token: string) => chamar<{ id: number; nickname?: string; email?: string; first_name?: string; site_id?: string }>(token, "/users/me");

/** O status do Mercado Pago no nosso vocabulário. */
export function traduzirStatus(s: string): "pendente" | "aprovado" | "recusado" | "cancelado" | "reembolsado" {
  switch (s) {
    case "approved": return "aprovado";
    case "rejected": return "recusado";
    case "cancelled": return "cancelado";
    case "refunded": case "charged_back": return "reembolsado";
    default: return "pendente"; // pending, in_process, authorized
  }
}
