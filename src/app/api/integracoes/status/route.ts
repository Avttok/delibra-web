import { ehDev } from "@/lib/supabase/admin";
import { MODULOS, conectado } from "@/lib/integracoes/modulos";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Dev: quais módulos têm a chave no servidor (só sim/não; a chave nunca sai daqui). */
export async function POST(req: Request) {
  if (!(await ehDev(req))) return Response.json({ erro: "apenas_dev" }, { status: 403 });
  return Response.json({ modulos: MODULOS.map((m) => ({ ...m, conectado: conectado(m.variavel) })) });
}
