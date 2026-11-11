import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const tentativas = new Map<string, number[]>();
function muitas(ip: string) {
  const agora = Date.now();
  const l = (tentativas.get(ip) ?? []).filter((t) => agora - t < 60 * 60_000);
  l.push(agora); tentativas.set(ip, l);
  return l.length > 4;
}

/** Empresa nova começa o teste grátis (só quando o Dev abriu o cadastro). Cria o login do dono e a empresa. */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "O site ainda não está pronto para cadastros." }, { status: 500 });
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "?";
  if (muitas(ip)) return Response.json({ erro: "Muitas tentativas. Tente de novo mais tarde." }, { status: 429 });
  let c: { empresa?: string; documento?: string; nome?: string; email?: string; senha?: string; telefone?: string; site?: string } = {};
  try { c = await req.json(); } catch { /* vazio */ }
  if (c.site) return Response.json({ ok: true }); // robô (campo escondido preenchido)
  const email = (c.email ?? "").trim().toLowerCase();
  if (!c.empresa?.trim() || !c.nome?.trim()) return Response.json({ erro: "Preencha o nome da empresa e o seu." }, { status: 400 });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return Response.json({ erro: "E-mail inválido." }, { status: 400 });
  if ((c.senha ?? "").length < 8) return Response.json({ erro: "A senha precisa de pelo menos 8 caracteres." }, { status: 400 });

  const sb = supabaseAdmin();
  const { data: aberto } = await sb.rpc("cadastro_empresas_aberto");
  if (!(aberto as { aberto?: boolean } | null)?.aberto) return Response.json({ erro: "O cadastro de empresas está fechado no momento. Fale com a gente." }, { status: 403 });

  const { data: u, error: e1 } = await sb.auth.admin.createUser({ email, password: c.senha, email_confirm: true, user_metadata: { nome: c.nome.trim() } });
  if (e1 || !u.user) return Response.json({ erro: e1?.message?.toLowerCase().includes("already") ? "Esse e-mail já tem conta. Entre com ele." : "Não deu para criar o login agora." }, { status: 400 });
  const { error: e2 } = await sb.rpc("criar_empresa_teste", { p: { nome: c.empresa.trim(), documento: c.documento ?? null, responsavel: c.nome.trim() }, p_dono: u.user.id });
  if (e2) {
    await sb.auth.admin.deleteUser(u.user.id).catch(() => {});
    return Response.json({ erro: e2.message.includes("cadastro_fechado") ? "O cadastro de empresas está fechado." : "Não deu para criar a empresa agora." }, { status: 400 });
  }
  return Response.json({ ok: true });
}
