"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase/client";

export type PreferenciaTema = "claro" | "escuro" | "sistema";
export type Tema = "claro" | "escuro";

const CHAVE = "pwex-tema";
const CHAVE_ESTILO = "pwex-estilo";

/** Cores que qualquer pessoa escolhe (as mesmas do app). Os dois "preto/branco" fixam claro ou noturno. */
export type Estilo = "ouro" | "azul" | "verde" | "pnb" | "bnp";
export const ESTILOS: { k: Estilo; rotulo: string; cor: string; fundo: string }[] = [
  { k: "ouro", rotulo: "Dourado", cor: "#d4af37", fundo: "#0f0f12" },
  { k: "azul", rotulo: "Azul", cor: "#3b82f6", fundo: "#0f0f12" },
  { k: "verde", rotulo: "Verde", cor: "#10b981", fundo: "#0f0f12" },
  { k: "pnb", rotulo: "Preto no branco", cor: "#111111", fundo: "#ffffff" },
  { k: "bnp", rotulo: "Branco no preto", cor: "#ffffff", fundo: "#000000" },
];

/** Roda antes da página aparecer (no <head>), para não piscar o tema errado. */
export const scriptTema = `(function(){try{var p=localStorage.getItem('${CHAVE}')||'sistema';var e=localStorage.getItem('${CHAVE_ESTILO}')||'ouro';var t=p==='sistema'?(matchMedia('(prefers-color-scheme: dark)').matches?'escuro':'claro'):p;if(e==='pnb')t='claro';if(e==='bnp')t='escuro';document.documentElement.dataset.tema=t;if(e!=='ouro')document.documentElement.dataset.estilo=e;}catch(x){document.documentElement.dataset.tema='escuro';}})();`;

interface ContextoTema {
  preferencia: PreferenciaTema;
  tema: Tema;
  definir: (p: PreferenciaTema) => void;
  alternar: () => void;
  estilo: Estilo;
  definirEstilo: (e: Estilo) => void;
}

const Contexto = createContext<ContextoTema>({ preferencia: "sistema", tema: "escuro", definir: () => {}, alternar: () => {}, estilo: "ouro", definirEstilo: () => {} });
export const useTema = () => useContext(Contexto);

function resolver(p: PreferenciaTema): Tema {
  if (p !== "sistema") return p;
  return typeof window !== "undefined" && window.matchMedia("(prefers-color-scheme: dark)").matches ? "escuro" : "claro";
}

export function ProvedorTema({ children }: { children: ReactNode }) {
  const [preferencia, setPreferencia] = useState<PreferenciaTema>("sistema");
  const [tema, setTema] = useState<Tema>("escuro");
  const [estilo, setEstilo] = useState<Estilo>("ouro");

  useEffect(() => {
    let p: PreferenciaTema = "sistema";
    try { p = (localStorage.getItem(CHAVE) as PreferenciaTema) || "sistema"; } catch {}
    setPreferencia(p);
    setTema(resolver(p));
    try { setEstilo((localStorage.getItem(CHAVE_ESTILO) as Estilo) || "ouro"); } catch {}
  }, []);

  // acompanha o sistema quando a preferência é "sistema"
  useEffect(() => {
    if (preferencia !== "sistema") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const aoMudar = () => setTema(mq.matches ? "escuro" : "claro");
    mq.addEventListener("change", aoMudar);
    return () => mq.removeEventListener("change", aoMudar);
  }, [preferencia]);

  useEffect(() => {
    document.documentElement.dataset.tema = estilo === "pnb" ? "claro" : estilo === "bnp" ? "escuro" : tema;
    if (estilo === "ouro") delete document.documentElement.dataset.estilo; else document.documentElement.dataset.estilo = estilo;
  }, [tema, estilo]);

  // ---------------------------------------------------------------- tema da pessoa: o mesmo no app e no site
  const envio = useRef<ReturnType<typeof setTimeout> | null>(null);
  const atual = useRef({ preferencia: "sistema" as PreferenciaTema, estilo: "ouro" as Estilo });
  const enviar = useCallback(() => {
    if (envio.current) clearTimeout(envio.current);
    envio.current = setTimeout(async () => {
      envio.current = null;
      try {
        const sb = supabase();
        const { data } = await sb.auth.getSession();
        if (!data.session) return;
        let barra = true; try { barra = localStorage.getItem("pwex_numero_barra") !== "0"; } catch {}
        await sb.rpc("salvar_meu_tema", { p: { preferencia: atual.current.preferencia, estilo: atual.current.estilo, numero_barra: barra } });
      } catch { /* sem conexão: fica só neste navegador */ }
    }, 1200);
  }, []);

  const definirEstilo = useCallback((e: Estilo, mandar = true) => {
    try { localStorage.setItem(CHAVE_ESTILO, e); } catch {}
    setEstilo(e); atual.current.estilo = e;
    if (mandar) enviar();
  }, [enviar]);

  const definir = useCallback((p: PreferenciaTema, mandar = true) => {
    try { localStorage.setItem(CHAVE, p); } catch {}
    setPreferencia(p); atual.current.preferencia = p;
    setTema(resolver(p));
    if (mandar) enviar();
  }, [enviar]);

  // ao entrar: o que a conta tem salvo vale aqui (conta sem tema recebe o deste navegador)
  useEffect(() => {
    let sb: ReturnType<typeof supabase>;
    try { sb = supabase(); } catch { return; }
    const aplicar = async (uid: string | undefined) => {
      if (!uid || envio.current) return;
      const { data } = await sb.from("perfis").select("tema").eq("id", uid).maybeSingle();
      const t = (data?.tema ?? {}) as { preferencia?: string; estilo?: string; numero_barra?: boolean };
      if (!Object.keys(t).length) { enviar(); return; }
      if (t.preferencia === "claro" || t.preferencia === "escuro" || t.preferencia === "sistema") definir(t.preferencia, false);
      if (t.estilo && ESTILOS.some((e) => e.k === t.estilo)) definirEstilo(t.estilo as Estilo, false);
      if (typeof t.numero_barra === "boolean") {
        try { localStorage.setItem("pwex_numero_barra", t.numero_barra ? "1" : "0"); } catch {}
        window.dispatchEvent(new CustomEvent("pwex-numero-modo", { detail: t.numero_barra }));
      }
    };
    void sb.auth.getSession().then(({ data }) => aplicar(data.session?.user.id));
    const aoNumero = () => enviar();
    window.addEventListener("pwex-tema-mudou", aoNumero);
    const { data: sub } = sb.auth.onAuthStateChange((ev, s) => { if (ev === "SIGNED_IN") void aplicar(s?.user.id); });
    return () => { sub.subscription.unsubscribe(); window.removeEventListener("pwex-tema-mudou", aoNumero); };
  }, [definir, definirEstilo, enviar]);

  // ciclo: sistema → claro → escuro → sistema
  const alternar = useCallback(() => {
    definir(preferencia === "sistema" ? "claro" : preferencia === "claro" ? "escuro" : "sistema");
  }, [preferencia, definir]);

  return <Contexto.Provider value={{ preferencia, tema: estilo === "pnb" ? "claro" : estilo === "bnp" ? "escuro" : tema, definir, alternar, estilo, definirEstilo }}>{children}</Contexto.Provider>;
}
