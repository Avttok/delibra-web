"use client";

import { useMemo, useState } from "react";
import { Pencil, Plus, RotateCcw, Save, Trash2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { moedaBr, traduzir, type LinhaOrcamento, type Orcamento } from "./tipos";
import { OrcamentoDetalhe } from "./FormPedido";

type Linha = { rotulo: string; qtd: string; unit: string; unidade: string; valor: string; fixo: boolean; chave?: string };
const num = (s: string) => { const n = Number(String(s).replace(",", ".")); return Number.isFinite(n) ? n : 0; };
const txt = (n?: number | null) => (n == null ? "" : String(n).replace(".", ","));
const deLinha = (l: LinhaOrcamento): Linha => ({ rotulo: l.rotulo, qtd: txt(l.qtd), unit: txt(l.unit), unidade: l.unidade ?? "", valor: txt(l.valor), fixo: Boolean(l.fixo), chave: l.chave });

/**
 * "Como chegou no valor" com edição: cada linha pode ter quantidade × valor unitário (ex.: 4,2 km × R$ 2,50)
 * ou só o valor final; os percentuais e o mínimo também mudam. O total é refeito no servidor.
 */
export function EditarOrcamento({ pedidoId, orc, bloqueado, onSalvo }: { pedidoId: string; orc: Orcamento; bloqueado?: boolean; onSalvo?: () => void }) {
  const [editando, setEditando] = useState(false);
  const [linhas, setLinhas] = useState<Linha[]>(() => orc.linhas.map(deLinha));
  const [pcts, setPcts] = useState(() => orc.percentuais.map((p) => ({ rotulo: p.rotulo, pct: txt(p.pct) })));
  const [minimo, setMinimo] = useState(txt(orc.minimo));
  const [motivo, setMotivo] = useState("");
  const [salvando, setSalvando] = useState(false);

  const valorDe = (l: Linha) => (l.qtd.trim() !== "" && l.unit.trim() !== "" ? Math.round(num(l.qtd) * num(l.unit) * 100) / 100 : num(l.valor));
  const previa = useMemo(() => {
    const sub = linhas.filter((l) => !l.fixo).reduce((s, l) => s + valorDe(l), 0);
    const fix = linhas.filter((l) => l.fixo).reduce((s, l) => s + valorDe(l), 0);
    const pct = pcts.reduce((s, p) => s + num(p.pct), 0);
    return Math.max(sub * (1 + pct / 100) + fix, num(minimo), 0);
  }, [linhas, pcts, minimo]); // eslint-disable-line react-hooks/exhaustive-deps

  const mudar = (i: number, d: Partial<Linha>) => setLinhas((l) => l.map((x, k) => (k === i ? { ...x, ...d } : x)));
  function abrir() { setLinhas(orc.linhas.map(deLinha)); setPcts(orc.percentuais.map((p) => ({ rotulo: p.rotulo, pct: txt(p.pct) }))); setMinimo(txt(orc.minimo)); setEditando(true); }
  function original() {
    const o = orc.original ?? orc;
    setLinhas(o.linhas.map(deLinha)); setPcts(o.percentuais.map((p) => ({ rotulo: p.rotulo, pct: txt(p.pct) }))); setMinimo(txt(o.minimo));
  }

  async function salvar() {
    setSalvando(true);
    const { error } = await supabase().rpc("editar_orcamento", {
      p_pedido: pedidoId,
      p_linhas: linhas.map((l) => ({ rotulo: l.rotulo.trim(), chave: l.chave, unidade: l.unidade || null, fixo: l.fixo,
        ...(l.qtd.trim() !== "" && l.unit.trim() !== "" ? { qtd: num(l.qtd), unit: num(l.unit) } : { valor: num(l.valor) }) })),
      p_percentuais: pcts.map((p) => ({ rotulo: p.rotulo.trim(), pct: num(p.pct) })), p_minimo: num(minimo), p_motivo: motivo.trim() || null,
    });
    setSalvando(false);
    if (error) return toast(error.message.includes("editar_orcamento") ? "Rode a migração 20261110000014_preco_zonas.sql." : traduzir(error.message), "erro");
    toast("Orçamento refeito. A rota recebe o valor novo.", "ok");
    setEditando(false);
    onSalvo?.();
  }

  if (!editando) {
    return (
      <div className="orcamento-editavel">
        <OrcamentoDetalhe orc={orc} />
        <div className="linha-botoes">
          {orc.editado && <span className="selo" title={orc.motivo ?? undefined}>Editado à mão{orc.motivo ? ` · ${orc.motivo}` : ""}</span>}
          <span className="espaco" />
          {!bloqueado && <button type="button" className="botao-texto" onClick={abrir}><Pencil size={14} aria-hidden /> Mudar o cálculo</button>}
        </div>
      </div>
    );
  }
  return (
    <div className="orcamento-editor">
      <p className="dica" style={{ margin: 0 }}>Mude quantidade e valor unitário (o valor da linha é a conta) ou só o valor final. Linhas “fixas” entram depois dos percentuais.</p>
      {linhas.map((l, i) => (
        <div key={i} className="orc-ed-linha">
          <input className="orc-ed-rotulo" value={l.rotulo} onChange={(e) => mudar(i, { rotulo: e.target.value })} aria-label="Nome da linha" />
          <input inputMode="decimal" placeholder="qtd" value={l.qtd} onChange={(e) => mudar(i, { qtd: e.target.value })} aria-label="Quantidade" />
          <input placeholder="un." value={l.unidade} onChange={(e) => mudar(i, { unidade: e.target.value })} aria-label="Unidade" style={{ width: 64 }} />
          <span className="dica">×</span>
          <input inputMode="decimal" placeholder="R$ un." value={l.unit} onChange={(e) => mudar(i, { unit: e.target.value })} aria-label="Valor unitário" />
          <span className="dica">=</span>
          <input inputMode="decimal" value={l.qtd.trim() !== "" && l.unit.trim() !== "" ? txt(valorDe(l)) : l.valor} disabled={l.qtd.trim() !== "" && l.unit.trim() !== ""}
            onChange={(e) => mudar(i, { valor: e.target.value })} aria-label="Valor da linha" />
          <label className="orc-ed-fixo" title="Entra depois dos percentuais"><input type="checkbox" checked={l.fixo} onChange={(e) => mudar(i, { fixo: e.target.checked })} /> fixo</label>
          <button type="button" className="icone" aria-label="Tirar linha" onClick={() => setLinhas((x) => x.filter((_, k) => k !== i))}><Trash2 size={14} /></button>
        </div>
      ))}
      <button type="button" className="botao-texto" onClick={() => setLinhas((x) => [...x, { rotulo: "Taxa", qtd: "", unit: "", unidade: "", valor: "0", fixo: false }])}><Plus size={14} aria-hidden /> Linha</button>
      <span className="rotulo">Percentuais</span>
      {pcts.map((p, i) => (
        <div key={i} className="orc-ed-linha">
          <input className="orc-ed-rotulo" value={p.rotulo} onChange={(e) => setPcts((x) => x.map((y, k) => (k === i ? { ...y, rotulo: e.target.value } : y)))} aria-label="Nome do percentual" />
          <input inputMode="decimal" value={p.pct} onChange={(e) => setPcts((x) => x.map((y, k) => (k === i ? { ...y, pct: e.target.value } : y)))} aria-label="Percentual" />
          <span className="dica">%</span>
          <button type="button" className="icone" aria-label="Tirar percentual" onClick={() => setPcts((x) => x.filter((_, k) => k !== i))}><Trash2 size={14} /></button>
        </div>
      ))}
      <button type="button" className="botao-texto" onClick={() => setPcts((x) => [...x, { rotulo: "Acréscimo", pct: "0" }])}><Plus size={14} aria-hidden /> Percentual</button>
      <div className="orc-ed-linha"><span className="orc-ed-rotulo">Mínimo</span><input inputMode="decimal" value={minimo} onChange={(e) => setMinimo(e.target.value)} aria-label="Mínimo" /></div>
      <input placeholder="Motivo (aparece no histórico do pedido)" value={motivo} onChange={(e) => setMotivo(e.target.value)} maxLength={200} />
      <div className="orcamento-linha total"><span>Novo total (antes do arredondamento)</span><strong>{moedaBr(previa)}</strong></div>
      <div className="linha-botoes">
        <button type="button" className="botao-texto" onClick={original}><RotateCcw size={14} aria-hidden /> Cálculo original</button>
        <span className="espaco" />
        <button type="button" className="botao-texto" onClick={() => setEditando(false)}><X size={14} aria-hidden /> Cancelar</button>
        <button type="button" className="botao-ouro" disabled={salvando} onClick={salvar}><Save size={15} aria-hidden /> {salvando ? "Salvando…" : "Salvar cálculo"}</button>
      </div>
    </div>
  );
}
