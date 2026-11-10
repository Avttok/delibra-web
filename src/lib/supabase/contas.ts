"use client";

import { useSyncExternalStore } from "react";

/**
 * "Permanecer conectado" e "Logar com" (mesmo comportamento do app do motoboy).
 *
 * - Com "permanecer" ligado, a sessão fica no localStorage e a conta guarda o token de renovação,
 *   para entrar de novo com um toque.
 * - Desligado, a sessão fica no sessionStorage (termina ao fechar o navegador) e a conta aparece
 *   na lista só com o e-mail preenchido.
 */

export type ContaSalva = { email: string; nome?: string | null; foto?: string | null; token?: string | null; usadaEm: number };

const CHAVE_CONTAS = "pwex-contas";
const CHAVE_PERMANECER = "pwex-permanecer";

function seguro<T>(f: () => T, padrao: T): T {
  try { return f(); } catch { return padrao; }
}

// ------------------------------------------------------------ permanecer conectado

export function permanecer(): boolean {
  return seguro(() => localStorage.getItem(CHAVE_PERMANECER) !== "0", true);
}

export function definirPermanecer(sim: boolean) {
  seguro(() => localStorage.setItem(CHAVE_PERMANECER, sim ? "1" : "0"), undefined);
}

/** Armazenamento da sessão do Supabase: localStorage ou sessionStorage, conforme a escolha. */
export const armazenamentoSessao = {
  getItem: (k: string) => seguro(() => localStorage.getItem(k) ?? sessionStorage.getItem(k), null),
  setItem: (k: string, v: string) => seguro(() => {
    if (permanecer()) { localStorage.setItem(k, v); sessionStorage.removeItem(k); }
    else { sessionStorage.setItem(k, v); localStorage.removeItem(k); }
  }, undefined),
  removeItem: (k: string) => seguro(() => { localStorage.removeItem(k); sessionStorage.removeItem(k); }, undefined),
};

// ------------------------------------------------------------ contas salvas

const ouvintes = new Set<() => void>();
let cache: ContaSalva[] | null = null;

function ler(): ContaSalva[] {
  if (cache) return cache;
  cache = seguro(() => {
    const v = JSON.parse(localStorage.getItem(CHAVE_CONTAS) ?? "[]");
    return Array.isArray(v) ? (v as ContaSalva[]) : [];
  }, []);
  return cache;
}

function gravar(lista: ContaSalva[]) {
  cache = [...lista].sort((a, b) => b.usadaEm - a.usadaEm).slice(0, 8);
  seguro(() => localStorage.setItem(CHAVE_CONTAS, JSON.stringify(cache)), undefined);
  ouvintes.forEach((f) => f());
}

const igual = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

export const contas = {
  listar: ler,

  /** Depois de entrar: põe a conta no topo e guarda (ou esquece) o token. */
  lembrar(email: string, token: string | null) {
    const atual = ler().find((c) => igual(c.email, email));
    gravar([
      { ...atual, email, token: permanecer() ? token : null, usadaEm: Date.now() },
      ...ler().filter((c) => !igual(c.email, email)),
    ]);
  },

  /** O Supabase troca o token de tempos em tempos: mantém o salvo atualizado. */
  atualizarToken(email: string, token: string) {
    if (!permanecer()) return;
    gravar(ler().map((c) => (igual(c.email, email) ? { ...c, token } : c)));
  },

  atualizarPerfil(email: string, nome: string | null, foto: string | null) {
    const atual = ler().find((c) => igual(c.email, email));
    if (!atual || (atual.nome === nome && atual.foto === foto)) return;
    gravar(ler().map((c) => (igual(c.email, email) ? { ...c, nome, foto } : c)));
  },

  esquecerToken(email: string) {
    gravar(ler().map((c) => (igual(c.email, email) ? { ...c, token: null } : c)));
  },

  remover(email: string) {
    gravar(ler().filter((c) => !igual(c.email, email)));
  },
};

const VAZIO: ContaSalva[] = [];

/** Lista reativa para componentes React. */
export function useContasSalvas(): ContaSalva[] {
  return useSyncExternalStore(
    (f) => { ouvintes.add(f); return () => { ouvintes.delete(f); }; },
    ler,
    () => VAZIO,
  );
}
