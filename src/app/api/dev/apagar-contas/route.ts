import { adminConfigurado, clienteDoUsuario, ehDev, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Dev: apaga as contas de uma empresa (ou de todas), menos as do Dev. Com "completo", some também
 * a cópia guardada, as mensagens e o nome nas rotas. Sempre com a senha do Dev.
 */
export async function POST(req: Request) {
  if (!adminConfigurado()) return Response.json({ erro: "servidor_sem_chave" }, { status: 503 });
  if (!(await ehDev(req))) return Response.json({ erro: "apenas_dev" }, { status: 403 });
  const sb = clienteDoUsuario(req)!;
  let c: { senha?: string; org?: string | null; completo?: boolean; papel?: string | null };
  try { c = await req.json(); } catch { return Response.json({ erro: "json_invalido" }, { status: 400 }); }
  const { data: conf, error: e1 } = await sb.rpc("dev_conferir_senha", { p_senha: c.senha ?? "" });
  if (e1) return Response.json({ erro: "falha" }, { status: 500 });
  const k = conf as { ok?: boolean; erro?: string; restantes?: number };
  if (!k?.ok) return Response.json({ erro: k?.erro ?? "senha_incorreta", restantes: k?.restantes }, { status: 400 });

  const admin = supabaseAdmin();
  let q = admin.from("perfis").select("id,papeis,organizacao_id").not("papeis", "cs", "{dev}");
  if (c.org && uuidValido(c.org)) q = q.eq("organizacao_id", c.org);
  if (c.papel && ["gestor", "supervisor", "motoboy", "cliente"].includes(c.papel)) q = q.contains("papeis", [c.papel]);
  const { data: lista, error } = await q.limit(2000);
  if (error) return Response.json({ erro: "falha", detalhe: error.message }, { status: 500 });
  let apagadas = 0; const falhas: string[] = [];
  for (const p of (lista ?? []) as { id: string }[]) {
    // tira de rotas em andamento antes (senão a conta some no meio da entrega)
    await admin.from("corridas").update({ motoboy_id: null, status: "sem_motoboy" }).eq("motoboy_id", p.id).in("status", ["aceita", "em_andamento"]);
    if (c.completo) await admin.rpc("apagar_rastros_conta", { p_usuario: p.id });
    const { data: fotos } = await admin.storage.from("avatares").list(p.id);
    if (fotos?.length) await admin.storage.from("avatares").remove(fotos.map((f) => `${p.id}/${f.name}`));
    const d = await admin.auth.admin.deleteUser(p.id);
    if (d.error) falhas.push(p.id); else apagadas++;
  }
  return Response.json({ ok: true, apagadas, falhas: falhas.length });
}
