"use client";

import { useEffect } from "react";

/** Faixas que rolam para o lado (abas, filtros, chips…). */
const ROLAVEIS = ".filtro, .filtro-rolavel, .abas, .config-grupos, .dev-rolagem, .abas-cliente, .linha-chips, .segmentado-rolavel, .rolavel-x";

const podeRolar = (el: Element) => el.scrollWidth > el.clientWidth + 2;

function marcarBordas(el: HTMLElement) {
  const max = el.scrollWidth - el.clientWidth;
  el.classList.toggle("rola-esq", max > 2 && el.scrollLeft > 2);
  el.classList.toggle("rola-dir", max > 2 && el.scrollLeft < max - 2);
}

/**
 * Faz toda faixa lateral rolar no computador também: roda do mouse vira rolagem para o lado,
 * dá para arrastar com o mouse e as bordas esmaecem quando há mais opções escondidas.
 */
export function RolagemLateral() {
  useEffect(() => {
    const vistos = new WeakSet<HTMLElement>();
    const ro = new ResizeObserver((es) => es.forEach((e) => marcarBordas(e.target as HTMLElement)));
    const aoRolar = (e: Event) => marcarBordas(e.currentTarget as HTMLElement);
    function varrer() {
      document.querySelectorAll<HTMLElement>(ROLAVEIS).forEach((el) => {
        if (!vistos.has(el)) {
          vistos.add(el);
          el.addEventListener("scroll", aoRolar, { passive: true });
          ro.observe(el);
        }
        marcarBordas(el);
      });
    }
    varrer();
    const mo = new MutationObserver(() => varrer());
    mo.observe(document.body, { childList: true, subtree: true });

    // roda do mouse → para o lado
    const roda = (e: WheelEvent) => {
      if (e.ctrlKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) return;
      const el = (e.target as Element | null)?.closest<HTMLElement>(ROLAVEIS);
      if (!el || !podeRolar(el)) return;
      const max = el.scrollWidth - el.clientWidth;
      if ((e.deltaY < 0 && el.scrollLeft <= 0) || (e.deltaY > 0 && el.scrollLeft >= max - 1)) return; // no fim: deixa a página rolar
      e.preventDefault();
      el.scrollLeft += e.deltaY;
    };
    // arrastar com o mouse (no toque o navegador já faz)
    let arrasto: { el: HTMLElement; x: number; inicio: number; moveu: boolean } | null = null;
    const baixo = (e: PointerEvent) => {
      if (e.pointerType !== "mouse" || e.button !== 0) return;
      const el = (e.target as Element | null)?.closest<HTMLElement>(ROLAVEIS);
      if (!el || !podeRolar(el)) return;
      arrasto = { el, x: e.clientX, inicio: el.scrollLeft, moveu: false };
    };
    const move = (e: PointerEvent) => {
      if (!arrasto) return;
      const dx = e.clientX - arrasto.x;
      if (!arrasto.moveu && Math.abs(dx) < 6) return;
      arrasto.moveu = true;
      arrasto.el.scrollLeft = arrasto.inicio - dx;
      arrasto.el.classList.add("arrastando");
    };
    const cima = () => {
      if (!arrasto) return;
      const a = arrasto;
      arrasto = null;
      a.el.classList.remove("arrastando");
      if (a.moveu) {
        // o soltar depois de arrastar não vira clique na aba
        const bloquear = (ev: MouseEvent) => { ev.stopPropagation(); ev.preventDefault(); };
        window.addEventListener("click", bloquear, { capture: true, once: true });
        setTimeout(() => window.removeEventListener("click", bloquear, { capture: true }), 50);
      }
    };
    // a aba clicada vem para a vista
    const clique = (e: MouseEvent) => {
      const b = (e.target as Element | null)?.closest<HTMLElement>("button, a");
      const el = b?.closest<HTMLElement>(ROLAVEIS);
      if (b && el && podeRolar(el)) b.scrollIntoView({ inline: "nearest", block: "nearest", behavior: "smooth" });
    };
    document.addEventListener("wheel", roda, { passive: false });
    document.addEventListener("pointerdown", baixo);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", cima);
    document.addEventListener("click", clique);
    return () => {
      mo.disconnect(); ro.disconnect();
      document.removeEventListener("wheel", roda);
      document.removeEventListener("pointerdown", baixo);
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", cima);
      document.removeEventListener("click", clique);
    };
  }, []);
  return null;
}
