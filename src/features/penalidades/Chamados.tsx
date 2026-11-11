"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Check, Hand, UserX, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

export type Chamado = {
  id: string; corrida_id: string; motoboy_id: string; motivo: string; status: "pendente" | "aprovado" | "negado" | "retirado" | "expirado";
  resposta: string | null; criado_em: string; corrida_numero: number; corrida_teste: boolean; motoboy_nome: string; feitas: number; paradas: number; abandono: boolean;
};
const ERRO: Record<string, string> = { chamado_ja_respondido: "Este pedido já foi respondido.", rota_sem_motoboy: "A rota já não está com o motoboy." };
const traduz = (m: string) => Object.entries(ERRO).find(([k]) => m.includes(k))?.[1] ?? m;

/** Responder um pedido de cancelamento (aprovar/negar) e, depois de negado, marcar abandono. */
export function RespostaChamado({ c, onMudou }: { c: Chamado; onMudou: () => void }) {
  const [resposta, setResposta] = useState("");
  const [penalizar, setPenalizar] = useState(true);
  const [ocupado, setOcupado] = useState(false);
  async function rodar(f: () => PromiseLike<{ error: { message: string } | null }>, ok: string) {
    setOcupado(true);
    const { error } = await f();
    setOcupado(false);
    if (error) return toast(traduz(error.message), "erro");
    toast(ok, "ok"); onMudou();
  }
  const sb = supabase();
  return (
    <div className={`chamado chamado-${c.status}`}>
      <div className="chamado-cabeca">
        <Hand size={16} aria-hidden />
        <strong>{c.motoboy_nome} {c.status === "pendente" ? "pediu para cancelar" : c.status === "aprovado" || c.status === "expirado" ? "teve o cancelamento aprovado" : c.status === "negado" ? "teve o cancelamento negado" : "retirou o pedido"}</strong>
        <span className="dica">rota {c.corrida_teste ? "T" : "#"}{c.corrida_numero} · {c.feitas}/{c.paradas} paradas feitas</span>
      </div>
      <p className="chamado-motivo">“{c.motivo}”</p>
      {c.resposta && <p className="dica" style={{ margin: 0 }}>Resposta: {c.resposta}</p>}
      {c.status === "pendente" && <>
        <label className="campo"><span>Resposta para o motoboy (opcional)</span><input value={resposta} maxLength={200} onChange={(e) => setResposta(e.target.value)} placeholder="Ex.: Ok, outro motoboy vai pegar" /></label>
        <label className="opcao"><span>Contar como desistência (penalidade)</span><input type="checkbox" role="switch" checked={penalizar} onChange={(e) => setPenalizar(e.target.checked)} /></label>
        <div className="linha-botoes">
          <button type="button" className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => sb.rpc("responder_chamado", { p_chamado: c.id, p_aprovar: true, p_resposta: resposta || null, p_penalizar: penalizar }), "Aprovado: a rota saiu dele e voltou para o sistema.")}><Check size={15} aria-hidden /> Aprovar</button>
          <button type="button" className="botao-texto" disabled={ocupado} onClick={() => rodar(() => sb.rpc("responder_chamado", { p_chamado: c.id, p_aprovar: false, p_resposta: resposta || null, p_penalizar: false }), "Negado: a rota continua com ele.")}><X size={15} aria-hidden /> Negar</button>
        </div>
      </>}
      {c.status === "negado" && !c.abandono && (
        <div className="linha-botoes">
          <button type="button" className="botao-perigo" disabled={ocupado} onClick={() => rodar(() => sb.rpc("marcar_abandono", { p_corrida: c.corrida_id, p_motivo: "Abandonou depois de o cancelamento ser negado" }), "Rota tirada dele e penalidade de abandono lançada.")}>
            <UserX size={15} aria-hidden /> Ele abandonou: tirar a rota e penalizar</button>
        </div>
      )}
    </div>
  );
}

/** Faixa no topo do painel do gestor com os pedidos de cancelamento esperando resposta. */
export function ChamadosPendentes() {
  const [lista, setLista] = useState<Chamado[]>([]);
  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("chamados_abertos");
    setLista(((data as Chamado[] | null) ?? []).filter((c) => c.status === "pendente"));
  }, []);
  useEffect(() => { void carregar(); const t = setInterval(carregar, 20_000); return () => clearInterval(t); }, [carregar]);
  if (!lista.length) return null;
  return (
    <div className="chamados-faixa" role="status">
      <Hand size={16} aria-hidden />
      <span>{lista.length === 1 ? `${lista[0].motoboy_nome} pediu para cancelar a rota ${lista[0].corrida_teste ? "T" : "#"}${lista[0].corrida_numero}` : `${lista.length} pedidos de cancelamento esperando você`}</span>
      <Link className="botao-ouro" href={`/gestor/corridas?c=${lista[0].corrida_id}`}>Responder</Link>
    </div>
  );
}

/** No detalhe da rota: o pedido de cancelamento dela (se houver) e o "abandonou". */
export function ChamadosDaCorrida({ corridaId, comMotoboy }: { corridaId: string; comMotoboy: boolean }) {
  const [lista, setLista] = useState<Chamado[]>([]);
  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("chamados_abertos");
    setLista(((data as Chamado[] | null) ?? []).filter((c) => c.corrida_id === corridaId));
  }, [corridaId]);
  useEffect(() => { void carregar(); const t = setInterval(carregar, 15_000); return () => clearInterval(t); }, [carregar]);
  const temNegado = lista.some((c) => c.status === "negado" && !c.abandono);
  return (
    <>
      {lista.map((c) => <RespostaChamado key={c.id} c={c} onMudou={carregar} />)}
      {comMotoboy && !temNegado && !lista.some((c) => c.status === "pendente") && (
        <details className="avancado">
          <summary><UserX size={13} aria-hidden /> O motoboy abandonou a rota?</summary>
          <p className="dica">Tira a rota dele, oferece de novo e lança a penalidade de abandono (o valor está em Ajustes → Motoboys → Penalidades).</p>
          <button type="button" className="botao-perigo" onClick={async () => {
            const { error } = await supabase().rpc("marcar_abandono", { p_corrida: corridaId, p_motivo: null });
            if (error) return toast(traduz(error.message), "erro");
            toast("Rota tirada dele e penalidade lançada.", "ok"); void carregar();
          }}><UserX size={15} aria-hidden /> Marcar abandono</button>
        </details>
      )}
    </>
  );
}
