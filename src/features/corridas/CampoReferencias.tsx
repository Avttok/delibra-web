"use client";

import { useState } from "react";
import { Landmark, Loader2, Plus, Sparkles, X } from "lucide-react";
import { geo, type Referencia } from "@/features/geo";

export const MAX_REFERENCIAS = 3;

const distancia = (m?: number | null) => (m == null ? "" : m < 1000 ? `${m} m` : `${(m / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km`);

/** Até 3 pontos de referência perto da parada (o motoboy vê no app). */
export function CampoReferencias({ valor, onMudar, lat, lng }: {
  valor: Referencia[];
  onMudar: (r: Referencia[]) => void;
  lat: number | null;
  lng: number | null;
}) {
  const [texto, setTexto] = useState("");
  const [sugestoes, setSugestoes] = useState<Referencia[] | null>(null);
  const [buscando, setBuscando] = useState(false);
  const cheio = valor.length >= MAX_REFERENCIAS;
  const jaTem = (nome: string) => valor.some((r) => r.nome.toLowerCase() === nome.toLowerCase());

  function adicionar(r: Referencia) {
    if (cheio || !r.nome.trim() || jaTem(r.nome)) return;
    onMudar([...valor, { ...r, nome: r.nome.trim() }]);
  }

  async function sugerir() {
    if (lat == null || lng == null) return;
    setBuscando(true);
    let r = await geo.pontosProximos(lat, lng, 250);
    if (!r.length) r = await geo.pontosProximos(lat, lng, 600);
    setSugestoes(r);
    setBuscando(false);
  }

  return (
    <div className="referencias">
      <span className="referencias-titulo">
        <Landmark size={13} aria-hidden /> Pontos de referência <span className="referencias-n">{valor.length}/{MAX_REFERENCIAS}</span>
      </span>

      {valor.length > 0 && (
        <ul className="referencias-lista">
          {valor.map((r) => (
            <li key={r.nome}>
              <span className="referencia-nome">{r.nome}</span>
              {(r.tipo || r.distancia_m != null || r.relacao) && <small>{r.relacao ?? [r.tipo, distancia(r.distancia_m)].filter(Boolean).join(" · ")}</small>}
              <button type="button" onClick={() => onMudar(valor.filter((x) => x !== r))} aria-label={`Remover ${r.nome}`}><X size={13} /></button>
            </li>
          ))}
        </ul>
      )}

      {!cheio && (
        <div className="referencias-novo">
          <input placeholder="Ex.: em frente ao Posto Ipiranga" value={texto} maxLength={80}
            onChange={(e) => setTexto(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); adicionar({ nome: texto }); setTexto(""); } }} />
          <button type="button" className="botao-texto" disabled={!texto.trim()} onClick={() => { adicionar({ nome: texto }); setTexto(""); }}>
            <Plus size={14} aria-hidden /> Adicionar
          </button>
          <button type="button" className="botao-texto" disabled={lat == null || buscando} onClick={sugerir}
            title={lat == null ? "Localize o endereço primeiro" : "Buscar estabelecimentos perto deste ponto"}>
            {buscando ? <Loader2 size={14} className="girando" aria-hidden /> : <Sparkles size={14} aria-hidden />} Sugerir próximos
          </button>
        </div>
      )}

      {sugestoes && !cheio && (
        sugestoes.length === 0
          ? <p className="dica" style={{ margin: 0 }}>Nada com nome até 600 m daqui. Aproxime o mapa nesse ponto e toque em “Sugerir próximos” de novo, ou escreva a referência acima.</p>
          : (
            <div className="referencias-sugestoes">
              {sugestoes.filter((s) => !jaTem(s.nome)).map((s) => (
                <button key={`${s.nome}-${s.lat}`} type="button" className="chip" onClick={() => adicionar(s)}>
                  <Plus size={12} aria-hidden /> {s.nome} <small>{s.relacao ? s.relacao.replace(` de ${s.nome}`, "") : [s.tipo, distancia(s.distancia_m)].filter(Boolean).join(" · ")}</small>
                </button>
              ))}
            </div>
          )
      )}
    </div>
  );
}
