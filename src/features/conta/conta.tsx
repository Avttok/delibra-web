"use client";

import { createContext, useContext, useEffect, type ReactNode } from "react";

/** Cargos do sistema. O Dev administra tudo; o gestor, a operação; o motoboy, as corridas. */
export type Papel = "dev" | "gestor" | "supervisor" | "motoboy" | "cliente";
export type CorTema = "ouro" | "vermelho";

/** Módulos que o Dev liga/desliga (mesmas chaves da tabela public.modulos). */
export type Modulo =
  | "corridas_planejadas" | "pontos_referencia" | "excluir_corridas" | "modo_teste" | "criar_contas"
  | "carteira" | "trilhas_mapa" | "estabelecimentos" | "atualizacao_app"
  | "chat" | "navegacao" | "extensao_rota" | "orcamento_editavel" | "objetos_cliente";

export interface ContextoConta {
  id: string;
  papeis: Papel[];
  dev: boolean;
  corTema: CorTema;
  modulos: Record<string, boolean>;
  /** O módulo está valendo para esta conta? (sem registro = ligado) */
  modulo: (m: Modulo) => boolean;
  definirCor: (c: CorTema) => Promise<string | null>;
  recarregar: () => void;
}

const Contexto = createContext<ContextoConta>({
  id: "", papeis: [], dev: false, corTema: "ouro", modulos: {}, modulo: () => true, definirCor: async () => null, recarregar: () => {},
});
export const useConta = () => useContext(Contexto);

/** Aplica a cor do tema no <html> (data-acento). O modo teste (violeta) sempre vence. */
export function ProvedorConta({ valor, children }: { valor: ContextoConta; children: ReactNode }) {
  useEffect(() => {
    const html = document.documentElement;
    if (valor.corTema === "vermelho") html.dataset.acento = "vermelho";
    else delete html.dataset.acento;
    return () => { delete html.dataset.acento; };
  }, [valor.corTema]);
  return <Contexto.Provider value={valor}>{children}</Contexto.Provider>;
}
