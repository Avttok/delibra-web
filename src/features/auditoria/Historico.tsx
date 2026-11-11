"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { History, Minus, Pencil, Plus, Search } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";

type Linha = { id: number; quando: string; autor: string; autor_id: string | null; tabela: string; acao: "insert" | "update" | "delete"; alvo: string | null; antes: Record<string, unknown> | null; depois: Record<string, unknown> | null };

const TABELA: Record<string, string> = {
  pedidos: "Pedido", corridas: "Rota", politicas: "Regra", empresas: "Cliente", zonas: "Zona", categorias_produto: "Tipo de objeto",
  tipos_pedido: "Tipo de pedido", penalidades: "Penalidade", chamados_corrida: "Pedido do motoboy", faixas_horario: "Faixa de horário",
};
const ACAO = { insert: { rotulo: "criou", icone: Plus }, update: { rotulo: "mudou", icone: Pencil }, delete: { rotulo: "apagou", icone: Minus } } as const;
// campos internos que não ajudam a entender a mudança
const ESCONDER = new Set(["id", "organizacao_id", "criado_em", "atualizado_em", "criada_em", "rota_planejada", "pag_calculo", "orcamento", "referencias"]);

function valor(v: unknown): string {
  if (v === null || v === undefined || v === "") return "vazio";
  if (typeof v === "boolean") return v ? "ligado" : "desligado";
  if (typeof v === "object") return JSON.stringify(v).slice(0, 80);
  return String(v).slice(0, 80);
}
const nomeCampo = (k: string) => k.replace(/_/g, " ");

function Diferencas({ l }: { l: Linha }) {
  const chaves = Object.keys(l.acao === "delete" ? l.antes ?? {} : l.depois ?? {}).filter((k) => !ESCONDER.has(k));
  if (!chaves.length) return null;
  const mostrar = l.acao === "update" ? chaves : chaves.filter((k) => (l.acao === "insert" ? l.depois : l.antes)?.[k] != null).slice(0, 6);
  return (
    <ul className="historico-campos">
      {mostrar.map((k) => (
        <li key={k}>
          <span className="historico-campo">{nomeCampo(k)}</span>
          {l.acao === "update" ? <><s>{valor(l.antes?.[k])}</s> → <strong>{valor(l.depois?.[k])}</strong></> : <strong>{valor((l.acao === "insert" ? l.depois : l.antes)?.[k])}</strong>}
        </li>
      ))}
    </ul>
  );
}

/** Quem mudou o quê: pedidos, rotas, regras, clientes, zonas… (Ajustes → Sistema → Histórico de mudanças). */
export function Historico() {
  const [linhas, setLinhas] = useState<Linha[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [busca, setBusca] = useState("");
  const [tabela, setTabela] = useState("");
  const [dias, setDias] = useState(7);
  const carregar = useCallback(async () => {
    const de = new Date(Date.now() - dias * 86_400_000).toISOString();
    const { data, error } = await supabase().rpc("auditoria_lista", { p_de: de, p_ate: null, p_busca: busca.trim() || null, p_limite: 500 });
    if (error) { setErro(error.message.includes("apenas_gestor") ? "Só gestores veem o histórico." : "Não deu para carregar o histórico."); return; }
    setErro(null); setLinhas((data as Linha[]) ?? []);
  }, [busca, dias]);
  useEffect(() => { const t = setTimeout(carregar, 300); return () => clearTimeout(t); }, [carregar]);
  const filtradas = useMemo(() => (linhas ?? []).filter((l) => !tabela || l.tabela === tabela), [linhas, tabela]);
  const porDia = useMemo(() => {
    const m = new Map<string, Linha[]>();
    filtradas.forEach((l) => { const d = new Date(l.quando).toLocaleDateString("pt-BR", { weekday: "long", day: "2-digit", month: "long" }); m.set(d, [...(m.get(d) ?? []), l]); });
    return [...m.entries()];
  }, [filtradas]);

  return (
    <section className="conteudo historico">
      <CabecaPagina titulo="Histórico de mudanças" icone={History} subtitulo="Tudo o que gestores e supervisores mudaram, com o antes e o depois." />
      <div className="historico-filtros">
        <label className="campo-busca"><Search size={15} aria-hidden /><input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Buscar por pessoa, campo ou valor" /></label>
        <select value={tabela} onChange={(e) => setTabela(e.target.value)} aria-label="O que mudou">
          <option value="">Tudo</option>
          {Object.entries(TABELA).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </select>
        <select value={dias} onChange={(e) => setDias(Number(e.target.value))} aria-label="Período">
          <option value={1}>Hoje</option><option value={7}>7 dias</option><option value={30}>30 dias</option><option value={90}>90 dias</option>
        </select>
      </div>
      {erro && <p className="erro">{erro}</p>}
      {linhas && !filtradas.length && <p className="dica">Nada mudou nesse período.</p>}
      {porDia.map(([dia, ls]) => (
        <section key={dia} className="historico-dia">
          <h3 className="rotulo">{dia}</h3>
          <ol className="historico-lista">
            {ls.map((l) => {
              const A = ACAO[l.acao];
              return (
                <li key={l.id} className={`historico-item ${l.acao}`}>
                  <span className="historico-icone"><A.icone size={14} aria-hidden /></span>
                  <div className="historico-texto">
                    <span><strong>{l.autor}</strong> {A.rotulo} {(TABELA[l.tabela] ?? l.tabela).toLowerCase()}
                      {l.depois && typeof l.depois.numero === "number" ? ` #${l.depois.numero}` : l.antes && typeof l.antes.numero === "number" ? ` #${l.antes.numero}` : l.depois?.chave ? ` “${String(l.depois.chave)}”` : ""}</span>
                    <span className="dica">{new Date(l.quando).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })}</span>
                    <Diferencas l={l} />
                  </div>
                </li>
              );
            })}
          </ol>
        </section>
      ))}
    </section>
  );
}
