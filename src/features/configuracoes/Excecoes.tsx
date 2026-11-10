"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Bike, Building2, Layers, RotateCcw, Search, Tags } from "lucide-react";
import { useConfiguracoes } from "./useConfiguracoes";
import { supabase } from "@/lib/supabase/client";
import { useEmpresas, useEquipe } from "@/features/corridas/dados";
import { useConta } from "@/features/conta/conta";
import { toast } from "@/features/ui/toast";
import { AREAS, GRUPOS, PARAMETROS, ROTULO_ESCOPO, type AreaParametro, type Configuracoes, type Escopo, type ValorParametro } from "./definicoes";
import { Parametro } from "./PainelConfiguracoes";

interface Politica { escopo: Escopo; alvo: string; chave: string; valor: ValorParametro }
interface Tipo { chave: string; nome: string }

const ICONE = { cliente: Building2, motoboy: Bike, tipo: Tags };

export const fmtRegra = (v: ValorParametro, chave: string) => {
  const p = PARAMETROS.find((x) => x.chave === chave);
  if (typeof v === "boolean") return v ? "ligado" : "desligado";
  if (Array.isArray(v)) return v.length ? v.map((x) => p?.opcoes?.find((o) => o.valor === x)?.rotulo ?? x).join(", ") : "nenhum";
  const op = p?.opcoes?.find((o) => o.valor === v);
  if (op) return op.rotulo;
  return `${p?.unidade === "R$" ? "R$ " : ""}${String(v).replace(".", ",")}${p?.unidade && p.unidade !== "R$" ? ` ${p.unidade}` : ""}`;
};
const fmt = fmtRegra;

/**
 * Lista de regras com o valor da exceção (ou o padrão), organizada como os Ajustes: áreas, seções,
 * busca e "só as exceções". Serve para cliente, motoboy, tipo e pedido.
 */
export function EditorRegras({ params, valores, cfg, estado, onDefinir, filtro }: {
  params: typeof PARAMETROS;
  valores: Record<string, ValorParametro>;
  cfg: Configuracoes;
  estado: Record<string, "salvando" | "salvo" | "erro" | undefined>;
  onDefinir: (chave: string, valor: ValorParametro | null) => void;
  filtro?: string;
}) {
  const conta = useConta();
  const [area, setArea] = useState<AreaParametro | "todas">("todas");
  const [secao, setSecao] = useState<string | null>(null);
  const [soExc, setSoExc] = useState(false);
  const termo = sem((filtro ?? "").trim());
  const areas = AREAS.filter((a) => params.some((p) => GRUPOS[p.grupo].area === a.chave));
  const conta_ = (lista: typeof PARAMETROS) => lista.filter((p) => p.chave in valores).length;
  let lista = params;
  if (termo) lista = lista.filter((p) => sem(`${p.rotulo} ${p.descricao} ${GRUPOS[p.grupo].titulo}`).includes(termo));
  else {
    if (area !== "todas") lista = lista.filter((p) => GRUPOS[p.grupo].area === area);
    if (secao) lista = lista.filter((p) => p.grupo === secao);
  }
  if (soExc) lista = lista.filter((p) => p.chave in valores);
  const secoes = area === "todas" ? [] : (Object.keys(GRUPOS) as (keyof typeof GRUPOS)[]).filter((g) => GRUPOS[g].area === area && params.some((p) => p.grupo === g));
  return (
    <div className="config-lista">
      {!termo && (
        <div className="regras-areas">
          <button type="button" className={`chip${area === "todas" ? " ativo" : ""}`} onClick={() => { setArea("todas"); setSecao(null); }}>
            Tudo{conta_(params) ? <span className="filtro-n">{conta_(params)}</span> : null}
          </button>
          {areas.map((a) => {
            const n = conta_(params.filter((p) => GRUPOS[p.grupo].area === a.chave));
            return (
              <button key={a.chave} type="button" className={`chip${area === a.chave ? " ativo" : ""}`} onClick={() => { setArea(a.chave); setSecao(null); }} title={a.descricao}>
                {a.titulo}{n ? <span className="filtro-n">{n}</span> : null}
              </button>
            );
          })}
        </div>
      )}
      {secoes.length > 1 && !termo && (
        <div className="regras-secoes">
          {secoes.map((g) => (
            <button key={g} type="button" className={`chip mini${secao === g ? " ativo" : ""}`} onClick={() => setSecao(secao === g ? null : g)}>{GRUPOS[g].titulo}</button>
          ))}
        </div>
      )}
      <label className="config-so-mudados"><input type="checkbox" role="switch" checked={soExc} onChange={(e) => setSoExc(e.target.checked)} /> Só as exceções ({conta_(params)})</label>
      {lista.length === 0 && <p className="dica">{soExc ? "Nenhuma exceção aqui: tudo usa o padrão." : "Nenhuma regra encontrada."}</p>}
      {(Object.keys(GRUPOS) as (keyof typeof GRUPOS)[]).map((g) => {
        const doGrupo = lista.filter((p) => p.grupo === g);
        if (!doGrupo.length) return null;
        return (
          <section key={g} className="excecoes-grupo">
            <h3 className="rotulo">{(area === "todas" || termo) ? `${AREAS.find((a) => a.chave === GRUPOS[g].area)?.titulo} · ` : ""}{GRUPOS[g].titulo}</h3>
            <p className="dica" style={{ margin: "0 0 6px" }}>{GRUPOS[g].descricao}</p>
            {doGrupo.map((p) => {
              const tem = p.chave in valores;
              const bloqueado = p.soDev && !conta.dev;
              return (
                <div key={p.chave} className={`excecao ${tem ? "com" : "sem"}`}>
                  <Parametro p={p} valor={tem ? valores[p.chave] : cfg[p.chave]} estado={estado[p.chave]} mostrarGrupo={false} bloqueado={bloqueado}
                    onSalvar={(v) => onDefinir(p.chave, v)}
                    extra={tem
                      ? <span className="excecao-tag">Exceção · padrão: {fmt(cfg[p.chave], p.chave)}
                          {!bloqueado && <button type="button" className="link" onClick={() => onDefinir(p.chave, null)}><RotateCcw size={11} aria-hidden /> usar o padrão</button>}</span>
                      : <span className="excecao-tag padrao">Usando o padrão · mude para criar a exceção</span>} />
                </div>
              );
            })}
          </section>
        );
      })}
    </div>
  );
}

const sem = (t: string) => t.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Peças do lego de um cliente ou motoboy, direto no perfil dele. */
export function RegrasDoAlvo({ escopo, alvo, nome }: { escopo: Escopo; alvo: string; nome: string }) {
  const cfg = useConfiguracoes();
  const conta = useConta();
  const [valores, setValores] = useState<Record<string, ValorParametro>>({});
  const [estado, setEstado] = useState<Record<string, "salvando" | "salvo" | "erro" | undefined>>({});
  const [busca, setBusca] = useState("");
  const carregar = useCallback(() => {
    supabase().from("politicas").select("chave,valor").eq("escopo", escopo).eq("alvo", alvo)
      .then(({ data }) => setValores(Object.fromEntries(((data ?? []) as { chave: string; valor: ValorParametro }[]).map((x) => [x.chave, x.valor]))));
  }, [escopo, alvo]);
  useEffect(() => { carregar(); }, [carregar]);
  async function definir(chave: string, valor: ValorParametro | null) {
    setEstado((e) => ({ ...e, [chave]: "salvando" }));
    const { error } = await supabase().rpc("definir_politica", { p_escopo: escopo, p_alvo: alvo, p_chave: chave, p_valor: valor });
    if (error) { setEstado((e) => ({ ...e, [chave]: "erro" })); toast(error.message.includes("apenas_dev") ? "Só o Dev altera a parte do Dev." : error.message, "erro"); return; }
    setEstado((e) => ({ ...e, [chave]: "salvo" }));
    setTimeout(() => setEstado((e) => ({ ...e, [chave]: undefined })), 1500);
    carregar();
  }
  const n = Object.keys(valores).length;
  return (
    <div className="excecoes">
      <p className="dica" style={{ margin: 0 }}><Layers size={12} aria-hidden /> Regras só de <strong>{nome}</strong>{n ? ` · ${n} diferente${n === 1 ? "" : "s"} do padrão` : " · tudo no padrão"}. {escopo === "cliente" ? "Valem para todos os pedidos dele (um pedido pode ter regras próprias)." : "Valem para todas as rotas dele."}</p>
      <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar regra" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
      <EditorRegras params={PARAMETROS.filter((p) => p.escopos?.includes(escopo) && (conta.dev || !p.escondido))} valores={valores} cfg={cfg} estado={estado} onDefinir={definir} filtro={busca} />
    </div>
  );
}

/** Regras diferentes do padrão para um cliente, um motoboy ou um tipo de pedido. Vence: motoboy > cliente > tipo > padrão. */
export function Excecoes({ cfg }: { cfg: Configuracoes }) {
  const conta = useConta();
  const { empresas } = useEmpresas();
  const equipe = useEquipe();
  const [tipos, setTipos] = useState<Tipo[]>([]);
  const [escopo, setEscopo] = useState<Escopo>("cliente");
  const [alvo, setAlvo] = useState("");
  const [politicas, setPoliticas] = useState<Politica[]>([]);
  const [estado, setEstado] = useState<Record<string, "salvando" | "salvo" | "erro" | undefined>>({});

  const carregar = useCallback(() => {
    supabase().from("politicas").select("escopo,alvo,chave,valor").then(({ data }) => setPoliticas((data ?? []) as Politica[]));
  }, []);
  useEffect(() => { carregar(); supabase().from("tipos_pedido").select("chave,nome").order("ordem").then(({ data }) => setTipos((data ?? []) as Tipo[])); }, [carregar]);

  const alvos = useMemo(() => {
    if (escopo === "cliente") return empresas.map((e) => ({ id: e.id, nome: e.nome }));
    if (escopo === "motoboy") return equipe.map((m) => ({ id: m.id, nome: m.nome }));
    return tipos.map((t) => ({ id: t.chave, nome: t.nome }));
  }, [escopo, empresas, equipe, tipos]);
  useEffect(() => { if (!alvos.some((a) => a.id === alvo)) setAlvo(alvos[0]?.id ?? ""); }, [alvos, alvo]);

  const params = PARAMETROS.filter((p) => p.escopos?.includes(escopo) && (conta.dev || !p.escondido));
  const minhas = politicas.filter((x) => x.escopo === escopo && x.alvo === alvo);
  const contagem = (id: string) => politicas.filter((x) => x.escopo === escopo && x.alvo === id).length;

  async function definir(chave: string, valor: ValorParametro | null) {
    setEstado((e) => ({ ...e, [chave]: "salvando" }));
    const { error } = await supabase().rpc("definir_politica", { p_escopo: escopo, p_alvo: alvo, p_chave: chave, p_valor: valor });
    if (error) {
      setEstado((e) => ({ ...e, [chave]: "erro" }));
      toast(error.message.includes("apenas_dev") ? "Só o Dev altera a parte do Dev." : error.message, "erro");
      return;
    }
    setEstado((e) => ({ ...e, [chave]: "salvo" }));
    setTimeout(() => setEstado((e) => ({ ...e, [chave]: undefined })), 1500);
    carregar();
  }

  const Icone = ICONE[escopo];

  return (
    <div className="excecoes">
      <div className="segmentado" style={{ gridTemplateColumns: "repeat(3, 1fr)", maxWidth: 520 }}>
        {(["cliente", "motoboy", "tipo"] as Escopo[]).map((e) => {
          const I = ICONE[e];
          return <button key={e} type="button" className={escopo === e ? "ativo" : ""} onClick={() => setEscopo(e)}><I size={14} aria-hidden /> {ROTULO_ESCOPO[e]}</button>;
        })}
      </div>
      <p className="dica" style={{ margin: 0 }}>
        <Layers size={12} aria-hidden /> Quem vence: <strong>motoboy</strong> &gt; <strong>cliente</strong> &gt; <strong>tipo de pedido</strong> &gt; padrão do sistema.
      </p>
      {alvos.length === 0 ? <p className="vazio">Nada para escolher aqui ainda.</p> : (
        <div className="excecoes-alvos">
          {alvos.map((a) => (
            <button key={a.id} type="button" className={`chip ${alvo === a.id ? "ativo" : ""}`} onClick={() => setAlvo(a.id)}>
              <Icone size={13} aria-hidden /> {a.nome}{contagem(a.id) > 0 && <span className="chip-n">{contagem(a.id)}</span>}
            </button>
          ))}
        </div>
      )}
      {alvo && (
        <>
          {minhas.length > 0 && (
            <div className="excecoes-resumo">
              <span className="rotulo">Exceções de {alvos.find((a) => a.id === alvo)?.nome}</span>
              <div className="excecoes-alvos">
                {minhas.map((x) => (
                  <span key={x.chave} className="selo" style={{ color: "var(--ouro)" }}>
                    {PARAMETROS.find((p) => p.chave === x.chave)?.rotulo ?? x.chave}: {fmt(x.valor, x.chave)}
                  </span>
                ))}
              </div>
            </div>
          )}
          <EditorRegras params={params} valores={Object.fromEntries(minhas.map((x) => [x.chave, x.valor]))} cfg={cfg} estado={estado} onDefinir={definir} />
        </>
      )}
    </div>
  );
}
