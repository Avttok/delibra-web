import { adminConfigurado, gestorDaRequisicao, podeGerenciar, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Bloqueia (ou libera) o acesso de alguém. Bloqueado não entra no app nem no painel. */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  const gestor = await gestorDaRequisicao(req);
  if (!gestor) return Response.json({ erro: "apenas_gestor" }, { status: 403 });

  let c: { id?: string; bloquear?: boolean };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }
  if (!uuidValido(c.id)) return Response.json({ erro: "usuario_invalido" }, { status: 400 });
  if (!(await podeGerenciar(req, c.id))) return Response.json({ erro: "conta_protegida" }, { status: 403 });
  if (c.id === gestor) return Response.json({ erro: "nao_bloqueie_a_si_mesmo" }, { status: 400 });

  const admin = supabaseAdmin();
  if (c.bloquear) {
    const { data: ativa } = await admin.from("corridas").select("id").eq("motoboy_id", c.id).in("status", ["aceita", "em_andamento"]).limit(1);
    if (ativa?.length) return Response.json({ erro: "membro_em_corrida" }, { status: 400 });
  }
  // ~100 anos = bloqueado até alguém liberar
  const { error } = await admin.auth.admin.updateUserById(c.id, { ban_duration: c.bloquear ? "876000h" : "none" });
  if (error) return Response.json({ erro: "falha", detalhe: error.message }, { status: 500 });
  if (c.bloquear) {
    await admin.from("motoboys").update({ status: "offline", status_em: new Date().toISOString() }).eq("id", c.id);
  }
  return Response.json({ ok: true });
}
