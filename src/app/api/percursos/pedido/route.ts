import { createClient } from "@supabase/supabase-js";
import { montarPercursos } from "@/lib/percursos/ajustar";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const uuid = (v: unknown): v is string => typeof v === "string" && /^[0-9a-f-]{36}$/i.test(v);

/**
 * Trajeto feito do pedido do cliente, traçado pelas ruas. Corpo: { pedido }.
 * O banco só devolve o trecho do próprio pedido (da coleta à última entrega) e só se a empresa vê ao vivo.
 */
export async function POST(req: Request) {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL, chave = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!token || !url || !chave) return Response.json({ erro: "nao_autenticado" }, { status: 401 });
  const sb = createClient(url, chave, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: `Bearer ${token}` } } });
  let c: { pedido?: string } = {};
  try { c = await req.json(); } catch { /* sem corpo */ }
  if (!uuid(c.pedido)) return Response.json({ erro: "pedido_invalido" }, { status: 400 });
  const { data, error } = await sb.rpc("pings_pedido_cliente", { p_pedido: c.pedido });
  if (error) return Response.json({ erro: error.message }, { status: 400 });
  return Response.json(await montarPercursos(sb, data ?? {}));
}
