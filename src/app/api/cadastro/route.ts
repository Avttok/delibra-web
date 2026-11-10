import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** O site do cliente fica em outro domínio: libera só o envio do formulário. */
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  Vary: "Origin",
};
const resp = (corpo: unknown, status = 200) => Response.json(corpo, { status, headers: CORS });

// freio simples contra robôs (por instância do servidor)
const tentativas = new Map<string, number[]>();
function muitas(ip: string) {
  const agora = Date.now();
  const l = (tentativas.get(ip) ?? []).filter((t) => agora - t < 60 * 60_000);
  l.push(agora);
  tentativas.set(ip, l);
  return l.length > 5;
}

export async function OPTIONS() { return new Response(null, { status: 204, headers: CORS }); }

/**
 * Empresa cria a conta pelo site do cliente. Conforme a regra do gestor ("Empresas se cadastram pelo site"),
 * fica esperando aprovação, entra na hora ou o cadastro está fechado.
 */
export async function POST(req: Request) {
  if (!adminConfigurado()) return resp({ erro: "servidor_sem_chave" }, 503);
  let c: Record<string, unknown>;
  try { c = await req.json(); } catch { return resp({ erro: "json_invalido" }, 400); }
  if (c.site) return resp({ ok: true }); // armadilha para robôs
  const ip = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "?";
  if (muitas(ip)) return resp({ erro: "muitas_tentativas" }, 429);

  const email = String(c.email ?? "").trim().toLowerCase();
  const senha = String(c.senha ?? "");
  const nome = String(c.nome ?? "").trim();
  const responsavel = String(c.responsavel ?? "").trim();
  const documento = String(c.documento ?? "").replace(/\D/g, "");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return resp({ erro: "email_invalido" }, 400);
  if (senha.length < 8) return resp({ erro: "senha_curta" }, 400);
  if (nome.length < 2 || nome.length > 120) return resp({ erro: "nome_invalido" }, 400);
  if (documento && documento.length !== 11 && documento.length !== 14) return resp({ erro: "documento_invalido" }, 400);

  const admin = supabaseAdmin();
  const aberto = await admin.rpc("cadastro_aberto");
  if ((aberto.data as { modo?: string } | null)?.modo === "desligado") return resp({ erro: "cadastro_desligado" }, 403);

  const { data, error } = await admin.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome: responsavel || nome } });
  if (error || !data.user) {
    const existe = /already|registered|exists/i.test(error?.message ?? "");
    return resp({ erro: existe ? "email_existe" : "falha_ao_criar" }, existe ? 409 : 500);
  }
  await admin.from("perfis").upsert({ id: data.user.id, nome: responsavel || nome });
  const r = await admin.rpc("registrar_cadastro", { d: {
    perfil_id: data.user.id, email, nome, responsavel: responsavel || null, documento: documento || null,
    telefone: c.telefone ?? null, endereco: c.endereco ?? null, lat: c.lat ?? null, lng: c.lng ?? null, observacoes: c.observacoes ?? null,
  } });
  if (r.error) {
    await admin.auth.admin.deleteUser(data.user.id).catch(() => null);
    return resp({ erro: r.error.message.includes("documento_invalido") ? "documento_invalido" : r.error.message.includes("cadastro_desligado") ? "cadastro_desligado" : "falha_no_cadastro" }, 400);
  }
  return resp({ ok: true, status: (r.data as { status?: string } | null)?.status ?? "pendente" });
}

/** O site do cliente pergunta se o cadastro está aberto. */
export async function GET() {
  if (!adminConfigurado()) return resp({ modo: "desligado" });
  const r = await supabaseAdmin().rpc("cadastro_aberto");
  return resp({ modo: (r.data as { modo?: string } | null)?.modo ?? "aprovacao" });
}
