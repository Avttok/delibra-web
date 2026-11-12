"use client";

import { useEffect, useState } from "react";
import { Check, ChevronDown, Eye, EyeOff, MapPinned, Percent, Receipt, RotateCcw, Route, Sparkles, Wallet } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { moeda } from "@/features/precos/estrategias";
import { toast } from "@/features/ui/toast";
import { traduzir } from "@/features/pedidos/tipos";
import { PARAMETROS, type ValorParametro } from "@/features/configuracoes/definicoes";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { usePermissoes } from "@/features/conta/permissoes";
import type { CalculoPagamento, Corrida } from "./tipos";

type Regras = Record<string, ValorParametro>;

/** Os cálculos que dá para ligar numa rota, cada um com os valores dele. */
export const CALCULOS: { modo: string; nome: string; dica: string; icone: LucideIcon; grupo?: string; chaves?: string[] }[] = [
  { modo: "zonas", nome: "Zonas", dica: "Juntas pagam por km; espalhadas, uma porcentagem.", icone: MapPinned, grupo: "pag_zonas" },
  { modo: "rota", nome: "Por km", dica: "Km da entrega de referência × valor, mais extras.", icone: Route, grupo: "pag_km" },
  { modo: "percentual", nome: "Percentual", dica: "Uma parte do valor da rota.", icone: Percent, chaves: ["repasse_motoboy_pct"] },
  { modo: "por_entrega", nome: "Por entrega", dica: "Cada entrega paga o km dela mais um fixo.", icone: Receipt, grupo: "pag_entrega" },
  { modo: "fixo", nome: "Fixo", dica: "Um valor por rota, entrega e coleta.", icone: Wallet, grupo: "pag_fixo" },
  { modo: "salario", nome: "Salário fixo", dica: "Um valor por mês, no holerite.", icone: Wallet, chaves: ["pag_salario_mensal", "pag_salario_proporcional", "pag_minimo_periodo"] },
  { modo: "diaria", nome: "Diária", dica: "Um valor por dia trabalhado, no holerite.", icone: Wallet, chaves: ["pag_diaria_valor"] },
  { modo: "por_hora", nome: "Por hora", dica: "Um valor por hora em corrida, no holerite.", icone: Wallet, chaves: ["pag_hora_valor"] },
];
const JUNTAR = [{ v: "soma", r: "Somar" }, { v: "media", r: "Média" }, { v: "maior", r: "O maior" }, { v: "menor", r: "O menor" }];
const EXTRAS = ["pag_acrescimo_pct", "pag_acrescimo_rota", "pag_volta", "pag_volta_valor_km", "pag_volta_pct"];

const paramsDe = (c: (typeof CALCULOS)[number]) => PARAMETROS.filter((p) => (c.grupo && p.grupo === c.grupo) || c.chaves?.includes(p.chave));

/** Um campo pequeno de valor (número, liga/desliga ou escolha), sempre com o valor de agora. */
function Campo({ chave, regras, cfg, onDefinir }: { chave: string; regras: Regras; cfg: Record<string, unknown>; onDefinir: (k: string, v: ValorParametro | null) => void }) {
  const p = PARAMETROS.find((x) => x.chave === chave);
  if (!p) return null;
  const proprio = chave in regras;
  const valor = (proprio ? regras[chave] : (cfg[chave] as ValorParametro | undefined)) ?? p.padrao;
  return (
    <label className={`pag-campo${proprio ? " proprio" : ""}`} title={p.descricao || undefined}>
      <span>{p.rotulo}{proprio && <button type="button" className="pag-limpar" onClick={(e) => { e.preventDefault(); onDefinir(chave, null); }} aria-label={`Voltar ${p.rotulo} ao padrão`}><RotateCcw size={11} aria-hidden /></button>}</span>
      {p.tipo === "booleano" ? (
        <input type="checkbox" role="switch" checked={Boolean(valor)} onChange={(e) => onDefinir(chave, e.target.checked)} />
      ) : p.tipo === "escolha" ? (
        <select value={String(valor)} onChange={(e) => onDefinir(chave, e.target.value)}>
          {p.opcoes?.map((o) => <option key={o.valor} value={o.valor}>{o.rotulo}</option>)}
        </select>
      ) : (
        <span className="passo-campo">
          {p.unidade === "R$" && <span className="unidade">R$</span>}
          <input inputMode="decimal" defaultValue={String(valor).replace(".", ",")} key={`${chave}-${String(valor)}`}
            onBlur={(e) => { const n = Number(e.target.value.replace(",", ".")); if (!Number.isNaN(n) && n !== Number(valor)) onDefinir(chave, n); }} />
          {p.unidade && p.unidade !== "R$" && <span className="unidade">{p.unidade}</span>}
        </span>
      )}
    </label>
  );
}

/**
 * Editor dos cálculos de uma rota: liga e desliga cada cálculo, muda os valores dele
 * e escolhe como juntar. Não salva sozinho: quem usa decide quando salvar.
 */
export function EditorCalculos({ regras, onMudar, calc }: { regras: Regras; onMudar: (r: Regras) => void; calc?: CalculoPagamento | null }) {
  const c = useConfiguracoes() as unknown as Record<string, unknown>;
  const [aberto, setAberto] = useState<string | null>(null);
  const [extras, setExtras] = useState(false);
  const modosBase = (regras.pag_modos ?? c.pag_modos ?? []) as string[];
  const modeloUnico = (regras.pag_modo as string | undefined) ?? (c.pag_modo as string | undefined) ?? calc?.modo ?? "rota";
  const modos = modosBase.length ? modosBase : [modeloUnico === "combinado" ? "rota" : modeloUnico];
  const definir = (k: string, v: ValorParametro | null) => { const n = { ...regras }; if (v == null) delete n[k]; else n[k] = v; onMudar(n); };
  const alternar = (m: string) => {
    const novo = modos.includes(m) ? modos.filter((x) => x !== m) : [...modos, m];
    if (!novo.length) return toast("Deixe pelo menos um cálculo ligado.", "aviso");
    definir("pag_modos", novo);
  };
  const parteDe = (m: string) => calc?.partes?.find((p) => (p.parte ?? p.modo) === m) ?? (calc?.modo === m ? calc : undefined);
  const combinar = String(regras.pag_combinar ?? c.pag_combinar ?? "soma");

  return (
    <div className="pag-editor">
      <div className="pag-calculos">
        {CALCULOS.map((k) => {
          const ligado = modos.includes(k.modo);
          const parte = parteDe(k.modo);
          const Ic = k.icone;
          return (
            <div key={k.modo} className={`pag-calc${ligado ? " ligado" : ""}`}>
              <div className="pag-calc-topo">
                <span className="pag-calc-icone"><Ic size={16} aria-hidden /></span>
                <span className="pag-calc-nome"><strong>{k.nome}</strong><small>{k.dica}</small></span>
                {ligado && parte && <span className="pag-calc-valor">{moeda(parte.total ?? 0)}</span>}
                <input type="checkbox" role="switch" aria-label={`Usar ${k.nome}`} checked={ligado} onChange={() => alternar(k.modo)} />
              </div>
              {ligado && (
                <button type="button" className="pag-calc-abrir" aria-expanded={aberto === k.modo} onClick={() => setAberto(aberto === k.modo ? null : k.modo)}>
                  Valores deste cálculo <ChevronDown size={14} aria-hidden style={{ transform: aberto === k.modo ? "rotate(180deg)" : undefined }} />
                </button>
              )}
              {ligado && aberto === k.modo && (
                <div className="pag-campos">{paramsDe(k).map((p) => <Campo key={p.chave} chave={p.chave} regras={regras} cfg={c} onDefinir={definir} />)}</div>
              )}
            </div>
          );
        })}
      </div>
      {modos.length > 1 && (
        <div className="pag-juntar">
          <span>Como juntar os {modos.length} cálculos</span>
          <div className="escolhas" role="radiogroup" aria-label="Como juntar">
            {JUNTAR.map((j) => <button key={j.v} type="button" role="radio" aria-checked={combinar === j.v} className={combinar === j.v ? "ativo" : ""} onClick={() => definir("pag_combinar", j.v)}>{j.r}</button>)}
          </div>
        </div>
      )}
      <button type="button" className="pag-calc-abrir" aria-expanded={extras} onClick={() => setExtras(!extras)}>
        Acréscimos e volta <ChevronDown size={14} aria-hidden style={{ transform: extras ? "rotate(180deg)" : undefined }} />
      </button>
      {extras && <div className="pag-campos">{EXTRAS.map((k) => <Campo key={k} chave={k} regras={regras} cfg={c} onDefinir={definir} />)}</div>}
    </div>
  );
}

/** Cartão do pagamento do motoboy no detalhe da rota: total grande, cálculos e ajuste. Muda antes e depois do aceite. */
export function PagamentoMotoboy({ corrida, conta }: { corrida: Corrida; conta?: React.ReactNode }) {
  const c = corrida as Corrida & { pag_regras?: Regras | null; pag_ajuste_mostrar?: boolean | null };
  const original = c.pag_regras ?? {};
  const [regras, setRegras] = useState<Regras>(original);
  const [ajuste, setAjuste] = useState(String(corrida.pag_ajuste ?? 0).replace(".", ","));
  const [motivo, setMotivo] = useState(corrida.pag_ajuste_motivo ?? "");
  const [mostrar, setMostrar] = useState(c.pag_ajuste_mostrar !== false);
  const [ocupado, setOcupado] = useState(false);
  const [detalhe, setDetalhe] = useState(false);
  useEffect(() => { setRegras(c.pag_regras ?? {}); }, [JSON.stringify(c.pag_regras ?? {})]); // eslint-disable-line react-hooks/exhaustive-deps
  const mudou = JSON.stringify(regras) !== JSON.stringify(original);
  const proprias = Object.keys(original).length > 0;
  const perm = usePermissoes();
  const fechada = corrida.status === "cancelada" || !perm.pode("editar_pagamento_motoboy");

  async function rodar(f: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setOcupado(true);
    const { error } = await f();
    setOcupado(false);
    if (error) return toast(error.message.includes("holerite_fechado") ? "O holerite deste motoboy já foi fechado: lance um ajuste no holerite." : traduzir(error.message), "erro");
    toast(ok, "ok");
  }
  const salvarRegras = (r: Regras, ok: string) => rodar(() => supabase().rpc("definir_regras_rota", { p_corrida: corrida.id, p_regras: r, p_motivo: null }), ok);
  const salvarAjuste = () => rodar(() => supabase().rpc("ajustar_pagamento_rota", {
    p_corrida: corrida.id, p_ajuste: Number(ajuste.replace(",", ".")) || 0, p_motivo: motivo || null, p_mostrar: mostrar,
  }), "Ajuste salvo nesta rota.");

  return (
    <section className="bloco pag-cartao">
      <div className="pag-cabeca">
        <span className="pag-rotulo"><Wallet size={14} aria-hidden /> Pagamento do motoboy</span>
        <div className="pag-total">
          <strong>{moeda(corrida.valor_motoboy ?? corrida.pag_calculo?.total ?? 0)}</strong>
          <span className="pag-selos">
            {!corrida.motoboy_id && <span className="selo">Prévia</span>}
            {proprias && <span className="selo ouro"><Sparkles size={11} aria-hidden /> Só desta rota</span>}
          </span>
        </div>
        {conta && <button type="button" className="botao-texto" onClick={() => setDetalhe(!detalhe)}>{detalhe ? "Esconder a conta" : "Ver a conta"}</button>}
      </div>
      {detalhe && conta}

      {!fechada && (
        <>
          <EditorCalculos regras={regras} onMudar={setRegras} calc={corrida.pag_calculo} />
          <div className="linha-botoes">
            <button className="botao-ouro" disabled={ocupado || !mudou} onClick={() => salvarRegras(regras, "Cálculo desta rota salvo.")}><Check size={15} aria-hidden /> Salvar cálculo</button>
            {mudou && <button className="botao-texto" onClick={() => setRegras(original)}>Desfazer</button>}
            {proprias && <button className="botao-texto" disabled={ocupado} onClick={() => salvarRegras({}, "A rota volta ao cálculo padrão.")}><RotateCcw size={14} aria-hidden /> Padrão</button>}
          </div>

          <div className="pag-ajuste">
            <span className="pag-rotulo">Ajuste nesta rota</span>
            <div className="pedido-valor">
              <label className="campo"><span>Valor (+/−)</span><span className="passo-campo"><span className="unidade">R$</span><input inputMode="decimal" value={ajuste} onChange={(e) => setAjuste(e.target.value)} /></span></label>
              <label className="campo" style={{ flex: 2 }}><span>Motivo</span><input placeholder="Ex.: chuva, espera longa" value={motivo} onChange={(e) => setMotivo(e.target.value)} /></label>
            </div>
            <label className="opcao"><span>{mostrar ? <Eye size={14} aria-hidden /> : <EyeOff size={14} aria-hidden />} O motoboy vê o motivo</span>
              <input type="checkbox" role="switch" checked={mostrar} onChange={(e) => setMostrar(e.target.checked)} /></label>
            <div className="linha-botoes"><button className="botao-texto" disabled={ocupado} onClick={salvarAjuste}><Check size={14} aria-hidden /> Salvar ajuste</button></div>
          </div>
        </>
      )}
    </section>
  );
}
