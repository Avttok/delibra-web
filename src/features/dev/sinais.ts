"use client";

import { useEffect, useRef } from "react";
import { sair, supabase } from "@/lib/supabase/client";

export type Sinal = "avisos" | "empresa" | "perfil" | "sessao";

/**
 * Sinais instantâneos do Dev (tabela public.sinais, tempo real): avisos, empresa congelada,
 * regras e módulos mudados, sessão derrubada. Cada área recarrega na hora o que precisa.
 * "sessao": tenta renovar o login; se o Dev desconectou esta conta, sai na hora.
 */
export function useSinais(ativo: boolean, onSinal: (s: Sinal) => void) {
  const cb = useRef(onSinal);
  useEffect(() => { cb.current = onSinal; }, [onSinal]);
  useEffect(() => {
    if (!ativo) return;
    const sb = supabase();
    const canal = sb.channel(`sinais-${Math.random().toString(36).slice(2)}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "sinais" }, (payload) => {
        const tipo = (payload.new as { tipo?: Sinal }).tipo;
        if (!tipo) return;
        if (tipo === "avisos" || tipo === "perfil") window.dispatchEvent(new Event("pwex:avisos"));
        if (tipo === "sessao") {
          void sb.auth.refreshSession().then(({ error }) => { if (error) void sair().then(() => window.location.reload()); });
          return;
        }
        cb.current(tipo);
      })
      .subscribe();
    return () => { sb.removeChannel(canal); };
  }, [ativo]);
}
