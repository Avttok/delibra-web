"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { ArrowDown, ArrowUp, Check, Eye, Lightbulb, Merge, PackageOpen, Pencil, RotateCcw, Route, Save, Send, Split, Wand2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { moeda } from "@/features/precos/estrategias";
import { formatarKm } from "@/features/corridas/tipos";
import type { CalculoPagamento } from "@/features/corridas/tipos";
import { ContaMotoboy } from "@/features/corridas/BlocoRota";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { EditorRegras, fmtRegra } from "@/features/configuracoes/Excecoes";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { PARAMETROS, type ValorParametro } from "@/features/configuracoes/definicoes";
import { Dica } from "@/features/ui/Tour";
import { traduzir } from "./tipos";

interface ParadaPrevia { id: string; ordem: number; tipo: "coleta" | "entrega"; endereco: string; lat: number; lng: number; pedido_id: string | null; deste_pedido: boolean; dist_rua_m: number | null }
interface RotaPrevia {
  id: string; numero: number; status: string; valor: number | null; valor_manual: number | null; agendada_para: string | null; urgente: boolean;
  distancia_m: number | null; pag_regras: Record<string, ValorParametro> | null; pagamento: CalculoPagamento | null; rota_planejada: string | null;
  outros_pedidos: number; paradas: ParadaPrevia[];
}
interface Sugestoes { acoes: Record<string, number>; pedidos_revisados: number; regras_comuns: { regras: Record<string, ValorParametro>; vezes: number }[]; valor_medio_manual: number | null }

/** Regras de pagamento que dá para mudar numa rota (as dos Ajustes → Motoboys → pagamento). */
const GRUPOS_PAG = new Set(["pagamento", "pag_combinar", "pag_zonas", "pag_km", "pag_entrega", "pag_fixo"]);
const PARAMS_PAG = PARAMETROS.filter((p) => GRUPOS_PAG.has(p.grupo) && !p.soDev && !p.escondido);

/** Só os parâmetros das modalidades escolhidas (igual ao app); a volta mostra os detalhes só ligada. */
function paramsPag(regras: Record<string, unknown>, modoCalc?: string | null) {
  const lista = Array.isArray(regras.pag_modos) ? (regras.pag_modos as string[]) : [];
  const modos = new Set(lista.length ? lista : [String(regras.pag_modo ?? (modoCalc && modoCalc !== "combinado" ? modoCalc : "zonas"))]);
  const volta = regras.pag_volta === true;
  return PARAMS_PAG.filter((p) => {
    switch (p.grupo) {
      case "pag_zonas": return modos.has("zonas");
      case "pag_km": return modos.has("rota");
      case "pag_entrega": return modos.has("por_entrega");
      case "pag_fixo": return modos.has("fixo");
      case "pag_combinar": return modos.size > 1;
      default:
        if (p.chave === "repasse_motoboy_pct") return modos.has("percentual");
        if (["pag_volta_valor_km", "pag_volta_pct", "pag_volta_teto"].includes(p.chave)) return volta;
        return true;
    }
  });
}
const EDITAVEL = ["montada", "agendada", "aguardando_motoboy", "sem_motoboy"];
const ACAO: Record<string, string> = { separar: "separou entregas", mover: "moveu entregas", juntar: "juntou rotas", ordenar: "mudou a ordem", regras: "mudou o pagamento", valor: "mudou o valor da rota" };

/**
 * Rotas do pedido na revisão: prévia antes de aprovar, "aprovar e montar" (segura as rotas para você ajustar),
 * e as ferramentas de cada rota — ordem, separar, mover, juntar, valor, regras de pagamento com prévia e soltar.
 */
export function RotasDoPedido({ pedidoId, status, chave, onMudou }: { pedidoId: string; status: string; chave: string; onMudou?: () => void }) {
  const [dados, setDados] = useState<{ previa: boolean; rotas: RotaPrevia[] } | null>(null);
  const [sug, setSug] = useState<Sugestoes | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [r, s] = await Promise.all([sb.rpc("previa_rotas_pedido", { p_pedido: pedidoId }), sb.rpc("sugestoes_rota", { p_pedido: pedidoId })]);
    if (r.error) { setErro(r.error.message.includes("previa_rotas_pedido") ? "Rode a migração 20261110000019 para ver a prévia das rotas." : traduzir(r.error.message)); return; }
    setErro(null);
    const d = r.data as { previa: boolean; rotas: RotaPrevia[] };
    setDados(d);
    setSug((s.data as Sugestoes) ?? null);
    setAberta((a) => (a && d.rotas.some((x) => x.id === a) ? a : d.rotas[0]?.id ?? null));
  }, [pedidoId]);
  useEffect(() => { void carregar(); }, [carregar, chave]);

  async function rodar(f: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setOcupado(true);
    const { error } = await f();
    setOcupado(false);
    if (error) return toast(traduzir(error.message), "erro");
    toast(ok, "ok");
    await carregar();
    onMudou?.();
  }
  const sb = supabase();
  const rotas = dados?.rotas ?? [];
  const editaveis = rotas.filter((r) => !dados?.previa && EDITAVEL.includes(r.status));
  const atual = rotas.find((r) => r.id === aberta) ?? rotas[0];

  if (erro) return <p className="dica">{erro}</p>;
  if (!dados) return <p className="dica">Montando a prévia das rotas…</p>;

  return (
    <div className="rotas-pedido">
      <div className="rotas-pedido-topo">
        <h3 className="display" style={{ margin: 0 }}><Route size={18} aria-hidden /> {dados.previa ? "Prévia das rotas" : "Rotas deste pedido"}</h3>
        <Dica titulo="Rotas do pedido" texto="A prévia mostra como o roteirizador vai montar as rotas (com outros pedidos, se juntar) e quanto cada motoboy recebe. “Aprovar e montar” cria as rotas e segura: você muda a ordem, separa, junta, muda o valor e as regras de pagamento, e solta quando quiser." />
        <span className="espaco" />
        {dados.previa && status === "recebido" && (
          <button className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => sb.rpc("aprovar_e_montar", { p_pedido: pedidoId }), "Aprovado. As rotas estão montadas e seguras: ajuste e solte.")}>
            <Wand2 size={15} aria-hidden /> Aprovar e montar para ajustar
          </button>
        )}
      </div>
      {dados.previa && <p className="dica" style={{ margin: 0 }}><Eye size={12} aria-hidden /> Nada foi gravado ainda: é como o sistema montaria agora.</p>}
      {rotas.length === 0 && <p className="dica">{dados.previa ? "O roteirizador ainda não formaria rota com este pedido (veja as regras de rota e o pagamento antecipado)." : "Sem rotas."}</p>}

      {sug && (sug.pedidos_revisados > 0 || Object.keys(sug.acoes).length > 0) && (
        <div className="rotas-sugestao">
          <Lightbulb size={16} aria-hidden />
          <div>
            <strong>Com este cliente, nos últimos 60 dias, você</strong>{" "}
            {Object.entries(sug.acoes).filter(([k]) => ACAO[k]).map(([k, n]) => `${ACAO[k]} ${n}×`).join(", ") || "só aprovou"}.
            {sug.regras_comuns.length > 0 && <span className="dica"> Regras de pagamento que você mais usa aparecem em cada rota para aplicar com um toque.</span>}
          </div>
        </div>
      )}

      {rotas.length > 1 && (
        <div className="segmentado" style={{ gridTemplateColumns: `repeat(${rotas.length}, 1fr)` }}>
          {rotas.map((r, i) => (
            <button key={r.id} type="button" className={atual?.id === r.id ? "ativo" : ""} onClick={() => setAberta(r.id)}>
              {dados.previa ? `Rota ${i + 1}` : `#${r.numero}`} · {r.paradas.filter((x) => x.tipo === "entrega").length} entr.
            </button>
          ))}
        </div>
      )}

      {atual && <CartaoRota key={atual.id} r={atual} previa={dados.previa} outras={editaveis.filter((x) => x.id !== atual.id)} ocupado={ocupado} rodar={rodar} sug={sug} />}
    </div>
  );
}

function CartaoRota({ r, previa, outras, ocupado, rodar, sug }: {
  r: RotaPrevia; previa: boolean; outras: RotaPrevia[]; ocupado: boolean; sug: Sugestoes | null;
  rodar: (f: () => PromiseLike<{ error: { message: string } | null }>, ok: string) => Promise<void>;
}) {
  const sb = supabase();
  const cfg = useConfiguracoes();
  const editavel = !previa && EDITAVEL.includes(r.status);
  const [paradas, setParadas] = useState(r.paradas);
  const [valor, setValor] = useState(r.valor_manual != null ? String(r.valor_manual).replace(".", ",") : "");
  const [regras, setRegras] = useState<Record<string, ValorParametro>>(r.pag_regras ?? {});
  const [previaPag, setPreviaPag] = useState<CalculoPagamento | null>(null);
  const [verRegras, setVerRegras] = useState(Object.keys(r.pag_regras ?? {}).length > 0);
  const mudouRegras = JSON.stringify(regras) !== JSON.stringify(r.pag_regras ?? {});
  const mudouOrdem = paradas.map((x) => x.id).join() !== r.paradas.map((x) => x.id).join();

  // prévia do pagamento com as regras que ainda não foram salvas
  useEffect(() => {
    if (!mudouRegras || previa) { setPreviaPag(null); return; }
    const t = setTimeout(() => { void sb.rpc("previa_pagamento_rota", { p_corrida: r.id, p_regras: regras }).then(({ data }) => setPreviaPag((data as CalculoPagamento) ?? null)); }, 350);
    return () => clearTimeout(t);
  }, [JSON.stringify(regras)]); // eslint-disable-line react-hooks/exhaustive-deps

  const pinos: PinoParada[] = paradas.map((x, i) => ({ chave: x.id, lat: x.lat, lng: x.lng, tipo: x.tipo, rotulo: String(i + 1) }));
  const pag = previaPag ?? r.pagamento;
  const zonaPag = (pag as { zona?: { raio_m?: number } } | null)?.zona;
  const raioZona = zonaPag?.raio_m != null ? Number(zonaPag.raio_m) : null;
  const raioAtual = Math.round(Number(regras.zona_entrega_raio_m ?? raioZona ?? 1500));
  const entregas = paradas.filter((x) => x.tipo === "entrega").length;
  function mover(i: number, d: number) {
    const l = [...paradas]; const j = i + d; if (j < 0 || j >= l.length) return;
    [l[i], l[j]] = [l[j], l[i]]; setParadas(l);
  }
  const valorNum = valor.trim() === "" ? null : Number(valor.replace(/\./g, "").replace(",", "."));

  return (
    <div className="rota-previa">
      <div className="rota-previa-cabeca">
        <div>
          <strong>{previa ? "Rota nova" : `Rota #${r.numero}`}</strong>
          <span className="dica"> · {entregas} entrega{entregas === 1 ? "" : "s"} · {formatarKm(r.distancia_m)}{r.urgente ? " · urgente" : ""}
            {r.outros_pedidos > 0 ? ` · junto com ${r.outros_pedidos} outro${r.outros_pedidos > 1 ? "s" : ""} pedido${r.outros_pedidos > 1 ? "s" : ""}` : ""}</span>
        </div>
        <span className="espaco" />
        <span className="selo">{previa ? "prévia" : r.status === "montada" ? "segura (não solta)" : r.status.replace("_", " ")}</span>
        {!previa && <Link className="chip" href={`/gestor/corridas?c=${r.id}`}><Route size={13} aria-hidden /> Abrir</Link>}
      </div>

      <div className="rota-previa-grade">
        <div className="rota-previa-mapa"><MapaCorridas paradas={pinos} rotaPlanejada={mudouOrdem ? null : r.rota_planejada} enquadrar={r.id + paradas.length} legenda={false} /></div>

        <ol className="rota-previa-paradas">
          {paradas.map((x, i) => (
            <li key={x.id} className={x.deste_pedido ? "" : "outro"}>
              <span className={`pino-mini ${x.tipo}`}>{i + 1}</span>
              <span className="rota-previa-end">
                <strong>{x.tipo === "coleta" ? "Coleta" : "Entrega"}</strong> {x.endereco.split(",").slice(0, 2).join(",")}
                {!x.deste_pedido && <small> · outro pedido</small>}
                {x.dist_rua_m != null && x.tipo === "entrega" && <small> · {formatarKm(x.dist_rua_m)} da coleta</small>}
              </span>
              {editavel && (
                <span className="rota-previa-acoes">
                  <button type="button" className="icone" title="Subir" disabled={i === 0} onClick={() => mover(i, -1)}><ArrowUp size={13} /></button>
                  <button type="button" className="icone" title="Descer" disabled={i === paradas.length - 1} onClick={() => mover(i, 1)}><ArrowDown size={13} /></button>
                  {x.tipo === "entrega" && entregas > 1 && (
                    <button type="button" className="icone" title="Separar numa rota nova" disabled={ocupado}
                      onClick={() => rodar(() => sb.rpc("mover_entrega", { p_parada: x.id, p_destino: null }), "Entrega separada numa rota nova.")}><Split size={13} /></button>
                  )}
                  {x.tipo === "entrega" && outras.length > 0 && (
                    <select aria-label="Mover para" value="" disabled={ocupado} onChange={(e) => e.target.value && rodar(() => sb.rpc("mover_entrega", { p_parada: x.id, p_destino: e.target.value }), "Entrega movida.")}>
                      <option value="">Mover…</option>{outras.map((o) => <option key={o.id} value={o.id}>para a rota #{o.numero}</option>)}
                    </select>
                  )}
                </span>
              )}
            </li>
          ))}
        </ol>
      </div>
      {editavel && mudouOrdem && (
        <div className="linha-botoes">
          <button className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => sb.rpc("ordenar_paradas", { p_corrida: r.id, p_ordem: paradas.map((x) => x.id) }), "Ordem salva.")}><Save size={15} aria-hidden /> Salvar a ordem</button>
          <button className="botao-texto" onClick={() => setParadas(r.paradas)}><RotateCcw size={14} aria-hidden /> Desfazer</button>
        </div>
      )}

      <div className="rota-previa-dinheiro">
        <div className="rota-previa-valor">
          <span className="rotulo">Valor da rota</span>
          <strong className="figura">{moeda(r.valor)}</strong>
          {r.valor_manual != null && <span className="dica">valor fixo</span>}
          {editavel && (
            <div className="linha-botoes">
              <span className="passo-campo"><span className="unidade">R$</span><input inputMode="decimal" placeholder="Fixo (vazio = soma)" value={valor} onChange={(e) => setValor(e.target.value)} aria-label="Valor fixo da rota" /></span>
              <button className="botao-texto" disabled={ocupado || (valorNum != null && !Number.isFinite(valorNum))}
                onClick={() => rodar(() => sb.rpc("definir_valor_rota", { p_corrida: r.id, p_valor: valorNum, p_motivo: null }), valorNum == null ? "Valor volta a ser a soma dos pedidos." : "Valor da rota salvo.")}>
                <Pencil size={14} aria-hidden /> {valorNum == null ? "Usar a soma" : "Salvar"}</button>
            </div>
          )}
        </div>
        <div className="rota-previa-pag">
          <span className="rotulo">O motoboy que pegar recebe{previaPag ? " (prévia com as mudanças)" : ""}</span>
          {pag ? <ContaMotoboy calc={pag} /> : <p className="dica">Sem cálculo ainda.</p>}
          {pag && r.valor != null && <p className="dica" style={{ margin: 0 }}>Gestor: {moeda(Math.max(0, Number(r.valor) - Number(pag.total)))}</p>}
          {editavel && raioZona != null && (
            // raio da mesma zona direto aqui, só nesta rota (igual ao app)
            <div className="raio-rapido">
              <span><strong>Raio da mesma zona</strong><small>Só nesta rota</small></span>
              <button type="button" className="botao-icone" aria-label="Diminuir o raio" onClick={() => setRegras((o) => ({ ...o, zona_entrega_raio_m: Math.max(100, raioAtual - 100) }))}>−</button>
              <b>{raioAtual} m</b>
              <button type="button" className="botao-icone" aria-label="Aumentar o raio" onClick={() => setRegras((o) => ({ ...o, zona_entrega_raio_m: Math.min(20000, raioAtual + 100) }))}>+</button>
              {mudouRegras && <button className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => sb.rpc("definir_regras_rota", { p_corrida: r.id, p_regras: regras, p_motivo: null }), "Raio salvo nesta rota.")}>Salvar</button>}
            </div>
          )}
        </div>
      </div>

      {editavel && (
        <div className="rota-previa-regras">
          <button type="button" className="botao-texto" onClick={() => setVerRegras((v) => !v)}>
            <PackageOpen size={15} aria-hidden /> {verRegras ? "Esconder" : "Mudar"} as regras de pagamento desta rota{Object.keys(r.pag_regras ?? {}).length ? ` (${Object.keys(r.pag_regras ?? {}).length})` : ""}
          </button>
          {verRegras && (
            <>
              <p className="dica" style={{ margin: 0 }}>Valem só para esta rota, para quem pegar. Mude e veja a prévia acima antes de salvar.</p>
              {(sug?.regras_comuns ?? []).length > 0 && (
                <div className="linha-chips">
                  {sug!.regras_comuns.map((x, i) => (
                    <button key={i} type="button" className="chip" title={Object.entries(x.regras).map(([k, v]) => `${PARAMETROS.find((p) => p.chave === k)?.rotulo ?? k}: ${fmtRegra(v, k)}`).join("\n")}
                      onClick={() => setRegras(x.regras)}><Wand2 size={13} aria-hidden /> Usar as de costume ({x.vezes}×)</button>
                  ))}
                </div>
              )}
              <EditorRegras params={paramsPag(regras, (pag as { modo?: string } | null)?.modo)} valores={regras} cfg={cfg} estado={{}} onDefinir={(k, v) => setRegras((o) => { const n = { ...o }; if (v == null) delete n[k]; else n[k] = v; return n; })} />
              <div className="linha-botoes">
                <button className="botao-ouro" disabled={ocupado || !mudouRegras} onClick={() => rodar(() => sb.rpc("definir_regras_rota", { p_corrida: r.id, p_regras: regras, p_motivo: null }), "Regras desta rota salvas.")}><Check size={15} aria-hidden /> Salvar regras</button>
                {mudouRegras && <button className="botao-texto" onClick={() => setRegras(r.pag_regras ?? {})}><X size={14} aria-hidden /> Desfazer</button>}
                {Object.keys(r.pag_regras ?? {}).length > 0 && <button className="botao-texto" onClick={() => rodar(() => sb.rpc("definir_regras_rota", { p_corrida: r.id, p_regras: {}, p_motivo: null }), "A rota volta às regras de sempre.")}><RotateCcw size={14} aria-hidden /> Voltar às regras de sempre</button>}
              </div>
            </>
          )}
        </div>
      )}

      {editavel && (
        <div className="linha-botoes">
          {outras.length > 0 && (
            <select aria-label="Juntar com" value="" disabled={ocupado} onChange={(e) => e.target.value && rodar(() => sb.rpc("juntar_rotas", { p_origem: r.id, p_destino: e.target.value }), "Rotas juntadas.")}>
              <option value="">Juntar com…</option>{outras.map((o) => <option key={o.id} value={o.id}>a rota #{o.numero}</option>)}
            </select>
          )}
          <span className="espaco" />
          {r.status === "montada" && (
            <button className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => sb.rpc("liberar_rota", { p_corrida: r.id }), "Rota solta para os motoboys.")}><Send size={15} aria-hidden /> Soltar para os motoboys</button>
          )}
        </div>
      )}
      {!editavel && !previa && <p className="dica" style={{ margin: 0 }}>Rota já com motoboy ou finalizada: o pagamento só muda no detalhe da rota.</p>}
      <p className="dica" style={{ margin: 0 }}>
        <Merge size={12} aria-hidden /> Tudo o que você muda aqui (ordem, separar, juntar, valor e regras) fica registrado e ajuda o sistema a sugerir da próxima vez.
      </p>
    </div>
  );
}

