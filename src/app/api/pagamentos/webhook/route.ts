import { adminConfigurado, uuidValido } from "@/lib/supabase/admin";
import { conferirPagamento } from "@/lib/pagamentos/conferir";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Aviso do Mercado Pago. Não confiamos no corpo: só usamos a nossa referência (na URL) e o id
 * do pagamento para buscar de novo na API, com o token da conta certa. Sempre responde 200
 * (senão o Mercado Pago fica reenviando).
 */
async function tratar(req: Request) {
  const url = new URL(req.url);
  const ref = url.searchParams.get("ref");
  if (!adminConfigurado() || !uuidValido(ref)) return Response.json({ ok: true });
  let corpo: { type?: string; topic?: string; data?: { id?: string | number }; resource?: string } = {};
  try { corpo = await req.json(); } catch { /* GET ou sem corpo */ }
  const tipo = corpo.type ?? corpo.topic ?? url.searchParams.get("type") ?? url.searchParams.get("topic");
  if (tipo && !["payment", "merchant_order"].includes(tipo)) return Response.json({ ok: true });
  const id = corpo.data?.id ?? url.searchParams.get("data.id") ?? (tipo === "payment" ? url.searchParams.get("id") : null);
  try {
    const r = await conferirPagamento(ref, id != null && /^\d+$/.test(String(id)) ? String(id) : null);
    return Response.json({ ok: true, status: r.status });
  } catch (e) {
    console.error("webhook mercado pago", e);
    return Response.json({ ok: true });
  }
}
export const POST = tratar;
export const GET = tratar;
