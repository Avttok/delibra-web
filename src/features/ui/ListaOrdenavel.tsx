"use client";

import { useRef, useState, type ReactNode } from "react";
import { ChevronDown, ChevronUp, GripVertical } from "lucide-react";

/** Move o item `de` para a posição `para`. */
export function mover<T>(lista: T[], de: number, para: number): T[] {
  if (de === para || de < 0 || para < 0 || de >= lista.length || para >= lista.length) return lista;
  const l = [...lista];
  const [x] = l.splice(de, 1);
  l.splice(para, 0, x);
  return l;
}

interface Arrasto { de: number; para: number; inicioY: number; dy: number; meios: number[]; alturas: number[]; gap: number }

/**
 * Lista que se reordena arrastando pela alça (ou pelas setas).
 * Sem "tremedeira": as posições são medidas uma vez quando o arrasto começa e os outros itens
 * só deslizam por transform; a ordem de verdade muda uma única vez, ao soltar.
 */
export function ListaOrdenavel<T>({ itens, chave, onMudar, render, className }: {
  itens: T[];
  chave: (x: T) => string;
  onMudar: (nova: T[]) => void;
  render: (x: T, i: number, alca: ReactNode) => ReactNode;
  className?: string;
}) {
  const caixa = useRef<HTMLDivElement>(null);
  const [a, setA] = useState<Arrasto | null>(null);

  function comecar(e: React.PointerEvent, i: number) {
    if (e.button !== 0 && e.pointerType === "mouse") return;
    const filhos = [...(caixa.current?.children ?? [])] as HTMLElement[];
    const rects = filhos.map((f) => f.getBoundingClientRect());
    const gap = rects.length > 1 ? Math.max(0, rects[1].top - rects[0].bottom) : 0;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    e.preventDefault();
    setA({ de: i, para: i, inicioY: e.clientY, dy: 0, meios: rects.map((r) => r.top + r.height / 2), alturas: rects.map((r) => r.height), gap });
  }
  function mexer(e: React.PointerEvent) {
    if (!a) return;
    const dy = e.clientY - a.inicioY;
    const centro = a.meios[a.de] + dy;
    let para = a.de;
    for (let k = 0; k < a.meios.length; k++) {
      if (k < a.de && centro < a.meios[k]) { para = k; break; }
      if (k > a.de && centro > a.meios[k]) para = k;
    }
    setA({ ...a, dy, para });
  }
  function soltar() {
    if (!a) return;
    const { de, para } = a;
    setA(null);
    if (de !== para) onMudar(mover(itens, de, para));
  }
  function desloc(i: number): number {
    if (!a) return 0;
    if (i === a.de) return a.dy;
    const alt = a.alturas[a.de] + a.gap;
    if (a.de < a.para && i > a.de && i <= a.para) return -alt;
    if (a.de > a.para && i < a.de && i >= a.para) return alt;
    return 0;
  }

  return (
    <div ref={caixa} className={`lista-ordenavel ${a ? "arrastando-lista" : ""} ${className ?? ""}`}>
      {itens.map((x, i) => {
        const alca = (
          <span className="alca-ordem">
            <button type="button" className="icone alca" aria-label="Arrastar para mudar a ordem" title="Arraste para mudar a ordem"
              onPointerDown={(e) => comecar(e, i)} onPointerMove={mexer} onPointerUp={soltar} onPointerCancel={soltar}><GripVertical size={15} /></button>
            <button type="button" className="icone" aria-label="Subir" disabled={i === 0} onClick={() => onMudar(mover(itens, i, i - 1))}><ChevronUp size={14} /></button>
            <button type="button" className="icone" aria-label="Descer" disabled={i === itens.length - 1} onClick={() => onMudar(mover(itens, i, i + 1))}><ChevronDown size={14} /></button>
          </span>
        );
        const ativo = a?.de === i;
        return (
          <div key={chave(x)} className={`item-ordenavel ${ativo ? "segurado" : ""}`}
            style={{ transform: `translate3d(0, ${desloc(i)}px, 0)`, transition: ativo || !a ? "none" : "transform 160ms cubic-bezier(0.2, 0.8, 0.3, 1)", zIndex: ativo ? 5 : undefined }}>
            {render(x, i, alca)}
          </div>
        );
      })}
    </div>
  );
}
