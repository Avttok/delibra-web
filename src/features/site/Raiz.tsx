"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase/client";
import { AreaCliente } from "@/features/cliente/AreaCliente";
import { PainelCliente } from "@/features/cliente/PainelCliente";
import { Landing } from "./Landing";

/** Início: quem já entrou vê o painel; quem não entrou vê a apresentação da Delibra. */
export function Raiz() {
  const [logado, setLogado] = useState<boolean | null>(null);
  useEffect(() => {
    const sb = supabase();
    sb.auth.getSession().then(({ data }) => setLogado(Boolean(data.session)));
    const { data } = sb.auth.onAuthStateChange((_e, s) => setLogado(Boolean(s)));
    return () => data.subscription.unsubscribe();
  }, []);
  if (logado === null) return <main className="tela-login"><p className="subtitulo">Carregando…</p></main>;
  if (!logado) return <Landing />;
  return <AreaCliente><PainelCliente /></AreaCliente>;
}
