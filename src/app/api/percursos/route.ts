import { clienteDoUsuario, uuidValido } from "@/lib/supabase/admin";
import { montarPercursos } from "@/lib/percursos/ajustar";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

/**
 * Percursos (histórico de pings) já traçados pelas ruas. Usado pelo painel e pelo app.
 * Corpo: { de, ate, motoboy?, teste?, corrida?, ajustar? } — de/ate em ISO; com `corrida`, a trilha inteira dela.
 * Quem pode ver o quê é o banco que decide (gestor: todos; motoboy: só os dele).
 */
export async function POST(req: Request) {
  const sb = clienteDoUsuario(req);
  if (!sb) return Response.json({ erro: "nao_autenticado" }, { status: 401 });
  let c: { de?: string; ate?: string; motoboy?: string; teste?: boolean; corrida?: string; ajustar?: boolean } = {};
  try { c = await req.json(); } catch { /* sem corpo */ }
  const data = (v?: string) => (v && !Number.isNaN(Date.parse(v)) ? new Date(v).toISOString() : null);
  const { data: dados, error } = await sb.rpc("pings_percurso", {
    p_de: data(c.de), p_ate: data(c.ate),
    p_motoboy: uuidValido(c.motoboy) ? c.motoboy : null,
    p_teste: typeof c.teste === "boolean" ? c.teste : null,
    p_corrida: uuidValido(c.corrida) ? c.corrida : null,
  });
  if (error) return Response.json({ erro: error.message }, { status: /permiss|autentic/.test(error.message) ? 403 : 400 });
  return Response.json(await montarPercursos(sb, dados ?? {}, c.ajustar !== false));
}
