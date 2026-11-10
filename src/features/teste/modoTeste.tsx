"use client";

import { createContext, useContext, useEffect, type ReactNode } from "react";

/**
 * Modo teste do painel. Ligado, o site inteiro troca o dourado por violeta,
 * mostra só corridas e ganhos de teste e cria corridas de teste por padrão.
 * O valor fica no perfil (mesmo do app, para quem também é motoboy).
 */
export interface ContextoTeste {
  teste: boolean;
  definir: (ligado: boolean) => Promise<string | null>; // devolve a mensagem de erro, se houver
}

const Contexto = createContext<ContextoTeste>({ teste: false, definir: async () => null });
export const useModoTeste = () => useContext(Contexto);

export function ProvedorTeste({ valor, children }: { valor: ContextoTeste; children: ReactNode }) {
  useEffect(() => {
    const html = document.documentElement;
    if (valor.teste) html.dataset.teste = "1";
    else delete html.dataset.teste;
    return () => { delete html.dataset.teste; };
  }, [valor.teste]);
  return <Contexto.Provider value={valor}>{children}</Contexto.Provider>;
}
