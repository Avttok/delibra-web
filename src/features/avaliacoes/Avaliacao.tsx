"use client";

import { useEffect, useState } from "react";
import { Check, Copy, Link2, Send, Star } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

const DICA_NOTA = ["", "Muito ruim", "Ruim", "Ok", "Boa", "Excelente"];

/** Cinco estrelas para tocar (ou só mostrar, com [somenteLer]). */
export function Estrelas({ nota, onNota, tamanho = 30, somenteLer = false }: { nota: number; onNota?: (n: number) => void; tamanho?: number; somenteLer?: boolean }) {
  const [sobre, setSobre] = useState(0);
  const mostra = sobre || nota;
  return (
    <div className="estrelas" role={somenteLer ? "img" : "radiogroup"} aria-label={`${nota} de 5 estrelas`} onMouseLeave={() => setSobre(0)}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} type="button" className={`estrela${n <= mostra ? " acesa" : ""}`} disabled={somenteLer} aria-label={`${n} estrela${n > 1 ? "s" : ""}`}
          aria-checked={n === nota} role={somenteLer ? undefined : "radio"} onMouseEnter={() => !somenteLer && setSobre(n)} onClick={() => onNota?.(n)}>
          <Star size={tamanho} aria-hidden />
        </button>
      ))}
    </div>
  );
}

/** Depois da entrega: o cliente dá de 1 a 5 estrelas e um comentário. Mostra a que ele já deu. */
export function AvaliarPedido({ pedidoId }: { pedidoId: string }) {
  const [feita, setFeita] = useState<{ nota: number; comentario: string | null } | null | undefined>(undefined);
  const [nota, setNota] = useState(0);
  const [comentario, setComentario] = useState("");
  const [ocupado, setOcupado] = useState(false);
  useEffect(() => {
    void supabase().rpc("minha_avaliacao", { p_pedido: pedidoId }).then(({ data }) => setFeita((data as { nota: number; comentario: string | null } | null) ?? null));
  }, [pedidoId]);
  if (feita === undefined) return null;
  if (feita) return (
    <div className="avaliacao feita">
      <span className="rotulo"><Check size={12} aria-hidden /> Sua avaliação</span>
      <Estrelas nota={feita.nota} somenteLer tamanho={20} />
      {feita.comentario && <p className="dica" style={{ margin: 0 }}>“{feita.comentario}”</p>}
    </div>
  );
  async function enviar() {
    setOcupado(true);
    const { error } = await supabase().rpc("avaliar_pedido", { p_pedido: pedidoId, p_nota: nota, p_comentario: comentario.trim() || null });
    setOcupado(false);
    if (error) return toast(error.message.includes("ja_avaliado") ? "Este pedido já foi avaliado." : error.message.includes("avalie_depois") ? "Dá para avaliar depois da entrega." : "Não deu para enviar agora.", "erro");
    toast("Obrigado! Sua avaliação foi enviada.", "ok");
    setFeita({ nota, comentario: comentario.trim() || null });
  }
  return (
    <div className="avaliacao">
      <span className="rotulo"><Star size={12} aria-hidden /> Como foi a entrega?</span>
      <Estrelas nota={nota} onNota={setNota} />
      {nota > 0 && <span className="dica">{DICA_NOTA[nota]}</span>}
      {nota > 0 && <>
        <textarea value={comentario} onChange={(e) => setComentario(e.target.value)} maxLength={500} rows={2} placeholder="Quer contar mais? (opcional)" />
        <div className="linha-botoes"><button type="button" className="botao-ouro" disabled={ocupado} onClick={enviar}><Send size={15} aria-hidden /> {ocupado ? "Enviando…" : "Enviar avaliação"}</button></div>
      </>}
    </div>
  );
}

/** Gera o link para quem recebe acompanhar a entrega (sem precisar de conta) e copia. */
export function BotaoRastreio({ pedidoId, compacto = false }: { pedidoId: string; compacto?: boolean }) {
  const [link, setLink] = useState<string | null>(null);
  const [ocupado, setOcupado] = useState(false);
  async function gerar() {
    setOcupado(true);
    const { data, error } = await supabase().rpc("gerar_rastreio", { p_pedido: pedidoId, p_ponto: null });
    setOcupado(false);
    if (error) return toast(error.message.includes("rastreio_desligado") ? "O link de rastreio está desligado." : "Não deu para gerar o link agora.", "erro");
    const r = data as { url: string; token: string };
    const url = r.url.startsWith("http") ? r.url : `${window.location.origin}/r/${r.token}`;
    setLink(url);
    try { await navigator.clipboard.writeText(url); toast("Link copiado: mande para quem vai receber.", "ok", { titulo: "Link de rastreio" }); }
    catch { toast("Link pronto: copie abaixo.", "ok"); }
  }
  return (
    <div className="rastreio-botao">
      <button type="button" className={compacto ? "botao-texto" : "botao-vidro"} disabled={ocupado} onClick={gerar}>
        <Link2 size={15} aria-hidden /> {ocupado ? "Gerando…" : link ? "Copiar de novo" : "Link de rastreio"}
      </button>
      {link && (
        <span className="rastreio-link">
          <code>{link}</code>
          <button type="button" className="botao-icone" aria-label="Copiar" onClick={() => { void navigator.clipboard.writeText(link).then(() => toast("Copiado.", "ok")); }}><Copy size={14} aria-hidden /></button>
        </span>
      )}
    </div>
  );
}
