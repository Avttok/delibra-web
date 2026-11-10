"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Ban, CheckCircle2, Download, FilePlus2, Receipt, Send, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { useEmpresas } from "@/features/corridas/dados";
import { useModoTeste } from "@/features/teste/modoTeste";
import { toast } from "@/features/ui/toast";
import { moedaBr, quando, traduzir } from "@/features/pedidos/tipos";

interface Fatura {
  id: string; numero: number; empresa_id: string; inicio: string; fim: string; status: "rascunho" | "emitida" | "paga" | "cancelada";
  subtotal: number; ajuste: number; ajuste_motivo: string | null; total: number; dev_pct: number | null; valor_dev: number | null;
  vencimento: string | null; emitida_em: string | null; paga_em: string | null; pagamento_metodo: string | null;
}
interface PedidoFatura { id: string; numero: number; concluido_em: string | null; valor: number | null; fatura_id: string | null; empresa_id: string | null }

const COR = { rascunho: "#f59e0b", emitida: "#60a5fa", paga: "#2ecc71", cancelada: "#8a8a8a" };
const ROT = { rascunho: "Rascunho", emitida: "Emitida", paga: "Paga", cancelada: "Cancelada" };
const data = (d: string | null) => (d ? new Date(`${d}T12:00:00`).toLocaleDateString("pt-BR") : "—");
const hojeIso = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);

/** Faturas dos clientes no crédito: geradas por ciclo (ou à mão), revisadas, emitidas e baixadas. */
export function Faturas() {
  const { teste } = useModoTeste();
  const { empresas } = useEmpresas();
  const [faturas, setFaturas] = useState<Fatura[]>([]);
  const [abertos, setAbertos] = useState<PedidoFatura[]>([]);
  const [sel, setSel] = useState<string | null>(null);
  const [pedidosSel, setPedidosSel] = useState<PedidoFatura[]>([]);
  const [novo, setNovo] = useState<{ cliente: string; inicio: string; fim: string } | null>(null);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [f, p] = await Promise.all([
      sb.from("faturas").select("*").eq("teste", teste).order("criado_em", { ascending: false }).limit(300),
      sb.from("pedidos").select("id,numero,concluido_em,valor,fatura_id,empresa_id").eq("teste", teste).eq("cobranca", "credito").eq("status", "concluido").is("fatura_id", null).limit(2000),
    ]);
    setFaturas((f.data ?? []) as Fatura[]);
    setAbertos((p.data ?? []) as PedidoFatura[]);
  }, [teste]);
  useEffect(() => { void carregar(); }, [carregar]);
  useEffect(() => {
    if (!sel) return;
    supabase().from("pedidos").select("id,numero,concluido_em,valor,fatura_id,empresa_id").eq("fatura_id", sel).order("concluido_em")
      .then(({ data: d }) => setPedidosSel((d ?? []) as PedidoFatura[]));
  }, [sel, faturas]);

  const nome = (id: string | null) => empresas.find((e) => e.id === id)?.nome ?? "—";
  const emAberto = useMemo(() => {
    const m = new Map<string, { n: number; v: number }>();
    for (const p of abertos) { if (!p.empresa_id) continue; const a = m.get(p.empresa_id) ?? { n: 0, v: 0 }; a.n++; a.v += Number(p.valor ?? 0); m.set(p.empresa_id, a); }
    return [...m.entries()].sort((a, b) => b[1].v - a[1].v);
  }, [abertos]);
  const atual = faturas.find((f) => f.id === sel);

  async function acao(f: Fatura, a: string, extra: Record<string, unknown> = {}) {
    const { error } = await supabase().rpc("editar_fatura", { p_fatura: f.id, p_acao: a, ...extra });
    if (error) return toast(traduzir(error.message), "erro");
    toast(a === "emitir" ? "Fatura emitida: o cliente já vê no site dele." : a === "paga" ? "Fatura baixada como paga." : a === "cancelar" ? "Fatura cancelada; os pedidos voltaram para em aberto." : "Fatura atualizada.", "ok");
    void carregar();
  }
  async function gerar() {
    if (!novo?.cliente) return;
    const { data: id, error } = await supabase().rpc("gerar_fatura", { p_cliente: novo.cliente, p_inicio: novo.inicio, p_fim: novo.fim, p_teste: teste });
    if (error) return toast(traduzir(error.message), "erro");
    toast("Fatura gerada como rascunho.", "ok");
    setNovo(null); setSel(id as string); void carregar();
  }
  function planilha(f: Fatura) {
    const linhas = [["Pedido", "Concluído", "Valor"], ...pedidosSel.map((p) => [`#${p.numero}`, quando(p.concluido_em), String(p.valor ?? 0).replace(".", ",")]),
      [], ["Subtotal", "", String(f.subtotal).replace(".", ",")], ["Ajuste", f.ajuste_motivo ?? "", String(f.ajuste).replace(".", ",")], ["Total", "", String(f.total).replace(".", ",")]];
    const blob = new Blob(["﻿" + linhas.map((l) => l.map((v) => `"${v}"`).join(";")).join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = `fatura-${f.numero}-${nome(f.empresa_id).replace(/\W+/g, "-")}.csv`; a.click();
  }

  return (
    <div className="faturas">
      {emAberto.length > 0 && (
        <div className="bloco">
          <span className="rotulo">Em aberto (concluídos, ainda sem fatura)</span>
          <div className="linha-botoes">
            {emAberto.map(([id, a]) => (
              <button key={id} className="chip" onClick={() => setNovo({ cliente: id, inicio: abertos.filter((p) => p.empresa_id === id).map((p) => (p.concluido_em ?? "").slice(0, 10)).sort()[0] || hojeIso(), fim: hojeIso() })}>
                {nome(id)} · {a.n} pedido{a.n === 1 ? "" : "s"} · {moedaBr(a.v)}
              </button>
            ))}
          </div>
          <p className="dica" style={{ margin: 0 }}>As faturas também saem sozinhas no fim do ciclo de cada cliente (Configurações → Cobrança e faturas).</p>
        </div>
      )}
      <div className="linha-botoes">
        <button className="botao-texto" onClick={() => setNovo({ cliente: empresas[0]?.id ?? "", inicio: hojeIso(), fim: hojeIso() })}><FilePlus2 size={15} aria-hidden /> Gerar fatura</button>
      </div>
      {novo && (
        <div className="catalogo-form vidro">
          <div className="grade-campos">
            <label className="campo"><span>Cliente</span><select value={novo.cliente} onChange={(e) => setNovo({ ...novo, cliente: e.target.value })}>{empresas.map((e) => <option key={e.id} value={e.id}>{e.nome}</option>)}</select></label>
            <label className="campo"><span>De</span><input type="date" value={novo.inicio} onChange={(e) => setNovo({ ...novo, inicio: e.target.value })} /></label>
            <label className="campo"><span>Até</span><input type="date" value={novo.fim} onChange={(e) => setNovo({ ...novo, fim: e.target.value })} /></label>
          </div>
          <div className="linha-botoes"><button className="botao-ouro" onClick={gerar}><Receipt size={15} aria-hidden /> Gerar rascunho</button><button className="botao-texto" onClick={() => setNovo(null)}>Cancelar</button></div>
        </div>
      )}
      <div className="dev-rolagem">
        <table className="tabela tabela-clicavel">
          <thead><tr><th>Nº</th><th>Cliente</th><th>Período</th><th>Situação</th><th>Vence</th><th>Total</th><th>Dev</th></tr></thead>
          <tbody>
            {faturas.map((f) => (
              <tr key={f.id} className={sel === f.id ? "ativo" : ""} onClick={() => setSel(sel === f.id ? null : f.id)}>
                <td>{f.numero}</td><td>{nome(f.empresa_id)}</td><td>{data(f.inicio)}–{data(f.fim)}</td>
                <td><span className="selo" style={{ color: COR[f.status] }}>{ROT[f.status]}</span></td><td>{data(f.vencimento)}</td>
                <td><strong>{moedaBr(f.total)}</strong></td><td>{moedaBr(f.valor_dev)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        {faturas.length === 0 && <p className="vazio">Nenhuma fatura ainda.</p>}
      </div>
      {atual && <DetalheFatura key={atual.id} f={atual} pedidos={pedidosSel} nome={nome(atual.empresa_id)} onAcao={acao} onPlanilha={() => planilha(atual)} onFechar={() => setSel(null)} />}
    </div>
  );
}

function DetalheFatura({ f, pedidos, nome, onAcao, onPlanilha, onFechar }: {
  f: Fatura; pedidos: PedidoFatura[]; nome: string; onAcao: (f: Fatura, a: string, extra?: Record<string, unknown>) => void; onPlanilha: () => void; onFechar: () => void;
}) {
  const [ajuste, setAjuste] = useState(String(f.ajuste).replace(".", ","));
  const [motivo, setMotivo] = useState(f.ajuste_motivo ?? "");
  const [venc, setVenc] = useState(f.vencimento ?? "");
  const editavel = f.status === "rascunho" || f.status === "emitida";
  return (
    <div className="catalogo-form vidro fatura-detalhe">
      <div className="titulo-linha">
        <h3 className="display" style={{ margin: 0 }}>Fatura {f.numero} · {nome}</h3>
        <span className="selo" style={{ color: COR[f.status] }}>{ROT[f.status]}</span>
        <button className="icone" aria-label="Fechar" onClick={onFechar}><X size={16} /></button>
      </div>
      <table className="tabela"><thead><tr><th>Pedido</th><th>Concluído</th><th>Valor</th>{f.status === "rascunho" && <th />}</tr></thead>
        <tbody>{pedidos.map((p) => (
          <tr key={p.id}><td>#{p.numero}</td><td>{quando(p.concluido_em)}</td><td>{moedaBr(p.valor)}</td>
            {f.status === "rascunho" && <td><button className="link" onClick={() => onAcao(f, "tirar_pedido", { p_pedido: p.id })}>tirar</button></td>}</tr>
        ))}</tbody></table>
      {editavel && (
        <div className="pedido-valor">
          <label className="campo"><span>Ajuste (+/−)</span><span className="passo-campo"><span className="unidade">R$</span><input inputMode="decimal" value={ajuste} onChange={(e) => setAjuste(e.target.value)} /></span></label>
          <label className="campo" style={{ flex: 2 }}><span>Motivo</span><input value={motivo} placeholder="Ex.: desconto, taxa extra combinada" onChange={(e) => setMotivo(e.target.value)} /></label>
          <label className="campo"><span>Vencimento</span><input type="date" value={venc} onChange={(e) => setVenc(e.target.value)} /></label>
        </div>
      )}
      <div className="orcamento">
        <div className="orcamento-linha"><span>Subtotal ({pedidos.length} pedido{pedidos.length === 1 ? "" : "s"})</span><strong>{moedaBr(f.subtotal)}</strong></div>
        {Number(f.ajuste) !== 0 && <div className="orcamento-linha"><span>Ajuste{f.ajuste_motivo && <small>{f.ajuste_motivo}</small>}</span><strong>{moedaBr(f.ajuste)}</strong></div>}
        <div className="orcamento-linha total"><span>Total</span><strong>{moedaBr(f.total)}</strong></div>
        <p className="dica" style={{ margin: 0 }}>Dev {Number(f.dev_pct ?? 5).toLocaleString("pt-BR")}%: {moedaBr(f.valor_dev)} · gestão {moedaBr(Number(f.total) - Number(f.valor_dev ?? 0))}</p>
      </div>
      <div className="linha-botoes">
        {editavel && <button className="botao-texto" onClick={() => onAcao(f, "ajustar", { p_ajuste: Number(ajuste.replace(",", ".")) || 0, p_motivo: motivo || null, p_vencimento: venc || null })}>Salvar ajuste</button>}
        {f.status === "rascunho" && <button className="botao-ouro" onClick={() => onAcao(f, "emitir", { p_vencimento: venc || null })}><Send size={15} aria-hidden /> Emitir</button>}
        {f.status === "emitida" && <>
          <button className="botao-ouro" onClick={() => onAcao(f, "paga", { p_metodo: "pix" })}><CheckCircle2 size={15} aria-hidden /> Paga no PIX</button>
          <button className="botao-texto" onClick={() => onAcao(f, "paga", { p_metodo: "cartao" })}>Paga no cartão</button>
          <button className="botao-texto" onClick={() => onAcao(f, "paga", { p_metodo: "outro" })}>Outro</button>
        </>}
        <button className="botao-texto" onClick={onPlanilha}><Download size={15} aria-hidden /> Planilha</button>
        <span className="espaco" />
        {f.status !== "paga" && f.status !== "cancelada" && <button className="botao-perigo" onClick={() => confirm("Cancelar esta fatura? Os pedidos voltam para em aberto.") && onAcao(f, "cancelar")}><Ban size={15} aria-hidden /> Cancelar</button>}
      </div>
    </div>
  );
}
