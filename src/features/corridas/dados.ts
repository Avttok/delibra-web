"use client";

import { useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import type { Corrida, Empresa, Oferta } from "./tipos";
import type { StatusMotoboy } from "@/features/rastreamento/tipos";

export interface MembroEquipe {
  id: string;
  nome: string;
  status: StatusMotoboy;
  lat: number | null;
  lng: number | null;
  posicao_em: string | null;
  modo_teste: boolean;
  foto: string | null;
}

/** Recarrega quando qualquer tabela observada mudar (agrupa rajadas em 300 ms). */
export function useRecarregarAoMudar(tabelas: string[], recarregar: () => void, canal: string) {
  const ref = useRef(recarregar);
  ref.current = recarregar;
  const chave = tabelas.join(",");
  useEffect(() => {
    const sb = supabase();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const agendar = () => {
      clearTimeout(timer);
      timer = setTimeout(() => ref.current(), 300);
    };
    let c = sb.channel(`${canal}-${Math.random().toString(36).slice(2)}`);
    for (const t of chave.split(",")) {
      c = c.on("postgres_changes", { event: "*", schema: "public", table: t }, agendar);
    }
    c.subscribe();
    ref.current();
    return () => {
      clearTimeout(timer);
      sb.removeChannel(c);
    };
  }, [chave, canal]);
}

export function useCorridas() {
  const [corridas, setCorridas] = useState<Corrida[]>([]);
  const [ofertas, setOfertas] = useState<Oferta[]>([]);
  const [erro, setErro] = useState<string | null>(null);

  useRecarregarAoMudar(["corridas", "paradas", "ofertas"], async () => {
    const sb = supabase();
    const desde = new Date(Date.now() - 30 * 86400_000).toISOString();
    const [c, o] = await Promise.all([
      sb.from("corridas").select("*, paradas(*)").gte("criada_em", desde).order("criada_em", { ascending: false }).limit(400),
      sb.from("ofertas").select("id,corrida_id,motoboy_id,status,distancia_m,expira_em").eq("status", "pendente"),
    ]);
    if (c.error || o.error) return setErro((c.error ?? o.error)!.message);
    const lista = (c.data as Corrida[]).map((x) => ({ ...x, paradas: [...x.paradas].sort((a, b) => a.ordem - b.ordem) }));
    setCorridas(lista);
    setOfertas(o.data as Oferta[]);
    setErro(null);
  }, "corridas");

  return { corridas, ofertas, erro };
}

export function useEquipe() {
  const [equipe, setEquipe] = useState<MembroEquipe[]>([]);
  useRecarregarAoMudar(["motoboys", "perfis"], async () => {
    const sb = supabase();
    const [m, p] = await Promise.all([
      sb.from("motoboys").select("id,status,lat,lng,posicao_em,modo_teste"),
      sb.from("perfis").select("id,nome,papeis,foto_url"),
    ]);
    if (m.error || p.error) return;
    const perfis = new Map((p.data as { id: string; nome: string; papeis: string[]; foto_url: string | null }[]).map((x) => [x.id, x]));
    const lista = (m.data as Omit<MembroEquipe, "nome">[])
      .filter((x) => perfis.get(x.id)?.papeis.includes("motoboy"))
      .map((x) => ({ ...x, nome: perfis.get(x.id)?.nome || "Motoboy", foto: perfis.get(x.id)?.foto_url ?? null }))
      .sort((a, b) => a.nome.localeCompare(b.nome));
    setEquipe(lista);
  }, "equipe");
  return equipe;
}

export function useEmpresas() {
  const [empresas, setEmpresas] = useState<Empresa[]>([]);
  const [favoritos, setFavoritos] = useState<{ empresa_id: string; motoboy_id: string; ordem: number }[]>([]);
  const [versao, setVersao] = useState(0);
  useRecarregarAoMudar(["empresas", "empresa_favoritos"], async () => {
    const sb = supabase();
    const [e, f] = await Promise.all([
      sb.from("empresas").select("*").order("nome"),
      sb.from("empresa_favoritos").select("empresa_id,motoboy_id,ordem").order("ordem"),
    ]);
    if (!e.error) setEmpresas(e.data as Empresa[]);
    if (!f.error) setFavoritos(f.data);
  }, `empresas-${versao}`);
  return { empresas, favoritos, recarregar: () => setVersao((v) => v + 1) };
}

/** Mensagens das funções do banco em português. */
export function traduzirErro(msg: string | undefined): string {
  const mapa: Record<string, string> = {
    apenas_gestor: "Apenas gestores podem fazer isso.",
    corrida_precisa_de_2_paradas: "A corrida precisa de pelo menos uma coleta e uma entrega.",
    primeira_parada_deve_ser_coleta: "A primeira parada precisa ser uma coleta.",
    escolha_o_motoboy: "Escolha o motoboy para o despacho direto.",
    corrida_nao_esta_sem_motoboy: "Essa corrida não está aguardando novo despacho.",
    motoboy_fora_do_modo_teste: "Esse motoboy não está com o modo teste ligado no app.",
    motoboy_em_modo_teste: "Esse motoboy está com o modo teste ligado: só recebe corridas de teste.",
    horario_muito_proximo: "Esse horário está perto demais. Planeje com mais antecedência (veja Configurações → Corridas planejadas) ou crie uma corrida para agora.",
    sem_datas: "Escolha pelo menos uma data.",
    datas_demais: "No máximo 60 corridas por repetição.",
    corrida_nao_esta_planejada: "Essa corrida não está mais planejada (já começou, foi despachada ou cancelada).",
    acao_invalida: "Ação inválida.",
    ja_coletou: "O motoboy já coletou: não dá mais para passar a rota.",
    corrida_sem_motoboy: "Essa rota não está com nenhum motoboy agora.",
    mesmo_motoboy: "A rota já está com esse motoboy.",
    passar_desligado: "Passar rota está desligado em Ajustes → Despacho.",
    motoboy_suspenso: "Esse motoboy está suspenso por penalidades.",
    sem_permissao: "Você não tem acesso a isso.",
  };
  const chave = msg?.match(/^[a-z_]+$/) ? msg : Object.keys(mapa).find((k) => msg?.includes(k));
  return (chave && mapa[chave]) || msg || "Erro desconhecido.";
}

/** Nome do cliente da corrida: empresa cadastrada, nome do avulso ou "Avulso". */
export function nomeCliente(c: { empresa_id: string | null; cliente_nome?: string | null }, empresas: { id: string; nome: string }[]): string {
  if (c.empresa_id) return empresas.find((e) => e.id === c.empresa_id)?.nome ?? "Cliente";
  return c.cliente_nome ? `${c.cliente_nome} (avulso)` : "Avulso";
}
