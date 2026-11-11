import { adminConfigurado, clienteDoUsuario, uuidValido } from "@/lib/supabase/admin";
import { conferirPagamento } from "@/lib/pagamentos/conferir";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** "Verificar agora" (cliente, gestor no site ou no app): confere no Mercado Pago o pagamento que a pessoa enxerga. */
export async function POST(req: Request) {
  const sb = clienteDoUsuario(req);
  if (!sb || !adminConfigurado()) return Response.json({ erro: "nao_autorizado" }, { status: 401 });
  let corpo: { id?: string; pedido_id?: string } = {};
  try { corpo = await req.json(); } catch { /* vazio */ }
  // pelas regras do banco: só acha se a pessoa pode ver este pagamento
  let q = sb.from("pagamentos").select("id,status").order("criado_em", { ascending: false }).limit(1);
  if (uuidValido(corpo.id)) q = q.eq("id", corpo.id);
  else if (uuidValido(corpo.pedido_id)) q = q.eq("pedido_id", corpo.pedido_id);
  else return Response.json({ erro: "id_invalido" }, { status: 400 });
  const { data } = await q.maybeSingle();
  if (!data) return Response.json({ status: "sem_pagamento" });
  const r = await conferirPagamento(data.id as string);
  return Response.json({ id: data.id, status: r.status, erro: r.erro });
}
