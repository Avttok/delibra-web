"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import { useModoTeste } from "@/features/teste/modoTeste";
import { buscarPercursos, type Ajuste } from "@/lib/mapa/percursos";
import type { Motoboy, Ponto } from "./tipos";

const HORAS_DE_TRILHA = 12;
const MAX_PONTOS = 5000;
const COLUNAS_MOTOBOY = "id,status,modo_economia,lat,lng,precisao_m,bateria,posicao_em,status_em,versao_app,modo_teste";
const COLUNAS_PONTO = "id,motoboy_id,sessao_id,corrida_id,status,lat,lng,precisao_m,velocidade_ms,bateria,registrado_em";

export interface EstadoRastreamento {
  motoboys: Record<string, Motoboy>;
  nomes: Record<string, string>;
  fotos: Record<string, string>;
  trilhas: Record<string, Ponto[]>;
  /** Caminho pelas ruas de cada registro (chave "motoboy|inicioMs"). */
  ajustes: Record<string, Ajuste>;
  conectado: boolean;
  erro: string | null;
}

/**
 * Carrega o estado atual e escuta o Supabase Realtime (motoboys + novos pontos).
 * Os percursos (trilhas) são só do modo atual: teste e real ficam separados.
 */
export function useRastreamento(): EstadoRastreamento {
  const { teste } = useModoTeste();
  const [motoboys, setMotoboys] = useState<Record<string, Motoboy>>({});
  const [nomes, setNomes] = useState<Record<string, string>>({});
  const [fotos, setFotos] = useState<Record<string, string>>({});
  const [trilhas, setTrilhas] = useState<Record<string, Ponto[]>>({});
  const [ajustes, setAjustes] = useState<Record<string, Ajuste>>({});
  const [conectado, setConectado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    const sb = supabase();
    let ativo = true;

    async function carregar() {
      const desde = new Date(Date.now() - HORAS_DE_TRILHA * 3600_000).toISOString();
      const pontos = (porModo: boolean) => {
        const q = sb.from("localizacoes").select(COLUNAS_PONTO);
        return (porModo ? q.eq("teste", teste) : q).gte("registrado_em", desde).order("registrado_em", { ascending: true }).limit(MAX_PONTOS);
      };
      // percursos pelo servidor: todos os pings (sem o corte de 1000) e já traçados pelas ruas
      // os percursos (traçado pelas ruas) podem demorar: motoboys e nomes aparecem antes, sem esperar
      const percursos = buscarPercursos({ de: new Date(desde), ate: new Date(Date.now() + 10 * 60_000), teste });
      const [m, p] = await Promise.all([
        sb.from("motoboys").select(COLUNAS_MOTOBOY),
        sb.from("perfis").select("id,nome,foto_url"),
      ]);
      if (!ativo) return;
      if (!m.error) setMotoboys(Object.fromEntries((m.data as Motoboy[]).map((x) => [x.id, x])));
      if (!p.error) {
        const ps = (p.data ?? []) as { id: string; nome: string; foto_url: string | null }[];
        setNomes(Object.fromEntries(ps.map((x) => [x.id, x.nome])));
        setFotos(Object.fromEntries(ps.filter((x) => x.foto_url).map((x) => [x.id, x.foto_url!])));
      }
      const viaApi = await percursos;
      let l: { data: Ponto[] | null; error: { message: string } | null };
      if (viaApi) {
        l = { data: viaApi.pings.map((x, i) => ({ id: -i - 1, sessao_id: null, precisao_m: null, velocidade_ms: null, bateria: null, ...x }) as Ponto), error: null };
      } else {
        const l1 = await pontos(true);
        // banco ainda sem a coluna "teste" (migração não rodada): mostra os pings sem separar, em vez de quebrar o mapa
        l = (l1.error && /teste/.test(l1.error.message) ? await pontos(false) : l1) as typeof l;
      }
      if (!ativo) return;
      const falha = m.error ?? p.error ?? l.error;
      if (falha) {
        setErro(falha.message);
        return;
      }
      setMotoboys(Object.fromEntries((m.data as Motoboy[]).map((x) => [x.id, x])));
      const perfis = (p.data ?? []) as { id: string; nome: string; foto_url: string | null }[];
      setNomes(Object.fromEntries(perfis.map((x) => [x.id, x.nome])));
      setFotos(Object.fromEntries(perfis.filter((x) => x.foto_url).map((x) => [x.id, x.foto_url!])));
      const porMotoboy: Record<string, Ponto[]> = {};
      for (const ponto of (l.data ?? []) as Ponto[]) (porMotoboy[ponto.motoboy_id] ??= []).push(ponto);
      setTrilhas(porMotoboy);
      setAjustes(viaApi?.ajustes ?? {});
    }

    const canal = sb
      .channel("rastreamento-ao-vivo")
      .on("postgres_changes", { event: "*", schema: "public", table: "motoboys" }, (payload) => {
        const novo = payload.new as Motoboy;
        if (!novo?.id) return;
        setMotoboys((atual) => ({ ...atual, [novo.id]: { ...atual[novo.id], ...novo } }));
      })
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "localizacoes" }, (payload) => {
        const ponto = payload.new as Ponto & { teste?: boolean };
        if (Boolean(ponto.teste) !== teste) return;
        setTrilhas((atual) => {
          const lista = [...(atual[ponto.motoboy_id] ?? []), ponto];
          lista.sort((a, b) => a.registrado_em.localeCompare(b.registrado_em));
          return { ...atual, [ponto.motoboy_id]: lista.slice(-MAX_PONTOS) };
        });
      })
      .subscribe((status) => setConectado(status === "SUBSCRIBED"));

    carregar();
    // de tempos em tempos o servidor retraça pelas ruas o que chegou ao vivo
    const refazer = setInterval(() => { if (document.visibilityState === "visible") void carregar(); }, 120_000);

    return () => {
      ativo = false;
      clearInterval(refazer);
      sb.removeChannel(canal);
    };
  }, [teste]);

  return { motoboys, nomes, fotos, trilhas, ajustes, conectado, erro };
}
