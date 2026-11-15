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

/**
 * Janela aberta = um passo no histórico: o "voltar" do navegador (ou do celular) fecha a janela
 * em vez de sair da página. Fechada pelo botão, o passo sai do histórico sozinho.
 */
export function useFecharNoVoltar(fechar: () => void, ativo = true) {
  const ref = useRef(fechar);
  ref.current = fechar;
  useEffect(() => {
    if (!ativo) return;
    const id = Math.random().toString(36).slice(2);
    let voltou = false;
    try { window.history.pushState({ ...(window.history.state ?? {}), janela: id }, ""); } catch { return; }
    const aoVoltar = () => {
      if ((window.history.state as { janela?: string } | null)?.janela !== id) { voltou = true; ref.current(); }
    };
    window.addEventListener("popstate", aoVoltar);
    return () => {
      window.removeEventListener("popstate", aoVoltar);
      if (!voltou && (window.history.state as { janela?: string } | null)?.janela === id) window.history.back();
    };
  }, [ativo]);
}
