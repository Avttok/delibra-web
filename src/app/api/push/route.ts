import { timingSafeEqual } from "node:crypto";
import { enviarFcm } from "@/lib/push/fcm";
import { adminConfigurado, supabaseAdmin } from "@/lib/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function segredoValido(recebido: string | null): boolean {
  const esperado = process.env.PUSH_SECRET;
  if (!esperado || !recebido) return false;
  const a = Buffer.from(recebido);
  const b = Buffer.from(esperado);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Chamado pelo banco (pg_net) para avisar o celular do motoboy. */
/** O segredo do banco (privado.config.push_secret) também vale: não precisa ser igual ao da Vercel. */
async function segredoDoBanco(recebido: string | null): Promise<boolean> {
  if (!recebido || !adminConfigurado()) return false;
  const { data, error } = await supabaseAdmin().rpc("push_secret_confere", { p: recebido });
  return !error && data === true;
}

export async function POST(req: Request) {
  const segredo = req.headers.get("x-pwex-secret");
  if (!segredoValido(segredo) && !(await segredoDoBanco(segredo))) {
    return Response.json({ erro: "nao_autorizado" }, { status: 401 });
  }
  let corpo: { token?: string; data?: Record<string, unknown> };
  try {
    corpo = await req.json();
  } catch {
    return Response.json({ erro: "json_invalido" }, { status: 400 });
  }
  if (!corpo.token || !corpo.data) return Response.json({ erro: "faltam_campos" }, { status: 400 });

  // FCM exige que todos os valores sejam texto
  const dados = Object.fromEntries(Object.entries(corpo.data).map(([k, v]) => [k, String(v ?? "")]));
  try {
    const r = await enviarFcm(corpo.token, dados);
    if (!r.ok) console.error("FCM recusou", r.status, r.corpo);
    return Response.json({ ok: r.ok, status: r.status }, { status: r.ok ? 200 : 502 });
  } catch (e) {
    console.error("Falha no push", e);
    return Response.json({ erro: String(e) }, { status: 500 });
  }
}

/** Diagnóstico rápido: GET /api/push mostra se as variáveis existem (sem revelar valores). */
export async function GET() {
  return Response.json({
    FIREBASE_SERVICE_ACCOUNT: Boolean(process.env.FIREBASE_SERVICE_ACCOUNT),
    PUSH_SECRET: Boolean(process.env.PUSH_SECRET),
    SUPABASE_SECRET_KEY: adminConfigurado(),
  });
}
