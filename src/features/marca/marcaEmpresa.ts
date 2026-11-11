"use client";

import { useSyncExternalStore } from "react";

/**
 * Marca da empresa (organização) da conta: quando o dono ou o Dev define um ícone, ele
 * aparece no lugar do Delibra em todo o site (cabeçalhos, tela de entrar, ícone da aba).
 * Fica guardada no navegador para a próxima visita já abrir com ela.
 */
/** `nomeApp`: nome que aparece no lugar de "Delibra" (vazio = Delibra). */
export type MarcaEmpresa = { nome: string; logo: string | null; cor?: string | null; nomeApp?: string | null; escala?: number | null };

/** Nome do app para esta conta: o escolhido pela empresa, ou o da empresa quando ela tem ícone, ou Delibra. */
export const nomeDoApp = (m: MarcaEmpresa | null) => m?.nomeApp || (m?.logo ? m.nome : "Delibra");

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
  aplicarTitulo(atual);
}

let observador: MutationObserver | null = null;
/** Troca "Delibra" pelo nome do app no título da aba (e continua trocando quando a página muda). */
function aplicarTitulo(m: MarcaEmpresa | null) {
  if (typeof document === "undefined") return;
  const nome = nomeDoApp(m);
  const trocar = () => { if (nome !== "Delibra" && document.title.includes("Delibra")) document.title = document.title.replace(/Delibra/g, nome); };
  trocar();
  observador?.disconnect();
  if (nome === "Delibra") return;
  const t = document.querySelector("title");
  if (t) { observador = new MutationObserver(trocar); observador.observe(t, { childList: true }); }
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
  const v = m && (m.logo || m.nomeApp) ? m : null;
  atual = v;
  try { if (v) localStorage.setItem(CHAVE, JSON.stringify(v)); else localStorage.removeItem(CHAVE); } catch { /* sem armazenamento */ }
  aplicarFavicon(v?.logo ?? null);
  aplicarTitulo(v);
  ouvintes.forEach((f) => f());
}

export function useMarcaEmpresa(): MarcaEmpresa | null {
  return useSyncExternalStore(
    (f) => { garantir(); ouvintes.add(f); return () => ouvintes.delete(f); },
    () => { garantir(); return atual; },
    () => null,
  );
}
