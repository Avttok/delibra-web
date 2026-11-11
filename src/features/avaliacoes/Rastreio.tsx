"use client";

import { useEffect, useMemo, useState } from "react";
import { Bike, Check, CircleCheck, Clock, MapPin, Package, Send, Timer } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { Estrelas } from "./Avaliacao";

type Ponto = { tipo: "coleta" | "entrega"; status: string; endereco: string; lat: number; lng: number; concluida_em: string | null; recebedor: string | null };
type Dados = {
  erro?: "link_invalido" | "link_expirado";
  pedido?: number; status?: string; rota?: number;
  marca?: { nome: string; topo?: string | null; logo?: string | null; cor?: string | null };
  motoboy?: string | null; posicao?: { lat: number; lng: number; em: string } | null;
  pontos?: Ponto[]; rota_planejada?: string | null; pode_avaliar?: boolean;
};

/** Em que pé está, na língua de quem recebe. */
function fase(d: Dados): { passo: 0 | 1 | 2 | 3; titulo: string; texto: string } {
  const coletou = (d.pontos ?? []).some((p) => p.tipo === "coleta" && p.status === "concluida");
  switch (d.status) {
    case "concluida": case "concluido": return { passo: 3, titulo: "Entregue", texto: "A entrega foi concluída." };
    case "em_andamento": return coletou
      ? { passo: 2, titulo: "A caminho", texto: d.motoboy ? `${d.motoboy} está levando sua entrega.` : "Sua entrega está a caminho." }
      : { passo: 1, titulo: "Indo buscar", texto: d.motoboy ? `${d.motoboy} está indo buscar sua entrega.` : "O motoboy está indo buscar." };
    case "aceita": return { passo: 1, titulo: "Indo buscar", texto: d.motoboy ? `${d.motoboy} aceitou e vai buscar sua entrega.` : "Um motoboy aceitou a entrega." };
    case "cancelada": case "cancelado": return { passo: 0, titulo: "Cancelada", texto: "Esta entrega foi cancelada." };
    default: return { passo: 0, titulo: "Preparando", texto: "Estamos separando um motoboy para a sua entrega." };
  }
}

const PASSOS = [{ rotulo: "Recebido", icone: Package }, { rotulo: "Coleta", icone: Bike }, { rotulo: "A caminho", icone: Send }, { rotulo: "Entregue", icone: CircleCheck }];

function hora(iso: string | null | undefined) {
  return iso ? new Date(iso).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" }) : "";
}

export function Rastreio({ token }: { token: string }) {
  const [d, setD] = useState<Dados | null>(null);
  const [nota, setNota] = useState(0);
  const [comentario, setComentario] = useState("");
  const [avaliado, setAvaliado] = useState(false);
  const [enviando, setEnviando] = useState(false);
  useEffect(() => {
    let vivo = true;
    const buscar = async () => {
      const { data } = await supabase().rpc("rastreio_publico", { p_token: token });
      if (vivo) setD((data as Dados) ?? { erro: "link_invalido" });
    };
    void buscar();
    const t = setInterval(buscar, 15_000);
    return () => { vivo = false; clearInterval(t); };
  }, [token]);

  const pinos: PinoParada[] = useMemo(() => (d?.pontos ?? []).map((p, i) => ({
    chave: `p${i}`, lat: p.lat, lng: p.lng, tipo: p.tipo, rotulo: String(i + 1), concluida: p.status === "concluida",
  })), [d?.pontos]);

  const cor = d?.marca?.cor || "#d4af37";
  const estilo = { ["--marca" as string]: cor } as React.CSSProperties;

  if (!d) return <main className="rastreio" style={estilo}><div className="rastreio-carregando" aria-busy="true">Carregando…</div></main>;
  if (d.erro) return (
    <main className="rastreio" style={estilo}>
      <section className="rastreio-cartao rastreio-fim">
        {d.marca?.logo && <img src={d.marca.logo} alt="" className="rastreio-logo" />}
        <h1>{d.erro === "link_expirado" ? "Este link já expirou" : "Link não encontrado"}</h1>
        <p>{d.erro === "link_expirado" ? "A entrega foi concluída há algum tempo. Se precisar de algo, fale com quem enviou." : "Confira se o endereço está completo ou peça um link novo a quem enviou."}</p>
      </section>
    </main>
  );

  const f = fase(d);
  const entregas = (d.pontos ?? []).filter((p) => p.tipo === "entrega");
  async function avaliar() {
    setEnviando(true);
    const { error } = await supabase().rpc("avaliar_por_rastreio", { p_token: token, p_nota: nota, p_comentario: comentario.trim() || null });
    setEnviando(false);
    if (!error) setAvaliado(true);
  }

  return (
    <main className="rastreio" style={estilo}>
      <header className="rastreio-topo">
        {d.marca?.logo ? <img src={d.marca.logo} alt={d.marca.nome} className="rastreio-logo" /> : <strong className="rastreio-nome">{d.marca?.nome}</strong>}
        <span className="rastreio-pedido">Pedido #{d.pedido}</span>
      </header>

      <section className="rastreio-cartao">
        <div className="rastreio-estado">
          <h1>{f.titulo}</h1>
          <p>{f.texto}</p>
        </div>
        <ol className="rastreio-passos" aria-label="Andamento">
          {PASSOS.map((p, i) => {
            const Ic = p.icone;
            const estado = i < f.passo ? "feito" : i === f.passo ? "agora" : "falta";
            return (
              <li key={p.rotulo} className={`rastreio-passo ${estado}`} aria-current={estado === "agora" ? "step" : undefined}>
                <span className="rastreio-bolinha">{estado === "feito" ? <Check size={14} aria-hidden /> : <Ic size={14} aria-hidden />}</span>
                <span>{p.rotulo}</span>
              </li>
            );
          })}
        </ol>
      </section>

      {(d.status === "aceita" || d.status === "em_andamento" || d.status === "concluida") && pinos.length > 0 && (
        <section className="rastreio-mapa">
          <MapaCorridas paradas={pinos} enquadrar={token} rotaPlanejada={d.rota_planejada ?? null} caminhoAuto={false} legenda={false} maximizavel={false}
            motoboys={d.posicao && d.status !== "concluida" ? [{ id: "m", nome: d.motoboy ?? "Motoboy", lat: d.posicao.lat, lng: d.posicao.lng, status: "em_corrida", foto: null }] : []} />
          {d.posicao && d.status !== "concluida" && <span className="rastreio-atualizado"><Timer size={12} aria-hidden /> posição às {hora(d.posicao.em)}</span>}
        </section>
      )}

      <section className="rastreio-cartao">
        <ul className="rastreio-pontos">
          {(d.pontos ?? []).map((p, i) => (
            <li key={i} className={p.status === "concluida" ? "feito" : ""}>
              <MapPin size={15} aria-hidden />
              <div>
                <strong>{p.tipo === "coleta" ? "Retirada" : entregas.length > 1 ? `Entrega ${entregas.indexOf(p) + 1}` : "Entrega"}</strong>
                <span>{p.endereco}</span>
                {p.concluida_em && <span className="rastreio-dica"><Clock size={11} aria-hidden /> {hora(p.concluida_em)}{p.recebedor ? ` · recebido por ${p.recebedor}` : ""}</span>}
              </div>
            </li>
          ))}
        </ul>
      </section>

      {d.pode_avaliar && !avaliado && (
        <section className="rastreio-cartao rastreio-avaliar">
          <h2>Como foi a entrega?</h2>
          <Estrelas nota={nota} onNota={setNota} tamanho={34} />
          {nota > 0 && <>
            <textarea value={comentario} onChange={(e) => setComentario(e.target.value)} maxLength={500} rows={2} placeholder="Quer contar mais? (opcional)" />
            <button type="button" className="rastreio-botao" disabled={enviando} onClick={avaliar}>{enviando ? "Enviando…" : "Enviar avaliação"}</button>
          </>}
        </section>
      )}
      {avaliado && <section className="rastreio-cartao rastreio-avaliar"><h2>Obrigado!</h2><p>Sua avaliação foi enviada.</p></section>}

      <footer className="rastreio-rodape">Acompanhamento por {d.marca?.nome ?? "Delibra"}</footer>
    </main>
  );
}
