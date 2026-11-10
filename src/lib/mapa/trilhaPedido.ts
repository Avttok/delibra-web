"use client";

import { supabase } from "@/lib/supabase/client";

/** Trajeto feito do pedido (lng, lat), já pelas ruas. [] se não houver ou a empresa não acompanha ao vivo. */
export async function trilhaDoPedido(pedido: string): Promise<[number, number][]> {
  try {
    const { data } = await supabase().auth.getSession();
    const token = data.session?.access_token;
    if (!token) return [];
    const r = await fetch("/api/percursos/pedido", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${token}` }, body: JSON.stringify({ pedido }) });
    if (!r.ok) return [];
    const j = (await r.json()) as { linha?: [number, number][] };
    return (j.linha ?? []).map(([la, lo]) => [lo, la]);
  } catch { return []; }
}
