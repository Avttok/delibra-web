import { adminConfigurado, clienteDoUsuario, ehDev, supabaseAdmin } from "@/lib/supabase/admin";
import { testarConta } from "@/lib/pagamentos/mercadopago";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Testa a conta Mercado Pago ligada (da empresa de quem chamou, ou a da plataforma para o Dev). */
export async function POST(req: Request) {
  const sb = clienteDoUsuario(req);
  if (!sb || !adminConfigurado()) return Response.json({ erro: "nao_autorizado" }, { status: 401 });
  let corpo: { plataforma?: boolean } = {};
  try { corpo = await req.json(); } catch { /* vazio */ }
  let org: string | null = null;
  if (corpo.plataforma) {
    if (!(await ehDev(req))) return Response.json({ erro: "apenas_dev" }, { status: 403 });
  } else {
    const { data: g } = await sb.rpc("is_gestor_pleno");
    if (g !== true) return Response.json({ erro: "apenas_gestor" }, { status: 403 });
    const { data } = await sb.rpc("minha_org");
    org = (data as string | null) ?? null;
    if (!org) return Response.json({ erro: "sem_empresa" }, { status: 400 });
  }
  const admin = supabaseAdmin();
  const { data: token } = await admin.rpc("pag_token_conta", { p_org: org });
  if (!token) return Response.json({ ok: false, erro: "Nenhuma conta ligada." });
  const r = await testarConta(token as string);
  if (!r.ok || !r.dados) return Response.json({ ok: false, erro: r.status === 401 ? "O Mercado Pago recusou o token (confira se copiou o Access Token de produção inteiro)." : r.erro });
  const nome = [r.dados.nickname, r.dados.email].filter(Boolean).join(" · ") || `Conta ${r.dados.id}`;
  await admin.rpc("pag_nome_conta", { p_org: org, p_nome: nome });
  return Response.json({ ok: true, nome, pais: r.dados.site_id });
}
