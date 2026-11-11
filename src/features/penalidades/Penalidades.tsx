"use client";

import { useCallback, useEffect, useState } from "react";
import { Ban, Check, Gavel, ShieldOff, Undo2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

type Dados = {
  pontos: number; limite: number; janela_dias: number; suspenso_ate: string | null; motivo: string | null;
  itens: { id: string; tipo: string; pontos: number; motivo: string | null; quando: string; corrida_numero: number | null; perdoada: boolean; vale: boolean }[];
};
const TIPO: Record<string, string> = {
  oferta_ignorada: "Oferta ignorada", oferta_recusada: "Oferta recusada", desistencia: "Desistência", abandono: "Abandono",
  atraso: "Atraso em planejada", manual: "Lançada pelo gestor",
};
const quando = (s: string) => new Date(s).toLocaleString("pt-BR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });

/** Penalidades de um motoboy ou cliente: pontos, suspensão, histórico, lançar, perdoar. */
export function Penalidades({ alvoTipo, alvoId, nome }: { alvoTipo: "motoboy" | "cliente"; alvoId: string; nome: string }) {
  const [d, setD] = useState<Dados | null>(null);
  const [pontos, setPontos] = useState("1");
  const [motivo, setMotivo] = useState("");
  const [abrir, setAbrir] = useState(false);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("penalidades_de", { p_alvo_tipo: alvoTipo, p_alvo: alvoId });
    if (!error) setD(data as Dados);
  }, [alvoTipo, alvoId]);
  useEffect(() => { void carregar(); }, [carregar]);

  async function rodar(f: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    const { error } = await f();
    if (error) return toast(error.message.includes("informe_o_motivo") ? "Escreva o motivo." : error.message.includes("pontos_invalidos") ? "Pontos inválidos." : error.message, "erro");
    toast(ok, "ok"); void carregar();
  }
  if (!d) return null;
  const suspenso = d.suspenso_ate && new Date(d.suspenso_ate) > new Date();
  const pct = d.limite > 0 ? Math.min(100, (Number(d.pontos) / Number(d.limite)) * 100) : 0;
  return (
    <section className="bloco penalidades">
      <h3 className="titulo-bloco"><Gavel size={16} aria-hidden /> Penalidades</h3>
      <div className="penalidades-medidor">
        <strong className="figura">{Number(d.pontos).toLocaleString("pt-BR")}{d.limite > 0 ? <small> / {d.limite} pts</small> : <small> pts</small>}</strong>
        {d.limite > 0 && <span className="barra-pontos" aria-hidden><i style={{ width: `${pct}%` }} /></span>}
        <span className="dica">Contam os últimos {d.janela_dias} dias.{d.limite > 0 ? ` No limite, ${alvoTipo === "motoboy" ? "fica suspenso (sem corridas)" : "fica sem pedidos novos"}.` : ""}</span>
      </div>
      {suspenso && (
        <div className="alerta-pagamento">
          <Ban size={15} aria-hidden /> {alvoTipo === "motoboy" ? "Suspenso" : "Bloqueado"} até {quando(d.suspenso_ate!)}{d.motivo ? ` · ${d.motivo}` : ""}
          <button type="button" className="botao-texto" onClick={() => rodar(() => supabase().rpc("levantar_suspensao", { p_alvo_tipo: alvoTipo, p_alvo: alvoId }), "Suspensão retirada.")}><ShieldOff size={14} aria-hidden /> Tirar agora</button>
        </div>
      )}
      {!abrir ? <button type="button" className="botao-texto" onClick={() => setAbrir(true)}><Gavel size={14} aria-hidden /> Lançar penalidade para {nome}</button> : (
        <div className="grade-2">
          <label className="campo"><span>Pontos</span><input inputMode="decimal" value={pontos} onChange={(e) => setPontos(e.target.value)} /></label>
          <label className="campo"><span>Motivo</span><input value={motivo} maxLength={200} placeholder="Ex.: atrasou a coleta sem avisar" onChange={(e) => setMotivo(e.target.value)} /></label>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" onClick={async () => { await rodar(() => supabase().rpc("penalizar_manual", { p_alvo_tipo: alvoTipo, p_alvo: alvoId, p_pontos: Number(pontos.replace(",", ".")), p_motivo: motivo, p_corrida: null }), "Penalidade lançada."); setMotivo(""); setAbrir(false); }}><Check size={15} aria-hidden /> Lançar</button>
            <button type="button" className="botao-texto" onClick={() => setAbrir(false)}>Cancelar</button>
          </div>
        </div>
      )}
      {d.itens.length === 0 ? <p className="dica" style={{ margin: 0 }}>Nenhuma penalidade.</p> : (
        <div className="lista-simples">{d.itens.map((x) => (
          <div key={x.id} className={`linha-item${x.vale ? "" : " apagado"}`}>
            <span><strong>{TIPO[x.tipo] ?? x.tipo}</strong> · {Number(x.pontos).toLocaleString("pt-BR")} pt{Number(x.pontos) === 1 ? "" : "s"}
              <span className="dica" style={{ display: "block" }}>{quando(x.quando)}{x.corrida_numero ? ` · rota #${x.corrida_numero}` : ""}{x.motivo ? ` · ${x.motivo}` : ""}{x.perdoada ? " · perdoada" : !x.vale ? " · já não conta" : ""}</span></span>
            {x.vale && <button type="button" className="botao-texto" onClick={() => rodar(() => supabase().rpc("perdoar_penalidade", { p_id: x.id }), "Penalidade perdoada.")}><Undo2 size={14} aria-hidden /> Perdoar</button>}
          </div>
        ))}</div>
      )}
    </section>
  );
}
