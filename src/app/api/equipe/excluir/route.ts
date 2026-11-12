import { adminConfigurado, clienteDoUsuario, gestorDaRequisicao, podeGerenciar, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Exclui uma conta de vez. A senha do gestor é conferida no banco (preparar_exclusao_conta),
 * que também arquiva o nome nas corridas e guarda uma cópia do perfil. Depois disso apaga no Auth.
 */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  const gestor = await gestorDaRequisicao(req);
  const sb = clienteDoUsuario(req);
  if (!gestor || !sb) return Response.json({ erro: "apenas_gestor" }, { status: 403 });

  let c: { id?: string; senha?: string; motivo?: string };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }
  if (!uuidValido(c.id)) return Response.json({ erro: "usuario_invalido" }, { status: 400 });
  if (!(await podeGerenciar(req, c.id))) return Response.json({ erro: "conta_protegida" }, { status: 403 });
  if (c.id === gestor) return Response.json({ erro: "nao_exclua_a_si_mesmo" }, { status: 400 });
  const { data: posso } = await sb.rpc("posso", { p_acao: "excluir_contas" });
  if (posso === false) return Response.json({ erro: "acao_bloqueada" }, { status: 403 });

  const { data, error } = await sb.rpc("preparar_exclusao_conta", { p_usuario: c.id, p_senha: c.senha ?? "", p_motivo: c.motivo ?? null });
  if (error) return Response.json({ erro: "falha", detalhe: error.message }, { status: 500 });
  const r = data as { ok?: boolean; erro?: string; restantes?: number };
  if (!r?.ok) return Response.json({ erro: r?.erro ?? "falha", restantes: r?.restantes }, { status: 400 });

  const admin = supabaseAdmin();
  // fotos de perfil da pessoa
  const { data: fotos } = await admin.storage.from("avatares").list(c.id);
  if (fotos?.length) await admin.storage.from("avatares").remove(fotos.map((f) => `${c.id}/${f.name}`));

  const del = await admin.auth.admin.deleteUser(c.id);
  if (del.error) return Response.json({ erro: "falha_ao_excluir", detalhe: del.error.message }, { status: 500 });
  return Response.json({ ok: true });
}
