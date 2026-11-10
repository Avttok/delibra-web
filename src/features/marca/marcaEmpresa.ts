"use client";

import { useSyncExternalStore } from "react";

/**
 * Marca da empresa (organização) da conta: quando o dono ou o Dev define um ícone, ele
 * aparece no lugar do Delibra em todo o site (cabeçalhos, tela de entrar, ícone da aba).
 * Fica guardada no navegador para a próxima visita já abrir com ela.
 */
export type MarcaEmpresa = { nome: string; logo: string | null; cor?: string | null };

const CHAVE = "delibra_marca";
let atual: MarcaEmpresa | null = null;
const ouvintes = new Set<() => void>();

function ler(): MarcaEmpresa | null {
  try { const t = localStorage.getItem(CHAVE); return t ? (JSON.parse(t) as MarcaEmpresa) : null; } catch { return null; }
}

let carregado = false;
function garantir() {
  if (carregado || typeof window === "undefined") return;
  carregado = true;
  atual = ler();
  aplicarFavicon(atual?.logo ?? null);
}

function aplicarFavicon(url: string | null) {
  if (typeof document === "undefined") return;
  let link = document.querySelector<HTMLLinkElement>("link[data-marca-empresa]");
  if (!url) { link?.remove(); return; }
  if (!link) {
    link = document.createElement("link");
    link.rel = "icon";
    link.setAttribute("data-marca-empresa", "1");
    document.head.appendChild(link);
  }
  link.href = url;
}

export function definirMarcaEmpresa(m: MarcaEmpresa | null) {
  const v = m && (m.logo || m.nome) ? m : null;
  atual = v;
  try { if (v) localStorage.setItem(CHAVE, JSON.stringify(v)); else localStorage.removeItem(CHAVE); } catch { /* sem armazenamento */ }
  aplicarFavicon(v?.logo ?? null);
  ouvintes.forEach((f) => f());
}

export function useMarcaEmpresa(): MarcaEmpresa | null {
  return useSyncExternalStore(
    (f) => { garantir(); ouvintes.add(f); return () => ouvintes.delete(f); },
    () => { garantir(); return atual; },
    () => null,
  );
}
