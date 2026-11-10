import { adminConfigurado, gestorDaRequisicao, podeGerenciar, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Gestor define uma senha nova para alguém da equipe (ex.: motoboy esqueceu). */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  const gestor = await gestorDaRequisicao(req);
  if (!gestor) return Response.json({ erro: "apenas_gestor" }, { status: 403 });

  let c: { id?: string; senha?: string };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }
  if (!c.id || !/^[0-9a-f-]{36}$/i.test(c.id)) return Response.json({ erro: "usuario_invalido" }, { status: 400 });
  if (!(await podeGerenciar(req, c.id))) return Response.json({ erro: "conta_protegida" }, { status: 403 });
  if (String(c.senha ?? "").length < 8) return Response.json({ erro: "senha_curta" }, { status: 400 });

  const { error } = await supabaseAdmin().auth.admin.updateUserById(c.id, { password: String(c.senha) });
  if (error) return Response.json({ erro: "falha", detalhe: error.message }, { status: 500 });
  return Response.json({ ok: true });
}
