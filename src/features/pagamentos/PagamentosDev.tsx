"use client";

import { useCallback, useEffect, useState } from "react";
import { Building2, CircleCheck, Landmark, Link2, PlugZap, Unplug } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { comSessao } from "./Recebimentos";

type Contas = {
  padrao: "plataforma" | "empresa";
  plataforma: { conectada: boolean; final: string; teste: boolean; nome: string | null; atualizado_em: string } | null;
  empresas: { id: string; nome: string; escolha: "padrao" | "plataforma" | "empresa"; destino: "plataforma" | "empresa"; conectada: boolean; recebido_30d: number }[];
};
const moeda = (v: number) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

/** Dev: para onde vai o dinheiro dos clientes — a conta da plataforma ou a de cada empresa (padrão e exceções). */
export function PagamentosDev() {
  const [c, setC] = useState<Contas | null>(null);
  const [token, setToken] = useState("");
  const [msg, setMsg] = useState<string | null>(null);
  const carregar = useCallback(async () => { const { data } = await supabase().rpc("dev_pag_contas"); setC(data as Contas); }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function destino(org: string | null, d: string) {
    const { data, error } = await supabase().rpc("dev_pag_destino", { p_org: org, p_destino: d });
    if (error) return toast(error.message, "erro");
    setC(data as Contas); toast("Salvo.", "ok");
  }
  async function salvarPlataforma(t: string) {
    const { data, error } = await supabase().rpc("dev_pag_salvar_plataforma", { p_token: t, p_public_key: null, p_nome: null });
    if (error) return toast(error.message.includes("token_invalido") ? "Isso não parece um Access Token (APP_USR-… ou TEST-…)." : error.message, "erro");
    setC(data as Contas); setToken("");
    if (t) { const r = await comSessao("/api/pagamentos/testar", { plataforma: true }); setMsg(r.ok ? `Conectada: ${String(r.nome)}` : String(r.erro)); void carregar(); }
  }
  if (!c) return <p className="dica">Carregando…</p>;
  return (
    <div className="plataforma">
      <section className="bloco recebimentos">
        <h3 className="titulo-bloco"><Landmark size={16} aria-hidden /> Conta da plataforma (sua)</h3>
        <div className="recebimentos-estado">
          {c.plataforma ? <span className="selo" style={{ color: "#22c55e" }}><CircleCheck size={13} aria-hidden /> Ligada · …{c.plataforma.final}{c.plataforma.teste ? " · teste" : ""}</span>
            : <span className="selo"><Unplug size={13} aria-hidden /> Não ligada</span>}
          {c.plataforma?.nome && <span className="dica">{c.plataforma.nome}</span>}
        </div>
        <label className="campo"><span>Access Token de produção do Mercado Pago</span>
          <input type="password" autoComplete="off" spellCheck={false} placeholder={c.plataforma ? "Cole um novo para trocar" : "APP_USR-…"} value={token} onChange={(e) => setToken(e.target.value.trim())} /></label>
        <div className="linha-botoes">
          <button type="button" className="botao-ouro" disabled={!token} onClick={() => void salvarPlataforma(token)}><PlugZap size={15} aria-hidden /> Ligar</button>
          {c.plataforma && <button type="button" className="botao-texto" onClick={async () => { const r = await comSessao("/api/pagamentos/testar", { plataforma: true }); setMsg(r.ok ? `Conectada: ${String(r.nome)}` : String(r.erro)); }}><Link2 size={15} aria-hidden /> Testar</button>}
          {c.plataforma && <button type="button" className="botao-texto" onClick={() => void salvarPlataforma("")}><Unplug size={15} aria-hidden /> Desligar</button>}
        </div>
        {msg && <p className="dica" style={{ margin: 0 }}>{msg}</p>}
      </section>

      <section className="bloco">
        <h3 className="titulo-bloco">Onde cai o dinheiro (padrão)</h3>
        <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }} role="radiogroup">
          <button type="button" className={c.padrao === "empresa" ? "ativo" : ""} onClick={() => void destino(null, "empresa")}><Building2 size={14} aria-hidden /> Na conta de cada empresa</button>
          <button type="button" className={c.padrao === "plataforma" ? "ativo" : ""} onClick={() => void destino(null, "plataforma")}><Landmark size={14} aria-hidden /> Na conta da plataforma</button>
        </div>
        <p className="dica" style={{ margin: 0 }}>Vale para toda empresa marcada como “Padrão” abaixo.</p>
      </section>

      <section className="bloco">
        <h3 className="titulo-bloco">Por empresa</h3>
        <div className="dev-rolagem"><table className="dev-tabela">
          <thead><tr><th>Empresa</th><th>Onde cai</th><th>Conta da empresa</th><th>Recebido 30 dias</th></tr></thead>
          <tbody>{c.empresas.map((e) => (
            <tr key={e.id}><td>{e.nome}</td>
              <td><select value={e.escolha} onChange={(ev) => void destino(e.id, ev.target.value)} aria-label={`Onde cai o dinheiro de ${e.nome}`}>
                <option value="padrao">Padrão ({c.padrao === "empresa" ? "empresa" : "plataforma"})</option>
                <option value="empresa">Conta da empresa</option>
                <option value="plataforma">Conta da plataforma</option>
              </select>{e.destino === "empresa" && !e.conectada && <small className="erro" style={{ display: "block" }}>a empresa ainda não ligou a conta</small>}
                {e.destino === "plataforma" && !c.plataforma && <small className="erro" style={{ display: "block" }}>ligue a conta da plataforma</small>}</td>
              <td>{e.conectada ? "ligada" : "—"}</td><td>{moeda(e.recebido_30d)}</td></tr>
          ))}</tbody>
        </table></div>
      </section>
    </div>
  );
}
