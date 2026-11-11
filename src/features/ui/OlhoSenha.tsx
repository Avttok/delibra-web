"use client";

import { useEffect } from "react";

const OLHO = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/></svg>';
const OLHO_FECHADO = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"/><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"/><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"/><path d="m2 2 20 20"/></svg>';

/**
 * Olho no canto de todo campo de senha do site: mostra/esconde o que foi digitado.
 * Vale para qualquer <input type="password"> (login, cadastro, trocar senha, confirmar…).
 */
export function OlhoSenha() {
  useEffect(() => {
    const enfeitar = (inp: HTMLInputElement) => {
      if (inp.dataset.olho) return;
      inp.dataset.olho = "1";
      // não mexe no lugar do campo (o React cuida dele): só põe o botão ao lado, por cima
      const pai = inp.parentElement;
      if (!pai) return;
      pai.classList.add("olho-pai");
      inp.classList.add("olho-input");
      const b = document.createElement("button");
      b.type = "button"; b.className = "olho-botao"; b.innerHTML = OLHO; b.setAttribute("aria-label", "Ver a senha");
      b.addEventListener("click", () => {
        const ver = inp.type === "password";
        inp.type = ver ? "text" : "password";
        b.innerHTML = ver ? OLHO_FECHADO : OLHO;
        b.setAttribute("aria-label", ver ? "Esconder a senha" : "Ver a senha");
        inp.focus();
      });
      pai.insertBefore(b, inp.nextSibling);
      const posicionar = () => { b.style.top = `${inp.offsetTop + inp.offsetHeight / 2}px`; };
      posicionar();
      new ResizeObserver(posicionar).observe(inp);
    };
    const varrer = () => document.querySelectorAll<HTMLInputElement>('input[type="password"]:not([data-olho])').forEach(enfeitar);
    varrer();
    const obs = new MutationObserver(varrer);
    obs.observe(document.body, { childList: true, subtree: true });
    return () => obs.disconnect();
  }, []);
  return null;
}
