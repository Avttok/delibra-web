"use client";

import { useEffect, useMemo, useState } from "react";
import { ArrowDownLeft, ArrowUpRight, Bike, Copy, Download, Landmark, Search, TrendingUp, Wallet } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { moeda } from "@/features/precos/estrategias";
import { useEmpresas, useEquipe } from "@/features/corridas/dados";
import { useModoTeste } from "@/features/teste/modoTeste";
import { toast } from "@/features/ui/toast";
import { useConta } from "@/features/conta/conta";
import { ChavesEquipe, MinhasChavesPix, useChavesPix } from "./ChavesPix";
import { formatarPix } from "@/lib/pix/identificar";
import { Faturas } from "./Faturas";
import { Relatorios } from "./Relatorios";
import { Folha } from "./Folha";

type Periodo = "hoje" | "7d" | "mes" | "30d" | "90d";
const ROTULO: Record<Periodo, string> = { hoje: "Hoje", "7d": "7 dias", mes: "Este mês", "30d": "30 dias", "90d": "90 dias" };
type Aba = "resumo" | "faturas" | "folha" | "clientes" | "extrato" | "relatorios" | "pix";

interface Linha {
  id: string; numero: number; teste: boolean; valor: number | null; valor_motoboy: number | null; valor_gestao: number | null; valor_dev: number | null;
  repasse_pct: number | null; dev_pct: number | null; motoboy_id: string | null; empresa_id: string | null; cliente_nome: string | null;
  concluida_em: string; distancia_real_m: number | null; distancia_planejada_m: number | null; pagamento_status: string | null; pagamento_metodo: string | null;
}

function inicio(p: Periodo) {
  const d = new Date();
  if (p === "hoje") d.setHours(0, 0, 0, 0);
  else if (p === "mes") { d.setDate(1); d.setHours(0, 0, 0, 0); }
  else d.setDate(d.getDate() - (p === "7d" ? 7 : p === "30d" ? 30 : 90));
  return d.toISOString();
}

/** Carteira da gestão: o que entrou, quanto é de cada parte (motoboy e gestão), extrato e chaves PIX. */
export function PainelFinanceiro() {
  const [periodo, setPeriodo] = useState<Periodo>("mes");
  const [aba, setAba] = useState<Aba>("resumo");
  const [linhas, setLinhas] = useState<Linha[]>([]);
  const { chaves, recarregar: recarregarChaves } = useChavesPix();
  const conta = useConta();
  const [busca, setBusca] = useState("");
  const equipe = useEquipe();
  const { empresas } = useEmpresas();
  const { teste } = useModoTeste();

  // o que está pendente (não depende do período): faturas emitidas e não pagas, folhas fechadas e não pagas
  const [pendente, setPendente] = useState<{ receber: number; nFat: number; pagar: number; nHol: number; aberto: number }>({ receber: 0, nFat: 0, pagar: 0, nHol: 0, aberto: 0 });
  useEffect(() => {
    const sb = supabase();
    Promise.all([
      sb.from("faturas").select("total").eq("teste", teste).eq("status", "emitida"),
      sb.from("holerites").select("total,status").eq("teste", teste).in("status", ["fechado", "aberto"]),
    ]).then(([f, h]) => {
      const fat = (f.data ?? []) as { total: number | null }[];
      const hol = (h.data ?? []) as { total: number | null; status: string }[];
      setPendente({
        receber: fat.reduce((s, x) => s + Number(x.total ?? 0), 0), nFat: fat.length,
        pagar: hol.filter((x) => x.status === "fechado").reduce((s, x) => s + Number(x.total ?? 0), 0), nHol: hol.filter((x) => x.status === "fechado").length,
        aberto: hol.filter((x) => x.status === "aberto").reduce((s, x) => s + Number(x.total ?? 0), 0),
      });
    });
  }, [teste]);

  useEffect(() => {
    supabase().from("corridas").select("*")
      .eq("status", "concluida").eq("teste", teste).gte("concluida_em", inicio(periodo)).order("concluida_em", { ascending: false }).limit(3000)
      .then(({ data }) => setLinhas((data ?? []) as Linha[]));
  }, [periodo, teste]);

  const soma = (f: (l: Linha) => number | null, ls = linhas) => ls.reduce((s, l) => s + Number(f(l) ?? 0), 0);
  // cada rota se divide em duas partes que somam o valor dela: motoboy + gestor
  const total = soma((l) => l.valor), motoboys = soma((l) => l.valor_motoboy);
  const gestor = total - motoboys;
  const pct = (v: number) => (total ? `${(Math.round((v / total) * 1000) / 10).toLocaleString("pt-BR")}%` : "0%");
  const km = soma((l) => l.distancia_real_m ?? l.distancia_planejada_m) / 1000;

  const agrupar = (chave: (l: Linha) => string | null) => {
    const m = new Map<string, { n: number; valor: number; motoboy: number; gestao: number; dev: number }>();
    for (const l of linhas) {
      const k = chave(l) ?? "—";
      const a = m.get(k) ?? { n: 0, valor: 0, motoboy: 0, gestao: 0, dev: 0 };
      a.n++; a.valor += Number(l.valor ?? 0); a.motoboy += Number(l.valor_motoboy ?? 0); a.gestao += Number(l.valor_gestao ?? 0); a.dev += Number(l.valor_dev ?? 0);
      m.set(k, a);
    }
    return [...m.entries()].sort((a, b) => b[1].valor - a[1].valor);
  };
  const porMotoboy = useMemo(() => agrupar((l) => l.motoboy_id), [linhas]); // eslint-disable-line react-hooks/exhaustive-deps
  const porCliente = useMemo(() => agrupar((l) => l.empresa_id ?? (l.cliente_nome ? `avulso:${l.cliente_nome}` : null)), [linhas]); // eslint-disable-line react-hooks/exhaustive-deps
  const nomeM = (id: string | null) => equipe.find((m) => m.id === id)?.nome ?? "—";
  const nomeC = (id: string) => (id === "—" ? "Avulso (sem nome)" : id.startsWith("avulso:") ? `${id.slice(7)} (avulso)` : empresas.find((e) => e.id === id)?.nome ?? "—");
  const clienteDe = (l: Linha) => nomeC(l.empresa_id ?? (l.cliente_nome ? `avulso:${l.cliente_nome}` : "—"));
  const termo = busca.trim().toLowerCase();
  const extrato = linhas.filter((l) => !termo || `${l.numero} ${nomeM(l.motoboy_id)} ${clienteDe(l)}`.toLowerCase().includes(termo));

  function exportar() {
    const cab = ["Rota", "Concluída em", "Cliente", "Motoboy", "Valor", "Motoboy %", "Motoboy R$", "Gestor R$", ...(conta.dev ? ["Plataforma %", "Plataforma R$"] : []), "Km", "Pagamento"];
    const linhasCsv = extrato.map((l) => [
      `${l.teste ? "T" : "#"}${l.numero}`, new Date(l.concluida_em).toLocaleString("pt-BR"), clienteDe(l), nomeM(l.motoboy_id),
      l.valor, l.repasse_pct, l.valor_motoboy, Number(l.valor ?? 0) - Number(l.valor_motoboy ?? 0), ...(conta.dev ? [l.dev_pct, l.valor_dev] : []),
      ((l.distancia_real_m ?? l.distancia_planejada_m ?? 0) / 1000).toFixed(1), l.pagamento_metodo ?? l.pagamento_status ?? "",
    ].map((v) => `"${String(v ?? "").replace(".", ",").replace(/"/g, '""')}"`).join(";"));
    const blob = new Blob(["﻿" + [cab.join(";"), ...linhasCsv].join("\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = `delibra-carteira-${periodo}${teste ? "-teste" : ""}.csv`;
    a.click();
  }
  const copiar = (t: string) => { navigator.clipboard?.writeText(t); toast("Chave PIX copiada.", "ok"); };

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={Wallet} titulo="Carteira" subtitulo={teste ? "Números das rotas de teste" : "Rotas concluídas no período"} />
        <div className="filtro filtro-rolavel">
          {(Object.keys(ROTULO) as Periodo[]).map((p) => (
            <button key={p} className={periodo === p ? "ativo" : ""} onClick={() => setPeriodo(p)}>{ROTULO[p]}</button>
          ))}
        </div>
        <div className="bloco carteira-total">
          <span className="rotulo"><TrendingUp size={12} /> Valor das rotas concluídas</span>
          <strong className="figura texto-grad" style={{ fontSize: 30 }}>{moeda(total)}</strong>
          <span className="dica">{linhas.length} rota{linhas.length === 1 ? "" : "s"} · {km.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km{linhas.length ? ` · média ${moeda(total / linhas.length)}` : ""}</span>
        </div>
        <div className="carteira-divisao" aria-label="Para onde vai o valor">
          <span className="rotulo">Para onde vai esse valor</span>
          <div className="barra-divisao" aria-hidden>
            <span style={{ flex: motoboys || 0.0001, background: "var(--texto-2)" }} />
            <span style={{ flex: Math.max(gestor, 0) || 0.0001, background: "var(--ouro)" }} />
          </div>
          <div className="carteira-parte"><i style={{ background: "var(--texto-2)" }} /><Bike size={14} aria-hidden /><span>Motoboys</span><strong>{moeda(motoboys)}</strong><small>{pct(motoboys)}</small></div>
          <div className="carteira-parte"><i style={{ background: "var(--ouro)" }} /><Landmark size={14} aria-hidden /><span>Gestor</span><strong>{moeda(gestor)}</strong><small>{pct(gestor)}</small></div>
          <p className="dica" style={{ margin: 0 }}>As duas partes somam o valor das rotas. A divisão de cada rota segue Configurações → Motoboys.</p>
        </div>
        <div className="grade-2 grade-igual">
          <button type="button" className="bloco carteira-pendente" onClick={() => setAba("faturas")}>
            <span className="rotulo"><ArrowDownLeft size={12} /> A receber</span><strong className="figura" style={{ fontSize: 20 }}>{moeda(pendente.receber)}</strong>
            <span className="dica">{pendente.nFat} fatura{pendente.nFat === 1 ? "" : "s"} emitida{pendente.nFat === 1 ? "" : "s"}</span>
          </button>
          <button type="button" className="bloco carteira-pendente" onClick={() => setAba("folha")}>
            <span className="rotulo"><ArrowUpRight size={12} /> A pagar</span><strong className="figura" style={{ fontSize: 20 }}>{moeda(pendente.pagar)}</strong>
            <span className="dica">{pendente.nHol} folha{pendente.nHol === 1 ? "" : "s"} fechada{pendente.nHol === 1 ? "" : "s"}{pendente.aberto ? ` · ${moeda(pendente.aberto)} em aberto` : ""}</span>
          </button>
        </div>
        <p className="dica">A receber e a pagar valem para todo o tempo (não dependem do período). Os recebimentos automáticos entram quando a intermediadora de pagamento for ligada.</p>
      </aside>
      <main className="conteudo">
        <div className="formulario larga vidro entrar">
          <div className="segmentado segmentado-rolavel">
            {([["resumo", "Resumo"], ["faturas", "Faturas"], ["folha", "Folha"], ["clientes", "Clientes"], ["extrato", "Extrato"], ["relatorios", "Relatórios"], ["pix", "PIX"]] as [Aba, string][]).map(([k, r]) => (
              <button key={k} type="button" className={aba === k ? "ativo" : ""} onClick={() => setAba(k)}>{r}</button>
            ))}
          </div>

          {aba === "resumo" && (
            <>
              <h3 className="display" style={{ margin: 0 }}>Por motoboy</h3>
              <p className="dica" style={{ margin: 0 }}>Quanto cada um recebeu das rotas que fez no período, e o valor dessas rotas.</p>
              <div className="dev-rolagem"><table className="tabela"><thead><tr><th>Motoboy</th><th>Rotas</th><th>Recebe</th><th>Valor das rotas</th><th>Chave PIX</th></tr></thead>
                <tbody>{porMotoboy.map(([id, a]) => {
                  const ch = chaves.find((c) => c.usuario_id === id && c.principal);
                  return (
                    <tr key={id}><td>{nomeM(id)}</td><td>{a.n}</td><td>{moeda(a.motoboy)}</td><td>{moeda(a.valor)}</td>
                      <td>{ch ? <button className="botao-texto celula-pix" onClick={() => copiar(ch.chave)} title={`${ch.titular} · ${ch.tipo_chave}`}><Copy size={13} aria-hidden /> {formatarPix(ch.chave, ch.tipo_chave)}</button> : <span className="dica">não cadastrada</span>}</td></tr>
                  );
                })}</tbody></table></div>
            </>
          )}

          {aba === "faturas" && <Faturas />}
          {aba === "folha" && <Folha />}
          {aba === "relatorios" && <Relatorios />}

          {aba === "clientes" && (
            <div className="dev-rolagem"><table className="tabela"><thead><tr><th>Cliente</th><th>Rotas</th><th>Valor</th><th>Motoboys</th><th>Gestor</th></tr></thead>
              <tbody>{porCliente.map(([id, a]) => <tr key={id}><td>{nomeC(id)}</td><td>{a.n}</td><td>{moeda(a.valor)}</td><td>{moeda(a.motoboy)}</td><td>{moeda(a.valor - a.motoboy)}</td></tr>)}</tbody></table></div>
          )}

          {aba === "extrato" && (
            <>
              <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
                <label className="busca-mini" style={{ flex: 1 }}><Search size={14} aria-hidden /><input placeholder="Buscar por número, motoboy ou cliente" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
                <button className="botao-texto" onClick={exportar} disabled={!extrato.length}><Download size={15} aria-hidden /> Planilha</button>
              </div>
              <div className="dev-rolagem">
                <table className="tabela"><thead><tr><th>Rota</th><th>Quando</th><th>Cliente</th><th>Motoboy</th><th>Valor</th><th>Motoboy recebe</th><th>Gestor</th></tr></thead>
                  <tbody>{extrato.map((l) => (
                    <tr key={l.id}><td>{l.teste ? "T" : "#"}{l.numero}</td><td>{new Date(l.concluida_em).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}</td>
                      <td>{clienteDe(l)}</td><td>{nomeM(l.motoboy_id)}</td><td>{moeda(Number(l.valor ?? 0))}</td>
                      <td>{moeda(Number(l.valor_motoboy ?? 0))}</td><td>{moeda(Number(l.valor ?? 0) - Number(l.valor_motoboy ?? 0))}</td></tr>
                  ))}</tbody></table>
              </div>
            </>
          )}
          {aba === "pix" && (
            <>
              <MinhasChavesPix chaves={chaves} onMudou={recarregarChaves} meuNome={equipe.find((m) => m.id === conta.id)?.nome} />
              <h3 className="display" style={{ margin: "6px 0 0" }}>Chaves da equipe</h3>
              <p className="dica" style={{ margin: 0 }}>A estrela marca a principal: é para ela que vai o repasse. Toque para copiar.</p>
              <ChavesEquipe chaves={chaves} nome={nomeM} />
            </>
          )}
          {["resumo", "clientes", "extrato"].includes(aba) && linhas.length === 0 && <p className="vazio">Nenhuma rota concluída neste período.</p>}
        </div>
      </main>
    </>
  );
}
