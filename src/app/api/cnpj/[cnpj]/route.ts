import { createClient } from "@supabase/supabase-js";
import { consultarCnpj } from "@/lib/cnpj/consulta";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** GET /api/cnpj/00000000000000 — apenas para gestores logados (token do Supabase no Authorization). */
export async function GET(req: Request, { params }: { params: Promise<{ cnpj: string }> }) {
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return Response.json({ erro: "nao_autenticado" }, { status: 401 });

  const sb = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL!, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: gestor, error } = await sb.rpc("is_gestor");
  if (error || gestor !== true) return Response.json({ erro: "apenas_gestor" }, { status: 403 });

  const { cnpj } = await params;
  const r = await consultarCnpj(cnpj);
  if (!r.dados) return Response.json({ erro: r.motivo ?? "nao_encontrado" }, { status: 404 });
  return Response.json(r.dados);
}
