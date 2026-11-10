"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import { PADROES, type Configuracoes } from "./definicoes";

/**
 * Ajustes valendo para a empresa de quem está logado: o padrão da plataforma + o que a empresa mudou
 * (o Dev sem empresa escolhida vê e muda o padrão da plataforma). Atualizados em tempo real.
 */
export function useConfiguracoes(): Configuracoes {
  const [cfg, setCfg] = useState<Configuracoes>(PADROES);
  useEffect(() => {
    const sb = supabase();
    const carregar = () =>
      sb.rpc("ajustes").then(({ data }) => {
        if (data && typeof data === "object") setCfg({ ...PADROES, ...(data as Configuracoes) });
      });
    const canal = sb.channel(`cfg-${Math.random().toString(36).slice(2)}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "configuracoes" }, carregar)
      .on("postgres_changes", { event: "*", schema: "public", table: "politicas" }, carregar)
      .subscribe();
    carregar();
    return () => { sb.removeChannel(canal); };
  }, []);
  return cfg;
}
