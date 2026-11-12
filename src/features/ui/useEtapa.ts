"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Igual ao useState, mas cada mudança vira um passo no histórico do navegador:
 * o "voltar" desfaz um passo de cada vez (ex.: Perfil → Conquistas → voltar = Perfil),
 * em vez de sair da página. Guarda o valor no history.state, junto com o que o Next já guarda.
 * O valor precisa ser simples (texto, número, objeto JSON).
 */
export function useEtapa<T>(chave: string, inicial: T | (() => T)) {
  const campo = `etapa:${chave}`;
  const inicialRef = useRef<T | null>(null);
  const [valor, setValor] = useState<T>(() => {
    const v = typeof inicial === "function" ? (inicial as () => T)() : inicial;
    inicialRef.current = v;
    return v;
  });
  const atual = useRef(valor);
  atual.current = valor;

  useEffect(() => {
    const voltar = (e: PopStateEvent) => {
      const s = (e.state ?? {}) as Record<string, unknown>;
      const v = (campo in s ? s[campo] : inicialRef.current) as T;
      if (JSON.stringify(v) !== JSON.stringify(atual.current)) setValor(v);
    };
    window.addEventListener("popstate", voltar);
    return () => window.removeEventListener("popstate", voltar);
  }, [campo]);

  const mudar = useCallback((novo: T | ((v: T) => T)) => {
    const v = typeof novo === "function" ? (novo as (v: T) => T)(atual.current) : novo;
    if (JSON.stringify(v) === JSON.stringify(atual.current)) return;
    try {
      const s = (window.history.state ?? {}) as Record<string, unknown>;
      // A primeira entrada guarda o valor de antes, para o "voltar" ter para onde ir.
      if (!(campo in s)) window.history.replaceState({ ...s, [campo]: atual.current }, "");
      window.history.pushState({ ...(window.history.state ?? {}), [campo]: v }, "");
    } catch { /* sem histórico (iframe bloqueado): segue só com o estado */ }
    atual.current = v;
    setValor(v);
  }, [campo]);

  return [valor, mudar] as const;
}
