import { timingSafeEqual } from "node:crypto";
import { adminConfigurado, gestorDaRequisicao, supabaseAdmin, uuidValido } from "@/lib/supabase/admin";
import { otimizarRota } from "@/lib/rotas/otimizar";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

function segredoValido(recebido: string | null): boolean {
  const esperado = process.env.PUSH_SECRET;
  if (!esperado || !recebido) return false;
  const a = Buffer.from(recebido), b = Buffer.from(esperado);
  return a.length === b.length && timingSafeEqual(a, b);
}

/**
 * Chamado pelo banco (a cada minuto, quando há rota nova ou mudada) ou pelo gestor.
 * Corpo opcional: { corrida_id } para otimizar só uma.
 */
export async function POST(req: Request) {
  const segredo = req.headers.get("x-pwex-secret");
  const doBanco = async () => {
    if (!segredo || !adminConfigurado()) return false;
    const { data, error } = await supabaseAdmin().rpc("push_secret_confere", { p: segredo });
    return !error && data === true;
  };
  // o banco chama com o segredo dele (não precisa bater com o PUSH_SECRET da Vercel)
  if (!segredoValido(segredo) && !(await doBanco()) && !(await gestorDaRequisicao(req))) {
    return Response.json({ erro: "nao_autorizado" }, { status: 401 });
  }
  if (!adminConfigurado()) return Response.json({ erro: "sem_chave_secreta" }, { status: 500 });
  let corpo: { corrida_id?: string } = {};
  try { corpo = await req.json(); } catch { /* sem corpo */ }
  const sb = supabaseAdmin();
  let q = sb.from("corridas").select("id, paradas(id,ordem,tipo,lat,lng,status)").eq("origem", "roteirizador")
    .in("status", ["montada", "agendada", "aguardando_motoboy", "sem_motoboy", "reservada"]).order("criada_em").limit(8);
  q = uuidValido(corpo.corrida_id) ? q.eq("id", corpo.corrida_id) : q.is("otimizada_em", null);
  const { data, error } = await q;
  if (error) return Response.json({ erro: error.message }, { status: 500 });
  let ok = 0;
  for (const c of data ?? []) {
    if (await otimizarRota(sb, c.id, c.paradas as never)) ok++;
  }
  return Response.json({ rotas: data?.length ?? 0, otimizadas: ok });
}
