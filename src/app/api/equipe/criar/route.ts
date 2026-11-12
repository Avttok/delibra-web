import { adminConfigurado, clienteDoUsuario, ehDev, gestorDaRequisicao, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const PAPEIS = ["gestor", "supervisor", "motoboy", "dev", "cliente"] as const;

/**
 * Cria uma conta já confirmada, dentro da empresa de quem chamou (o Dev escolhe a empresa).
 * Gestor cria qualquer cargo da empresa dele; supervisor só motoboys e clientes (se o gestor deixou).
 */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  const gestor = await gestorDaRequisicao(req);
  if (!gestor) return Response.json({ erro: "apenas_gestor" }, { status: 403 });

  let c: { email?: string; senha?: string; nome?: string; papeis?: string[]; repasse?: number | null; empresa_id?: string | null; organizacao_id?: string | null };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }

  const email = String(c.email ?? "").trim().toLowerCase();
  const nome = String(c.nome ?? "").trim();
  const senha = String(c.senha ?? "");
  const papeis = (c.papeis ?? []).filter((p): p is (typeof PAPEIS)[number] => (PAPEIS as readonly string[]).includes(p));
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return Response.json({ erro: "email_invalido" }, { status: 400 });
  if (nome.length < 2 || nome.length > 60) return Response.json({ erro: "nome_invalido" }, { status: 400 });
  if (senha.length < 8) return Response.json({ erro: "senha_curta" }, { status: 400 });
  if (papeis.length === 0) return Response.json({ erro: "sem_papel" }, { status: 400 });
  const dev = await ehDev(req);
  if (papeis.includes("dev") && !dev) return Response.json({ erro: "apenas_dev" }, { status: 403 });
  const sbUsuario = clienteDoUsuario(req)!;
  const [{ data: pleno }, { data: podeCadastrar }, { data: minhaOrg }] = await Promise.all([
    sbUsuario.rpc("is_gestor_pleno"), sbUsuario.rpc("pode", { p_acao: "cadastrar" }), sbUsuario.rpc("minha_org"),
  ]);
  if (podeCadastrar !== true) return Response.json({ erro: "sem_permissao" }, { status: 403 });
  const { data: posso } = await sbUsuario.rpc("posso", { p_acao: "criar_contas" });
  if (posso === false) return Response.json({ erro: "acao_bloqueada" }, { status: 403 });
  if ((papeis.includes("gestor") || papeis.includes("supervisor")) && pleno !== true) return Response.json({ erro: "apenas_gestor" }, { status: 403 });
  // empresa da conta nova: a de quem chamou; o Dev pode escolher qualquer uma
  const organizacaoId = dev && uuidValido(c.organizacao_id) ? c.organizacao_id : (typeof minhaOrg === "string" ? minhaOrg : null);
  if (!organizacaoId && !papeis.includes("dev")) return Response.json({ erro: "sem_empresa" }, { status: 400 });
  // conta de cliente: só esse papel, ligada a um cliente cadastrado
  const empresaId = papeis.includes("cliente") ? String(c.empresa_id ?? "") : "";
  if (papeis.includes("cliente") && !/^[0-9a-f-]{36}$/i.test(empresaId)) return Response.json({ erro: "cliente_sem_cadastro" }, { status: 400 });
  const repasse = c.repasse == null ? null : Number(c.repasse);
  if (repasse != null && (Number.isNaN(repasse) || repasse < 0 || repasse > 100)) return Response.json({ erro: "percentual_invalido" }, { status: 400 });

  // só o Dev cria gestor; e cada cargo respeita as vagas da empresa (o Dev define)
  if (papeis.includes("gestor") && !dev) return Response.json({ erro: "apenas_dev_cria_gestor" }, { status: 403 });
  if (organizacaoId) {
    const { data: vagas } = await sbUsuario.rpc("vagas_da_equipe", { p_org: organizacaoId });
    const v = (vagas ?? {}) as Record<string, { pode?: boolean; limite?: number | null }>;
    const sem = papeis.find((pp) => v[pp]?.pode === false);
    if (sem) return Response.json({ erro: `limite_${sem === "gestor" ? "gestores" : sem === "supervisor" ? "supervisores" : "motoboys"}_do_plano` }, { status: 409 });
  }

  const admin = supabaseAdmin();
  const { data, error } = await admin.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome } });
  if (error || !data.user) {
    const existe = /already|registered|exists/i.test(error?.message ?? "");
    return Response.json({ erro: existe ? "email_existe" : "falha_ao_criar", detalhe: error?.message }, { status: existe ? 409 : 500 });
  }
  const id = data.user.id;

  // perfil nasce pelo gatilho do banco; aqui só definimos nome e papéis
  const p = await admin.from("perfis").upsert({ id, nome, papeis, organizacao_id: organizacaoId, responsavel_id: gestor, ...(empresaId ? { empresa_id: empresaId } : {}) });
  if (p.error) {
    await admin.auth.admin.deleteUser(id).catch(() => null);
    const limite = /limite_\w+_do_plano|apenas_dev_cria_gestor/.exec(p.error.message)?.[0];
    return Response.json({ erro: limite ?? "falha_no_perfil", detalhe: limite ? undefined : p.error.message }, { status: limite ? 409 : 500 });
  }
  if (papeis.includes("motoboy")) {
    const m = await admin.from("motoboys").upsert({ id, repasse_pct: repasse });
    if (m.error) return Response.json({ erro: "falha_no_motoboy", detalhe: m.error.message, id }, { status: 500 });
  }
  return Response.json({ ok: true, id });
}

/** Diagnóstico: mostra se a chave secreta está configurada (sem revelar o valor). */
export async function GET() {
  return Response.json({ SUPABASE_SECRET_KEY: adminConfigurado() });
}
