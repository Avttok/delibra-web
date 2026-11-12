"use client";

import { useEffect, useState } from "react";
import { Download, FileSpreadsheet, Mail, Printer, RefreshCw } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { moeda } from "@/features/precos/estrategias";
import { SITUACAO, TIPOS, paraCsv, type Linha, type Tipo } from "./relatorioDados";

const hojeIso = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 10);
const inicioMes = () => hojeIso().slice(0, 8) + "01";

export function Relatorios() {
  const [tipo, setTipo] = useState<Tipo>("rotas");
  const [de, setDe] = useState(inicioMes());
  const [ate, setAte] = useState(hojeIso());
  const [linhas, setLinhas] = useState<Linha[] | null>(null);
  const [email, setEmail] = useState("");
  const [enviando, setEnviando] = useState(false);
  const t = TIPOS.find((x) => x.v === tipo)!;

  async function carregar() {
    setLinhas(null);
    const { data, error } = await supabase().rpc("relatorio", { p_tipo: tipo, p_de: de, p_ate: ate });
    if (error) { setLinhas([]); return toast(error.message.includes("periodo_invalido") ? "Escolha um período de até 400 dias." : error.message, "erro"); }
    setLinhas(((data ?? []) as Linha[]).map((l) => ({ ...l, ...(l["Situação"] != null ? { "Situação": SITUACAO[String(l["Situação"])] ?? l["Situação"] } : {}) })));
  }
  useEffect(() => { void carregar(); }, [tipo, de, ate]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { void supabase().auth.getUser().then(({ data }) => setEmail((e) => e || data.user?.email || "")); }, []);

  const nomeArquivo = `relatorio-${tipo}-${de}-a-${ate}`;
  const totais = t.dinheiro.map((c) => [c, (linhas ?? []).reduce((s, l) => s + Number(l[c] ?? 0), 0)] as const);

  function baixar() {
    const blob = new Blob([paraCsv(t.colunas, linhas ?? [])], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = `${nomeArquivo}.csv`; a.click(); URL.revokeObjectURL(a.href);
  }
  function imprimir() {
    const w = window.open("", "_blank");
    if (!w) return toast("O navegador bloqueou a janela. Libere pop-ups para este site.", "aviso");
    const fmt = (c: string, v: unknown) => (t.dinheiro.includes(c) ? moeda(Number(v ?? 0)) : String(v ?? ""));
    w.document.write(`<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>${nomeArquivo}</title><style>
      body{font:12px system-ui,sans-serif;color:#111;margin:24px} h1{font-size:18px;margin:0 0 4px} p{margin:0 0 14px;color:#555}
      table{border-collapse:collapse;width:100%} th,td{padding:6px 8px;border-bottom:1px solid #ddd;text-align:left} th{background:#f4efe1;font-size:11px}
      tfoot td{font-weight:700;border-top:2px solid #b8901f} @page{margin:14mm}</style></head><body>
      <h1>Relatório de ${t.r.toLowerCase()}</h1><p>${de.split("-").reverse().join("/")} a ${ate.split("-").reverse().join("/")} · ${(linhas ?? []).length} linha(s)</p>
      <table><thead><tr>${t.colunas.map((c) => `<th>${c}</th>`).join("")}</tr></thead><tbody>
      ${(linhas ?? []).map((l) => `<tr>${t.colunas.map((c) => `<td>${fmt(c, l[c]).replace(/</g, "&lt;")}</td>`).join("")}</tr>`).join("")}</tbody>
      ${totais.length ? `<tfoot><tr>${t.colunas.map((c, i) => { const x = totais.find(([k]) => k === c); return `<td>${x ? moeda(x[1]) : i === 0 ? "Total" : ""}</td>`; }).join("")}</tr></tfoot>` : ""}
      </table><script>window.onload=()=>{window.print()}</script></body></html>`);
    w.document.close();
  }
  async function enviar() {
    setEnviando(true);
    const { data: s } = await supabase().auth.getSession();
    const r = await fetch("/api/relatorios/email", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${s.session?.access_token ?? ""}` },
      body: JSON.stringify({ tipo, de, ate, para: email.trim() }) }).then((x) => x.json()).catch(() => ({ erro: "rede" }));
    setEnviando(false);
    if (r.ok) return toast(`Relatório enviado para ${email.trim()}.`, "ok");
    toast(r.erro === "nao_conectado" ? "O envio de e-mail ainda não foi conectado. Por enquanto, baixe o Excel ou o PDF." : r.erro === "email_invalido" ? "Confira o e-mail." : "Não deu para enviar agora.", r.erro === "nao_conectado" ? "aviso" : "erro");
  }

  return (
    <div className="relatorios">
      <div className="relatorios-tipos" role="radiogroup" aria-label="Relatório">
        {TIPOS.map((x) => (
          <button key={x.v} type="button" role="radio" aria-checked={tipo === x.v} className={`relatorio-tipo${tipo === x.v ? " ativo" : ""}`} onClick={() => setTipo(x.v)}>
            <FileSpreadsheet size={18} aria-hidden /><strong>{x.r}</strong><small>{x.dica}</small>
          </button>
        ))}
      </div>
      <div className="relatorios-barra">
        <label className="campo"><span>De</span><input type="date" value={de} max={ate} onChange={(e) => setDe(e.target.value)} /></label>
        <label className="campo"><span>Até</span><input type="date" value={ate} min={de} onChange={(e) => setAte(e.target.value)} /></label>
        <button className="botao-texto" onClick={() => void carregar()}><RefreshCw size={14} aria-hidden /> Atualizar</button>
        <span className="espaco" />
        <button className="botao-ouro" disabled={!linhas?.length} onClick={baixar}><Download size={15} aria-hidden /> Excel</button>
        <button className="botao-texto" disabled={!linhas?.length} onClick={imprimir}><Printer size={15} aria-hidden /> PDF</button>
      </div>
      <div className="relatorios-email">
        <label className="campo" style={{ flex: 1 }}><span>Mandar por e-mail (vai a planilha anexada)</span><input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="voce@empresa.com" /></label>
        <button className="botao-texto" disabled={enviando || !linhas?.length || !email.includes("@")} onClick={enviar}><Mail size={15} aria-hidden /> {enviando ? "Enviando…" : "Enviar"}</button>
      </div>
      {totais.length > 0 && linhas && linhas.length > 0 && (
        <div className="relatorios-totais">{totais.map(([c, v]) => <span key={c}><small>{c}</small><b>{moeda(v)}</b></span>)}<span><small>Linhas</small><b>{linhas.length}</b></span></div>
      )}
      {linhas === null ? <p className="dica">Carregando…</p> : linhas.length === 0 ? <p className="vazio">Nada neste período.</p> : (
        <div className="dev-rolagem"><table className="tabela">
          <thead><tr>{t.colunas.map((c) => <th key={c}>{c}</th>)}</tr></thead>
          <tbody>{linhas.slice(0, 300).map((l, i) => <tr key={i}>{t.colunas.map((c) => <td key={c}>{t.dinheiro.includes(c) ? moeda(Number(l[c] ?? 0)) : String(l[c] ?? "")}</td>)}</tr>)}</tbody>
        </table>{linhas.length > 300 && <p className="dica">Mostrando 300 de {linhas.length}. O Excel e o PDF levam tudo.</p>}</div>
      )}
    </div>
  );
}

