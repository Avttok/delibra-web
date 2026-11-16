"use client";

import { supabase } from "@/lib/supabase/client";

/** Trajeto feito do pedido (lng, lat), já pelas ruas, em pedaços (sem ligar com reta onde o GPS ficou sem sinal). [] se não houver. */
export async function trilhaDoPedido(pedido: string): Promise<[number, number][][]> {
  try {
    const { data } = await supabase().auth.getSession();
    const token = data.session?.access_token;
    if (!token) return [];
    const r = await fetch("/api/percursos/pedido", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ pedido }) });
    if (!r.ok) return [];
    const j = (await r.json()) as { linha?: [number, number][]; linhas?: [number, number][][] };
    const partes = j.linhas ?? (j.linha?.length ? [j.linha] : []);
    return partes.map((l) => l.map(([la, lo]) => [lo, la] as [number, number]));
  } catch { return []; }
}
