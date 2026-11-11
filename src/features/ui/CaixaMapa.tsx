"use client";

import { useEffect, useState, type CSSProperties, type ReactNode, type RefObject } from "react";
import { Maximize2, Minus, Plus, X } from "lucide-react";
import type { maplibregl } from "@/lib/mapa/maplibre";

/** Caixa de mapa com tela cheia, aproximar e afastar. O mesmo mapa (cliques e edição continuam). */
export function CaixaMapa({ refMapa, mapa, className, style, titulo, children, painelCheio }: {
  refMapa: RefObject<HTMLDivElement | null>; mapa: RefObject<maplibregl.Map | null>;
  className?: string; style?: CSSProperties; titulo?: string; children?: ReactNode;
  /** As ferramentas da tela (ex.: raio, centro) também na tela cheia, embaixo. */
  painelCheio?: ReactNode;
}) {
  const [cheio, setCheio] = useState(false);
  useEffect(() => {
    setTimeout(() => mapa.current?.resize(), 30);
    if (!cheio) return;
    const esc = (e: KeyboardEvent) => { if (e.key === "Escape") setCheio(false); };
    window.addEventListener("keydown", esc);
    document.body.classList.add("com-mapa-cheio");
    return () => { window.removeEventListener("keydown", esc); document.body.classList.remove("com-mapa-cheio"); };
  }, [cheio, mapa]);
  return (
    <div className={`mapa-caixa${className ? ` ${className}` : ""}${cheio ? " mapa-cheia" : ""}`} style={cheio ? undefined : style}>
      <div ref={refMapa} className="mapa-caixa-mapa" />
      <div className="mapa-cheia-topo">
        <button type="button" className="mapa-botao" aria-label={cheio ? "Sair da tela cheia" : "Tela cheia"} title={cheio ? "Sair da tela cheia (Esc)" : "Tela cheia"} onClick={() => setCheio(!cheio)}>
          {cheio ? <X size={18} aria-hidden /> : <Maximize2 size={16} aria-hidden />}
        </button>
        {cheio && titulo && <span className="mapa-cheia-titulo">{titulo}</span>}
      </div>
      {cheio && (
        <div className="mapa-controles">
          <button type="button" className="mapa-botao" aria-label="Aproximar" onClick={() => mapa.current?.zoomIn()}><Plus size={18} aria-hidden /></button>
          <button type="button" className="mapa-botao" aria-label="Afastar" onClick={() => mapa.current?.zoomOut()}><Minus size={18} aria-hidden /></button>
        </div>
      )}
      {cheio && painelCheio && <div className="mapa-cheia-painel vidro">{painelCheio}</div>}
      {children}
    </div>
  );
}
