"use client";

import { usePermissoes } from "@/features/conta/permissoes";

import { useState } from "react";
import { CalendarClock, Repeat, Send, TriangleAlert, UserCheck, UserMinus, Play } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { traduzirErro, type MembroEquipe } from "./dados";
import { formatarQuando, paraCampo, relativo } from "./planejadas";
import type { Corrida } from "./tipos";

/** Bloco do detalhe para corridas planejadas: quando, quem reservou, prazos e ações do gestor. */
export function GestaoPlanejada({ corrida, equipe, cfg, agora }: {
  corrida: Corrida;
  equipe: MembroEquipe[];
  cfg: Record<string, number | boolean | string | string[]>;
  agora: number;
}) {
  const [motoboy, setMotoboy] = useState("");
  const [novoHorario, setNovoHorario] = useState(() => paraCampo(new Date(corrida.agendada_para ?? Date.now())));
  const [reagendando, setReagendando] = useState(false);
  const perm = usePermissoes();
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);

  const quando = new Date(corrida.agendada_para ?? 0).getTime();
  const min = (k: string, p: number) => (Number(cfg[k]) || p) * 60000;
  const desistirAte = quando - min("agendada_cancelar_ate_min", 60);
  const iniciarDesde = quando - min("agendada_iniciar_antes_min", 60);
  const reservado = equipe.find((m) => m.id === corrida.motoboy_id);
  const compativeis = equipe.filter((m) => m.modo_teste === corrida.teste && m.id !== corrida.motoboy_id);

  async function acao(p_acao: string, extra: Record<string, unknown> = {}, confirmar?: string) {
    if (confirmar && !confirm(confirmar)) return;
    setErro(null);
    setEnviando(true);
    const { error } = await supabase().rpc("gerenciar_planejada", { p_corrida: corrida.id, p_acao, p_motoboy: null, p_quando: null, ...extra });
    setEnviando(false);
    if (error) return setErro(traduzirErro(error.message));
    setReagendando(false);
    setMotoboy("");
  }

  return (
    <section className={`bloco bloco-planejada ${corrida.atraso_avisado_em ? "atrasada" : ""}`}>
      <span className="rotulo"><CalendarClock size={12} aria-hidden style={{ verticalAlign: -1 }} /> Corrida planejada{corrida.serie_id ? " · faz parte de uma repetição" : ""}</span>
      <div className="planejada-quando">
        <strong className="display">{formatarQuando(corrida.agendada_para)}</strong>
        <span>{corrida.atraso_avisado_em ? <><TriangleAlert size={13} aria-hidden /> atrasada: ainda não foi iniciada</> : relativo(corrida.agendada_para, agora)}</span>
      </div>

      {corrida.motoboy_id ? (
        <p className="dica" style={{ margin: 0 }}>
          Reservada por <strong style={{ color: "var(--texto)" }}>{reservado?.nome ?? "—"}</strong>
          {corrida.reservada_em ? ` em ${formatarQuando(corrida.reservada_em)}` : ""}.{" "}
          {agora < desistirAte ? `Pode desistir pelo app até ${formatarQuando(new Date(desistirAte).toISOString())}.` : "O prazo de desistência pelo app já passou."}{" "}
          {agora < iniciarDesde ? `Pode iniciar a partir de ${formatarQuando(new Date(iniciarDesde).toISOString())}.` : "Já pode iniciar pelo app."}
        </p>
      ) : (
        <p className="dica" style={{ margin: 0 }}>
          Livre: aparece no app de todos os motoboys{corrida.teste ? " em modo teste" : ""}, e o primeiro que reservar fica com ela.
          {cfg.agendada_despacho_auto
            ? ` Se ninguém reservar até ${Number(cfg.agendada_despacho_auto_min)} min antes, vai para o despacho normal.`
            : " Se ninguém reservar, fica “sem motoboy” no horário."}
        </p>
      )}

      <div className="planejada-acoes">
        <div className="linha-campos">
          <select value={motoboy} onChange={(e) => setMotoboy(e.target.value)} aria-label="Reservar para">
            <option value="">{corrida.motoboy_id ? "Passar para outro motoboy…" : "Reservar para um motoboy…"}</option>
            {compativeis.map((m) => <option key={m.id} value={m.id}>{m.nome}</option>)}
          </select>
          <button className="botao-texto" disabled={!motoboy || enviando} onClick={() => acao("reservar", { p_motoboy: motoboy })}>
            <UserCheck size={15} aria-hidden /> Reservar
          </button>
        </div>

        {reagendando ? (
          <div className="linha-campos">
            <input type="datetime-local" value={novoHorario} onChange={(e) => setNovoHorario(e.target.value)} aria-label="Novo horário" />
            <button className="botao-ouro" disabled={enviando} onClick={() => acao("reagendar", { p_quando: new Date(novoHorario).toISOString() })}>Salvar</button>
            <button className="botao-texto" onClick={() => setReagendando(false)}>Cancelar</button>
          </div>
        ) : null}

        <div className="linha-botoes">
          {!reagendando && <button className="botao-texto" onClick={() => setReagendando(true)}><Repeat size={15} aria-hidden /> Mudar horário</button>}
          {corrida.motoboy_id && (
            <button className="botao-texto" disabled={enviando}
              onClick={() => acao("liberar", {}, `Tirar a reserva de ${reservado?.nome ?? "motoboy"}? A corrida volta a ficar livre para todos.`)}>
              <UserMinus size={15} aria-hidden /> Liberar reserva
            </button>
          )}
          {corrida.motoboy_id && perm.pode("forcar_inicio") && (
            <button className="botao-ouro" disabled={enviando}
              onClick={() => acao("iniciar_agora", {}, `Começar agora com ${reservado?.nome ?? "o motoboy reservado"}? A rota vira a corrida dele na hora, sem esperar o horário.`)}>
              <Play size={15} aria-hidden /> Começar agora
            </button>
          )}
          <button className="botao-texto" disabled={enviando}
            onClick={() => acao("despachar_agora", {}, "Despachar agora para o motoboy mais próximo? A corrida deixa de ser planejada.")}>
            <Send size={15} aria-hidden /> Despachar agora
          </button>
        </div>
      </div>
      {erro && <p className="erro">{erro}</p>}
    </section>
  );
}
