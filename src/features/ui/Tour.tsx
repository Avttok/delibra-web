"use client";

import { useCallback, useEffect, useLayoutEffect, useState } from "react";
import { createPortal } from "react-dom";

/** Um passo do tour: aponta um elemento (seletor CSS) ou aparece no centro. */
export interface PassoTour { alvo?: string; titulo: string; texto: string }

const visto = (id: string) => { try { return localStorage.getItem(`pwex-tour-${id}`) === "1"; } catch { return true; } };
const marcar = (id: string) => { try { localStorage.setItem(`pwex-tour-${id}`, "1"); } catch {} };

/** Abre o tour de novo (botão "Ver o tour" no menu). */
export function abrirTour(id: string) { window.dispatchEvent(new CustomEvent("pwex-tour", { detail: id })); }

/**
 * Tour guiado: na primeira vez abre sozinho; depois, só pelo menu.
 * Destaca o elemento com um recorte e mostra a explicação do lado.
 */
export function Tour({ id, passos, automatico = true }: { id: string; passos: PassoTour[]; automatico?: boolean }) {
  const [i, setI] = useState<number | null>(null);
  const [caixa, setCaixa] = useState<DOMRect | null>(null);

  useEffect(() => {
    if (automatico && !visto(id)) { const t = setTimeout(() => setI(0), 900); return () => clearTimeout(t); }
  }, [id, automatico]);
  useEffect(() => {
    const abrir = (e: Event) => { if ((e as CustomEvent).detail === id) setI(0); };
    window.addEventListener("pwex-tour", abrir);
    return () => window.removeEventListener("pwex-tour", abrir);
  }, [id]);

  const passo = i != null ? passos[i] : null;
  const medir = useCallback(() => {
    if (!passo?.alvo) return setCaixa(null);
    const el = Array.from(document.querySelectorAll<HTMLElement>(passo.alvo)).find((x) => x.offsetParent !== null);
    if (!el) return setCaixa(null);
    el.scrollIntoView({ block: "nearest", inline: "nearest" });
    setCaixa(el.getBoundingClientRect());
  }, [passo]);
  useLayoutEffect(() => {
    if (i == null) return;
    medir();
    window.addEventListener("resize", medir); window.addEventListener("scroll", medir, true);
    return () => { window.removeEventListener("resize", medir); window.removeEventListener("scroll", medir, true); };
  }, [i, medir]);
  useEffect(() => {
    if (i == null) return;
    const tecla = (e: KeyboardEvent) => {
      if (e.key === "Escape") fechar();
      if (e.key === "ArrowRight") avancar();
      if (e.key === "ArrowLeft") setI((x) => (x != null && x > 0 ? x - 1 : x));
    };
    window.addEventListener("keydown", tecla);
    return () => window.removeEventListener("keydown", tecla);
  });

  function fechar() { marcar(id); setI(null); }
  function avancar() { if (i == null) return; if (i >= passos.length - 1) fechar(); else setI(i + 1); }
  if (i == null || !passo || typeof document === "undefined") return null;

  const folga = 8;
  const largura = Math.min(340, window.innerWidth - 32);
  let pos: React.CSSProperties;
  if (caixa) {
    const abaixo = caixa.bottom + 14 + 190 < window.innerHeight;
    const left = Math.max(16, Math.min(caixa.left + caixa.width / 2 - largura / 2, window.innerWidth - largura - 16));
    pos = abaixo ? { top: caixa.bottom + 14, left } : { top: Math.max(16, caixa.top - 14 - 190), left };
  } else pos = { top: "50%", left: "50%", transform: "translate(-50%, -50%)" };

  return createPortal(
    <div className="tour" role="dialog" aria-modal="true" aria-label={passo.titulo}>
      <div className="tour-fundo" onClick={fechar} />
      {caixa && <div className="tour-recorte" style={{ top: caixa.top - folga, left: caixa.left - folga, width: caixa.width + folga * 2, height: caixa.height + folga * 2 }} />}
      {!caixa && <div className="tour-escuro" />}
      <div className="tour-balao vidro" style={{ ...pos, width: largura }}>
        <span className="tour-conta">{i + 1} de {passos.length}</span>
        <strong>{passo.titulo}</strong>
        <p>{passo.texto}</p>
        <div className="tour-acoes">
          <button type="button" className="botao-texto" onClick={fechar}>{i >= passos.length - 1 ? "Fechar" : "Pular"}</button>
          <span className="espaco" />
          {i > 0 && <button type="button" className="botao-texto" onClick={() => setI(i - 1)}>Voltar</button>}
          <button type="button" className="botao-ouro" onClick={avancar} autoFocus>{i >= passos.length - 1 ? "Terminar" : "Próximo"}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

/** (?) ao lado de uma opção que pode confundir: explica num balão. */
export function Dica({ texto, titulo }: { texto: string; titulo?: string }) {
  const [aberta, setAberta] = useState(false);
  return (
    <span className="dica-q">
      <button type="button" className="dica-q-botao" aria-label={titulo ? `O que é ${titulo}?` : "O que é isso?"} aria-expanded={aberta}
        onClick={(e) => { e.preventDefault(); e.stopPropagation(); setAberta((a) => !a); }}
        onBlur={() => setTimeout(() => setAberta(false), 150)}>?</button>
      {aberta && <span className="dica-q-balao vidro" role="tooltip">{titulo && <strong>{titulo}</strong>}{texto}</span>}
    </span>
  );
}
