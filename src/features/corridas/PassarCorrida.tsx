"use client";

import { useState } from "react";
import { ArrowLeftRight } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { traduzirErro, type MembroEquipe } from "./dados";
import type { Corrida } from "./tipos";

/** Rota aceita (nada coletado ainda): tira do motoboy e passa para outro, ou devolve ao sistema. */
export function PassarCorrida({ corrida, equipe }: { corrida: Corrida; equipe: MembroEquipe[] }) {
  const [aberto, setAberto] = useState(false);
  const [para, setPara] = useState("");
  const [motivo, setMotivo] = useState("");
  const [ocupado, setOcupado] = useState(false);
  const atual = equipe.find((m) => m.id === corrida.motoboy_id)?.nome?.split(" ")[0] ?? "o motoboy";
  const opcoes = equipe.filter((m) => m.id !== corrida.motoboy_id && m.modo_teste === corrida.teste);

  async function passar() {
    setOcupado(true);
    const { error } = await supabase().rpc("passar_corrida", { p_corrida: corrida.id, p_motoboy: para || null, p_motivo: motivo.trim() || null });
    setOcupado(false);
    if (error) return toast(traduzirErro(error.message), "erro");
    toast(para ? `Passada para ${equipe.find((m) => m.id === para)?.nome ?? "o motoboy"}: ele recebe a oferta.` : "Devolvida ao sistema: vai para o despacho.", "ok", { titulo: "Rota passada" });
    setAberto(false); setPara(""); setMotivo("");
  }

  if (!aberto) return (
    <button type="button" className="botao-vidro" onClick={() => setAberto(true)}>
      <ArrowLeftRight size={15} aria-hidden /> Passar para outro motoboy
    </button>
  );
  return (
    <div className="bloco passar-corrida">
      <span className="rotulo"><ArrowLeftRight size={12} aria-hidden /> Passar a rota</span>
      <p className="dica" style={{ margin: 0 }}>Dá enquanto nada foi coletado. {atual.charAt(0).toUpperCase() + atual.slice(1)} é avisado.</p>
      <select value={para} onChange={(e) => setPara(e.target.value)} aria-label="Para quem">
        <option value="">O sistema escolhe (mais perto)</option>
        {opcoes.map((m) => <option key={m.id} value={m.id}>{m.nome}{m.status === "disponivel" ? " · online" : m.status === "em_corrida" ? " · em rota" : ""}</option>)}
      </select>
      <input value={motivo} onChange={(e) => setMotivo(e.target.value)} placeholder="Motivo (o motoboy vê) · opcional" maxLength={200} />
      <div className="linha-botoes">
        <button type="button" className="botao-texto" onClick={() => setAberto(false)}>Voltar</button>
        <button type="button" className="botao-ouro" disabled={ocupado} onClick={passar}>
          <ArrowLeftRight size={15} aria-hidden /> {ocupado ? "Passando…" : para ? "Passar" : "Devolver ao sistema"}
        </button>
      </div>
    </div>
  );
}
