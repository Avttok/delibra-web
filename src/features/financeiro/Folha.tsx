"use client";

import { Fragment, useCallback, useEffect, useMemo, useState } from "react";
import { Dica } from "@/features/ui/Tour";
import { ChevronLeft, ChevronRight, Copy, Eye, EyeOff, Lock, LockOpen, Plus, Trash2, Wallet, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { useModoTeste } from "@/features/teste/modoTeste";
import { toast } from "@/features/ui/toast";
import { ContaMotoboy } from "@/features/corridas/BlocoRota";
import type { CalculoPagamento } from "@/features/corridas/tipos";
import { moedaBr, quando, traduzir } from "@/features/pedidos/tipos";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { useEtapa } from "@/features/ui/useEtapa";

interface LinhaFolha {
  motoboy_id: string; nome: string; foto_url: string | null; rotas: number; entregas: number; km: number; calculado: number; ajustes_rotas: number; ajustes: number;
  faturado: number; holerite: { status: "aberto" | "fechado" | "pago"; total: number | null; pago_em: string | null } | null;
  chave_pix: { tipo: string; chave: string; titular: string } | null;
}
interface Holerite {
  status: string; rotas: number; entregas: number; km: number; calculado: number; ajustes_rotas: number; total: number; observacoes: string | null;
  ajustes: { id: string; descricao: string; valor: number; criado_em: string; visibilidade?: "tudo" | "valor" | "oculto" }[];
  fixos?: { tipo: string; descricao: string; detalhe?: string; valor?: number }[];
  itens: { id: string; numero: number; concluida_em: string; entregas: number; km: number; clientes: string | null; calculo: CalculoPagamento | null; ajuste: number; ajuste_motivo: string | null; valor: number; faturado: number }[];
}
type Periodo = "diario" | "semanal" | "quinzenal" | "mensal";

const iso = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const dataBr = (s: string) => new Date(`${s}T12:00:00`).toLocaleDateString("pt-BR", { day: "2-digit", month: "short" });

/** Período (mesma regra do banco) que contém `ref`, deslocado `passo` períodos. */
function periodo(tipo: Periodo, inicioSemana: number, ref: Date, passo: number): [string, string] {
  const d = new Date(ref.getFullYear(), ref.getMonth(), ref.getDate());
  if (tipo === "diario") { d.setDate(d.getDate() + passo); return [iso(d), iso(d)]; }
  if (tipo === "mensal") { const i = new Date(d.getFullYear(), d.getMonth() + passo, 1); return [iso(i), iso(new Date(i.getFullYear(), i.getMonth() + 1, 0))]; }
  if (tipo === "quinzenal") {
    let q = (d.getMonth() + d.getFullYear() * 12) * 2 + (d.getDate() > 15 ? 1 : 0) + passo;
    const mes = Math.floor(q / 2); q %= 2;
    const i = new Date(Math.floor(mes / 12), mes % 12, q ? 16 : 1);
    return [iso(i), iso(q ? new Date(i.getFullYear(), i.getMonth() + 1, 0) : new Date(i.getFullYear(), i.getMonth(), 15))];
  }
  const isoDow = d.getDay() === 0 ? 7 : d.getDay();
  d.setDate(d.getDate() - ((isoDow - inicioSemana + 7) % 7) + passo * 7);
  const f = new Date(d); f.setDate(f.getDate() + 6);
  return [iso(d), iso(f)];
}

const ROT_VIS: Record<string, string> = { tudo: "tudo", valor: "só o valor", oculto: "nada" };
const PROX_VIS: Record<string, string> = { tudo: "valor", valor: "oculto", oculto: "tudo" };

/** Folha de pagamento dos motoboys: período, rotas, cálculo, ajustes, fechar e pagar. */
export function Folha() {
  const { teste } = useModoTeste();
  const cfg = useConfiguracoes();
  const [tipo, setTipo] = useState<Periodo>("semanal");
  const [passo, setPasso] = useState(0);
  const [linhas, setLinhas] = useState<LinhaFolha[] | null>(null);
  const [sel, setSel] = useState<string | null>(null);
  useEffect(() => { if (typeof cfg.holerite_periodo === "string") setTipo(cfg.holerite_periodo as Periodo); }, [cfg.holerite_periodo]);
  const [ini, fim] = useMemo(() => periodo(tipo, Number(cfg.holerite_inicio_semana) || 1, new Date(), passo), [tipo, passo, cfg.holerite_inicio_semana]);

  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("folha", { p_inicio: ini, p_fim: fim, p_teste: teste });
    if (error) return toast(traduzir(error.message), "erro");
    setLinhas((data ?? []) as LinhaFolha[]);
  }, [ini, fim, teste]);
  useEffect(() => { setLinhas(null); void carregar(); }, [carregar]);

  const total = (l: LinhaFolha) => l.holerite?.status !== "aberto" && l.holerite?.total != null ? Number(l.holerite.total) : Number(l.calculado) + Number(l.ajustes_rotas) + Number(l.ajustes);
  const soma = (linhas ?? []).reduce((s, l) => s + total(l), 0);
  const faturado = (linhas ?? []).reduce((s, l) => s + Number(l.faturado), 0);
  const atual = linhas?.find((l) => l.motoboy_id === sel);

  return (
    <div className="folha">
      <div className="folha-topo">
        <div className="segmentado segmentado-rolavel" style={{ maxWidth: 460 }}>
          {(["diario", "semanal", "quinzenal", "mensal"] as Periodo[]).map((p) => (
            <button key={p} type="button" className={tipo === p ? "ativo" : ""} onClick={() => { setTipo(p); setPasso(0); }}>{{ diario: "Dia", semanal: "Semana", quinzenal: "Quinzena", mensal: "Mês" }[p]}</button>
          ))}
        </div>
        <div className="folha-periodo">
          <button className="icone" aria-label="Período anterior" onClick={() => setPasso((p) => p - 1)}><ChevronLeft size={16} /></button>
          <strong>{ini === fim ? dataBr(ini) : `${dataBr(ini)} – ${dataBr(fim)}`}</strong>
          <button className="icone" aria-label="Próximo período" disabled={passo >= 0} onClick={() => setPasso((p) => Math.min(0, p + 1))}><ChevronRight size={16} /></button>
        </div>
      </div>
      <div className="dev-grade">
        <div className="dev-num"><strong>{moedaBr(soma)}</strong><span>Folha do período</span></div>
        <div className="dev-num"><strong>{moedaBr(faturado)}</strong><span>Faturado nessas rotas</span></div>
        <div className="dev-num"><strong>{faturado ? `${(Math.round((soma / faturado) * 1000) / 10).toLocaleString("pt-BR")}%` : "—"}</strong><span>Folha ÷ faturado</span></div>
      </div>
      <div className="dev-rolagem">
        <table className="tabela tabela-clicavel">
          <thead><tr><th>Motoboy</th><th>Rotas</th><th>Entregas</th><th>Km</th><th>Calculado</th><th>Ajustes</th><th>Total</th><th>Situação</th><th>PIX</th></tr></thead>
          <tbody>{(linhas ?? []).filter((l) => l.rotas > 0 || l.holerite).map((l) => (
            <tr key={l.motoboy_id} className={sel === l.motoboy_id ? "ativo" : ""} onClick={() => setSel(sel === l.motoboy_id ? null : l.motoboy_id)}>
              <td><strong>{l.nome}</strong></td><td>{l.rotas}</td><td>{l.entregas}</td><td>{Number(l.km).toLocaleString("pt-BR")}</td>
              <td>{moedaBr(l.calculado)}</td><td>{moedaBr(Number(l.ajustes_rotas) + Number(l.ajustes))}</td><td><strong>{moedaBr(total(l))}</strong></td>
              <td><span className="selo" style={{ color: l.holerite?.status === "pago" ? "#2ecc71" : l.holerite?.status === "fechado" ? "#60a5fa" : "var(--texto-2)" }}>{l.holerite?.status === "pago" ? "Pago" : l.holerite?.status === "fechado" ? "Fechado" : "Aberto"}</span></td>
              <td className="celula-pix" onClick={(e) => e.stopPropagation()}>{l.chave_pix ? <button className="link" title={l.chave_pix.titular} onClick={() => { navigator.clipboard?.writeText(l.chave_pix!.chave); toast("Chave PIX copiada.", "ok"); }}><Copy size={12} aria-hidden /> {l.chave_pix.chave}</button> : <span className="dica">sem chave</span>}</td>
            </tr>
          ))}</tbody>
        </table>
        {linhas && !linhas.some((l) => l.rotas > 0 || l.holerite) && <p className="vazio">Nenhuma rota concluída neste período.</p>}
      </div>
      {atual && <DetalheHolerite key={`${atual.motoboy_id}-${ini}`} l={atual} ini={ini} fim={fim} teste={teste} onMudou={carregar} onFechar={() => setSel(null)} />}
    </div>
  );
}

function DetalheHolerite({ l, ini, fim, teste, onMudou, onFechar }: { l: LinhaFolha; ini: string; fim: string; teste: boolean; onMudou: () => void; onFechar: () => void }) {
  const [h, setH] = useState<Holerite | null>(null);
  const [aberto, setAberto] = useEtapa<string | null>("folha-aberto", null);
  const [desc, setDesc] = useState("");
  const [vis, setVis] = useState("tudo");
  const [valor, setValor] = useState("");
  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("holerite", { p_motoboy: l.motoboy_id, p_inicio: ini, p_fim: fim, p_teste: teste });
    setH(data as Holerite);
  }, [l.motoboy_id, ini, fim, teste]);
  useEffect(() => { void carregar(); }, [carregar]);
  const fechado = h?.status !== "aberto";

  async function rpc(f: string, args: Record<string, unknown>, ok: string) {
    const { error } = await supabase().rpc(f, args);
    if (error) return toast(traduzir(error.message), "erro");
    toast(ok, "ok"); void carregar(); onMudou();
  }
  async function ajustarRota(id: string, atual: number) {
    const v = prompt("Ajuste desta rota (use − para descontar):", String(atual).replace(".", ","));
    if (v === null) return;
    const motivo = prompt("Motivo do ajuste:") ?? "";
    await rpc("ajustar_pagamento_rota", { p_corrida: id, p_ajuste: Number(v.replace(",", ".")) || 0, p_motivo: motivo }, "Rota ajustada.");
  }
  if (!h) return <div className="catalogo-form vidro"><p className="dica">Carregando holerite…</p></div>;
  return (
    <div className="catalogo-form vidro holerite">
      <div className="titulo-linha">
        <h3 className="display" style={{ margin: 0 }}><Wallet size={18} aria-hidden /> Holerite · {l.nome}</h3>
        <span className="dica">{dataBr(ini)} – {dataBr(fim)}</span>
        <button className="icone" aria-label="Fechar" onClick={onFechar}><X size={16} /></button>
      </div>
      <div className="dev-grade">
        <div className="dev-num"><strong>{h.rotas}</strong><span>Rotas</span></div>
        <div className="dev-num"><strong>{h.entregas}</strong><span>Entregas</span></div>
        <div className="dev-num"><strong>{Number(h.km).toLocaleString("pt-BR")} km</strong><span>Rodados</span></div>
        <div className="dev-num"><strong className="texto-grad">{moedaBr(h.total)}</strong><span>Total</span></div>
      </div>
      <div className="dev-rolagem">
        <table className="tabela">
          <thead><tr><th>Rota</th><th>Quando</th><th>Clientes</th><th>Entregas</th><th>Km</th><th>Calculado</th><th>Ajuste</th><th>Total</th></tr></thead>
          <tbody>{h.itens.map((it) => (
            <Fragment key={it.id}>
              <tr className="tabela-clicavel" onClick={() => setAberto(aberto === it.id ? null : it.id)}>
                <td>#{it.numero}</td><td>{quando(it.concluida_em)}</td><td>{it.clientes ?? "—"}</td><td>{it.entregas}</td><td>{Number(it.km).toLocaleString("pt-BR")}</td>
                <td>{moedaBr(it.calculo?.total)}</td>
                <td>{fechado ? moedaBr(it.ajuste) : <button className="link" onClick={(e) => { e.stopPropagation(); void ajustarRota(it.id, it.ajuste); }} title={it.ajuste_motivo ?? undefined}>{moedaBr(it.ajuste)}</button>}</td>
                <td><strong>{moedaBr(it.valor)}</strong></td>
              </tr>
              {aberto === it.id && it.calculo && <tr><td colSpan={8}><ContaMotoboy calc={it.calculo} />{it.ajuste_motivo && <p className="dica">Ajuste: {it.ajuste_motivo}</p>}</td></tr>}
            </Fragment>
          ))}</tbody>
        </table>
      </div>
      {(h.fixos?.length ?? 0) > 0 && (<>
        <span className="rotulo">Salário, diárias e horas<Dica titulo="Pagamento do período" texto="Vem do modelo de pagamento do motoboy (Regras dele): salário fixo, diária, hora em corrida e mínimo garantido. Já está somado no total." /></span>
        <div className="lista-simples">{h.fixos!.map((f, i) => (
          <div key={i} className="linha-item"><span>{f.descricao}{f.detalhe ? <span className="dica"> · {f.detalhe}</span> : null}</span><strong>{moedaBr(f.valor)}</strong></div>
        ))}</div>
      </>)}
      <span className="rotulo">Ajustes do período<Dica titulo="Ajustes" texto="Bônus (valor positivo) ou desconto (com −). Em cada ajuste você escolhe o que o motoboy vê: tudo, só o valor (aparece como “Ajuste”) ou nada (não aparece para ele nem no total dele)." /></span>
      {h.ajustes.length === 0 && <p className="dica" style={{ margin: 0 }}>Nenhum (bônus, vale, desconto…).</p>}
      {h.ajustes.map((a) => (
        <div key={a.id} className="orcamento-linha"><span>{a.descricao}
          <button type="button" className="selo selo-vis" disabled={fechado} title="Toque para mudar o que o motoboy vê"
            onClick={() => rpc("ajuste_holerite_visibilidade", { p_id: a.id, p_visibilidade: PROX_VIS[a.visibilidade ?? "tudo"] }, "Visibilidade mudada.")}>
            {a.visibilidade === "oculto" ? <EyeOff size={11} aria-hidden /> : <Eye size={11} aria-hidden />} Motoboy vê: {ROT_VIS[a.visibilidade ?? "tudo"]}</button></span><strong>{moedaBr(a.valor)}</strong>
          {!fechado && <button className="icone" aria-label="Remover ajuste" onClick={() => rpc("remover_ajuste_holerite", { p_ajuste: a.id }, "Ajuste removido.")}><Trash2 size={13} /></button>}</div>
      ))}
      {!fechado && (
        <div className="pedido-valor">
          <label className="campo" style={{ flex: 2 }}><span>Descrição</span><input placeholder="Ex.: bônus, vale, desconto de avaria" value={desc} onChange={(e) => setDesc(e.target.value)} /></label>
          <label className="campo"><span>Valor (+/−)</span><span className="passo-campo"><span className="unidade">R$</span><input inputMode="decimal" value={valor} onChange={(e) => setValor(e.target.value)} /></span></label>
          <label className="campo"><span>O motoboy vê</span><select value={vis} onChange={(e) => setVis(e.target.value)}>
            <option value="tudo">Tudo (descrição e valor)</option><option value="valor">Só o valor</option><option value="oculto">Nada</option></select></label>
          <button className="botao-texto" disabled={!desc.trim() || !valor} onClick={async () => { await rpc("ajuste_holerite", { p_motoboy: l.motoboy_id, p_inicio: ini, p_fim: fim, p_descricao: desc, p_valor: Number(valor.replace(/[−–]/g, "-").replace(/R\$|\s/g, "").replace(",", ".")), p_teste: teste, p_visibilidade: vis }, "Ajuste lançado."); setDesc(""); setValor(""); }}><Plus size={14} aria-hidden /> Lançar</button>
        </div>
      )}
      <div className="linha-botoes">
        {h.status === "aberto" && <button className="botao-ouro" onClick={() => rpc("situacao_holerite", { p_motoboy: l.motoboy_id, p_inicio: ini, p_fim: fim, p_acao: "fechar", p_teste: teste }, "Holerite fechado.")}><Lock size={15} aria-hidden /> Fechar holerite</button>}
        {h.status === "fechado" && <button className="botao-ouro" onClick={() => rpc("situacao_holerite", { p_motoboy: l.motoboy_id, p_inicio: ini, p_fim: fim, p_acao: "pago", p_teste: teste }, "Marcado como pago.")}>Marcar como pago</button>}
        {h.status !== "aberto" && <button className="botao-texto" onClick={() => rpc("situacao_holerite", { p_motoboy: l.motoboy_id, p_inicio: ini, p_fim: fim, p_acao: "reabrir", p_teste: teste }, "Holerite reaberto.")}><LockOpen size={15} aria-hidden /> Reabrir</button>}
        {l.chave_pix && <span className="dica">PIX: {l.chave_pix.chave} · {l.chave_pix.titular}</span>}
      </div>
    </div>
  );
}
