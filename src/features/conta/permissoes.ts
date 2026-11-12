"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";

export type NivelAjuste = "editar" | "ver" | "oculto";
export type Permissoes = { dev: boolean; ajustes: Record<string, NivelAjuste>; acoes: Record<string, boolean> };

/** Ações que o Dev liga e desliga para os gestores (mesma lista do banco: privado.acoes_gestor). */
export const ACOES_GESTOR: { chave: string; rotulo: string; dica: string }[] = [
  { chave: "criar_contas", rotulo: "Criar contas", dica: "Novos motoboys, supervisores e clientes com acesso." },
  { chave: "excluir_contas", rotulo: "Excluir contas", dica: "Apagar contas da equipe." },
  { chave: "editar_cargos", rotulo: "Mudar cargos", dica: "Trocar o cargo de quem já tem conta." },
  { chave: "apagar_historico", rotulo: "Apagar histórico", dica: "Rotas antigas, percursos e pings." },
  { chave: "exportar_dados", rotulo: "Relatórios e planilhas", dica: "Baixar e mandar relatórios por e-mail." },
  { chave: "editar_valor_pedido", rotulo: "Mudar o valor do pedido", dica: "O que o cliente paga, na revisão e depois." },
  { chave: "editar_pagamento_motoboy", rotulo: "Mudar o pagamento do motoboy", dica: "Cálculos e ajustes de cada rota." },
  { chave: "ajuste_holerite", rotulo: "Lançar ajustes no holerite", dica: "Valores a mais ou a menos na folha." },
  { chave: "fechar_holerite", rotulo: "Fechar e pagar holerites", dica: "Marcar a folha como fechada e paga." },
  { chave: "emitir_fatura", rotulo: "Emitir faturas", dica: "Gerar e emitir as faturas dos clientes." },
  { chave: "cancelar_rota", rotulo: "Cancelar rotas", dica: "Cancelar uma rota já montada ou em andamento." },
  { chave: "voltar_revisao", rotulo: "Voltar pedidos à revisão", dica: "Desfazer rotas e revisar de novo." },
  { chave: "forcar_inicio", rotulo: "Forçar início de planejada", dica: "Começar uma rota planejada antes da hora." },
  { chave: "chat_apagar", rotulo: "Apagar mensagens de outros", dica: "No chat da equipe." },
  { chave: "mudar_marca", rotulo: "Mudar a marca da empresa", dica: "Nome, logo e cores." },
  { chave: "modo_teste", rotulo: "Usar o modo teste", dica: "Treinar sem mexer no que é real." },
  { chave: "ver_carteira", rotulo: "Ver a carteira", dica: "Faturamento, folha, extrato e PIX." },
  { chave: "regras_por_cliente", rotulo: "Regras por cliente", dica: "Exceções de preço e regras de cada cliente." },
  { chave: "regras_por_motoboy", rotulo: "Regras por motoboy", dica: "Exceções de pagamento e GPS de cada motoboy." },
  { chave: "penalidades", rotulo: "Penalidades", dica: "Aplicar e perdoar penalidades." },
];

let cache: Permissoes | null = null;
const ouvintes = new Set<(p: Permissoes) => void>();

export function recarregarPermissoes() {
  void supabase().rpc("minhas_permissoes").then(({ data }) => {
    const p = (data ?? { dev: false, ajustes: {}, acoes: {} }) as Permissoes;
    cache = p; ouvintes.forEach((f) => f(p));
  });
}

/** O que o Dev deixou este gestor fazer. Sem resposta ainda: tudo liberado (o banco barra de qualquer jeito). */
export function usePermissoes() {
  const [p, setP] = useState<Permissoes | null>(cache);
  useEffect(() => {
    ouvintes.add(setP);
    if (!cache) recarregarPermissoes();
    return () => { ouvintes.delete(setP); };
  }, []);
  const v = p ?? { dev: false, ajustes: {}, acoes: {} };
  return {
    carregou: p !== null,
    nivel: (chave: string): NivelAjuste => (v.dev ? "editar" : v.ajustes[chave] ?? "editar"),
    pode: (acao: string) => v.dev || v.acoes[acao] !== false,
  };
}
