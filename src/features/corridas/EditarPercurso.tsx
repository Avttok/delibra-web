"use client";

import { useEffect, useState } from "react";
import { Check, Route, RotateCcw, Trash2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { geo } from "@/features/geo";
import { toast } from "@/features/ui/toast";

export type ViaPercurso = { lat: number; lng: number; trecho: number; t: number };

/** Em qual trecho (entre duas paradas) o clique cai, e onde nele (0..1). Igual ao app. */
export function encaixarVia(lat: number, lng: number, paradas: { lat: number; lng: number }[]): ViaPercurso {
  let melhor = 0, dist = Infinity, tt = 0.5;
  for (let i = 0; i < paradas.length - 1; i++) {
    const a = paradas[i], b = paradas[i + 1], k = Math.cos((a.lat * Math.PI) / 180);
    const ax = a.lng * k, ay = a.lat, bx = b.lng * k, by = b.lat, px = lng * k, py = lat;
    const dx = bx - ax, dy = by - ay, len = dx * dx + dy * dy;
    const t = len === 0 ? 0 : Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / len));
    const d = Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
    if (d < dist) { dist = d; melhor = i; tt = t; }
  }
  return { lat, lng, trecho: melhor, t: tt };
}

/**
 * Editar percurso (mesmo do app): com o painel aberto, cada clique no mapa vira um ponto de
 * passagem; o caminho é refeito pelas ruas. Salvar grava o traçado que o motoboy vê.
 */
export function EditarPercurso({ corridaId, paradas, vias, setVias, onPolyline, onFechar, distanciaAntes }: {
  corridaId: string; paradas: { lat: number; lng: number }[]; vias: ViaPercurso[]; setVias: (v: ViaPercurso[]) => void;
  onPolyline: (p: string | null) => void; onFechar: () => void; distanciaAntes: number | null;
}) {
  const [calc, setCalc] = useState<{ polyline: string; distanciaM: number; duracaoS: number } | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const chave = vias.map((v) => `${v.lat},${v.lng}`).join("|");

  useEffect(() => {
    void supabase().rpc("corrida_percurso_via", { p_corrida: corridaId }).then(({ data }) => {
      if (Array.isArray(data) && data.length && vias.length === 0) setVias(data as ViaPercurso[]);
    });
  }, [corridaId]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (vias.length === 0 || paradas.length < 2) { setCalc(null); onPolyline(null); return; }
    let vivo = true;
    const seq: { lat: number; lng: number }[] = [];
    paradas.forEach((p, i) => {
      if (i > 0) seq.push(...vias.filter((v) => v.trecho === i - 1).sort((a, b) => a.t - b.t).map((v) => ({ lat: v.lat, lng: v.lng })));
      seq.push(p);
    });
    const t = setTimeout(() => {
      void geo.calcularRota(seq).then((r) => { if (vivo && r) { setCalc(r); onPolyline(r.polyline); } }).catch(() => toast("O mapa não respondeu. Tente de novo.", "erro"));
    }, 250);
    return () => { vivo = false; clearTimeout(t); };
  }, [chave]); // eslint-disable-line react-hooks/exhaustive-deps

  async function salvar() {
    if (!calc) return;
    setOcupado(true);
    const { error } = await supabase().rpc("definir_percurso_rota", { p_corrida: corridaId, p_polyline: calc.polyline, p_distancia_m: calc.distanciaM, p_duracao_s: calc.duracaoS, p_via: vias });
    setOcupado(false);
    if (error) return toast(error.message, "erro");
    toast("O motoboy já vê o caminho novo.", "ok", { titulo: "Percurso salvo" });
    onFechar();
  }
  const km = (m: number) => `${(m / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km`;

  return (
    <section className="bloco editar-percurso">
      <div className="lateral-cabecalho">
        <strong><Route size={15} aria-hidden /> Editar percurso</strong>
        <button type="button" className="botao-icone" onClick={onFechar} aria-label="Fechar"><X size={16} /></button>
      </div>
      <p className="dica" style={{ margin: 0 }}>Puxe a linha do caminho até a rua que você quer, ou clique numa rua. Arraste os pontos numerados para ajustar; duplo clique tira. As paradas ficam na mesma ordem.</p>
      {vias.length > 0 && (
        <ul className="lista-vias">
          {vias.map((v, i) => (
            <li key={`${v.lat},${v.lng}`}>Ponto {i + 1} <small>entre a parada {v.trecho + 1} e a {v.trecho + 2}</small>
              <button type="button" className="botao-icone perigo" onClick={() => setVias(vias.filter((_, j) => j !== i))} aria-label={`Tirar o ponto ${i + 1}`}><Trash2 size={14} /></button></li>
          ))}
        </ul>
      )}
      <p className="dica" style={{ margin: 0 }}>Distância: {calc ? km(calc.distanciaM) : distanciaAntes != null ? km(distanciaAntes) : "—"}{calc && distanciaAntes != null ? ` (antes ${km(distanciaAntes)})` : ""}</p>
      <div className="linha-botoes linha-botoes-iguais">
        <button type="button" className="botao-texto" disabled={!vias.length} onClick={() => setVias(vias.slice(0, -1))}><RotateCcw size={14} aria-hidden /> Desfazer</button>
        <button type="button" className="botao-texto" disabled={!vias.length} onClick={() => setVias([])}><Trash2 size={14} aria-hidden /> Limpar</button>
      </div>
      <button type="button" className="botao" disabled={!calc || ocupado} onClick={salvar}><Check size={15} aria-hidden /> {ocupado ? "Salvando…" : "Salvar percurso"}</button>
    </section>
  );
}
