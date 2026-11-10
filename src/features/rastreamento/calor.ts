"use client";

import { supabase } from "@/lib/supabase/client";
import { decodificarPolyline } from "@/lib/geo/polyline";

export type TipoCalor = "pedidos" | "pings" | "rotas";
export const ROTULO_CALOR: Record<TipoCalor, string> = { pedidos: "Pedidos (coletas e entregas)", pings: "Pings dos motoboys", rotas: "Rotas das corridas" };

/** Pontos para o mapa de calor (últimos 60 dias; pings: 7 dias), do modo atual (real ou teste). */
export async function carregarCalor(tipo: TipoCalor, teste: boolean): Promise<[number, number][]> {
  const sb = supabase();
  const desde = new Date(Date.now() - (tipo === "pings" ? 7 : 60) * 86400_000).toISOString();
  if (tipo === "pedidos") {
    const { data } = await sb.from("paradas").select("lat,lng,corridas!inner(teste,criada_em)")
      .eq("corridas.teste", teste).gte("corridas.criada_em", desde).limit(8000);
    return (data ?? []).map((p) => [p.lat as number, p.lng as number]);
  }
  if (tipo === "pings") {
    // cada ping já nasce marcado como teste ou real
    const { data } = await sb.from("localizacoes").select("lat,lng").eq("teste", teste).gte("registrado_em", desde).limit(15000);
    return (data ?? []).map((p) => [p.lat as number, p.lng as number]);
  }
  const { data } = await sb.from("corridas").select("rota_planejada").eq("teste", teste).gte("criada_em", desde).not("rota_planejada", "is", null).limit(600);
  return (data ?? []).flatMap((c) => {
    const pts = decodificarPolyline(c.rota_planejada as string);
    const passo = Math.max(1, Math.floor(pts.length / 60));
    return pts.filter((_, i) => i % passo === 0).map(([lng, lat]) => [lat, lng] as [number, number]);
  });
}
