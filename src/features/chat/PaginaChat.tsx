"use client";

import { useEffect, useState } from "react";
import { useConta } from "@/features/conta/conta";
import { Chat, type Anexo } from "./Chat";

/** Para onde cada cartão do chat leva no painel do gestor. */
function linkDe(a: Anexo): string | null {
  if (!a.id) return null;
  if (a.tipo === "pedido") return `/gestor/pedidos?p=${a.id}`;
  if (a.tipo === "rota") return `/gestor/corridas?c=${a.id}`;
  if (a.tipo === "cliente") return `/gestor/clientes?e=${a.id}`;
  if (a.tipo === "pessoa") return `/gestor/equipe?m=${a.id}`;
  return null;
}

export function PaginaChat() {
  const conta = useConta();
  const [anexo, setAnexo] = useState<Anexo | null>(null);
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("anexo");
    if (q) try { setAnexo(JSON.parse(q) as Anexo); } catch { /* link quebrado */ }
  }, []);
  const limpar = () => { setAnexo(null); const u = new URL(window.location.href); u.searchParams.delete("anexo"); window.history.replaceState(null, "", u); };
  return (
    <main className="conteudo conteudo-chat">
      {conta.id && <Chat meuId={conta.id} gestor={conta.papeis.includes("gestor") || conta.dev} linkDe={linkDe} anexoPendente={anexo} onAnexoEnviado={limpar} />}
    </main>
  );
}

/** Botão "Compartilhar no chat" para qualquer coisa do painel. */
export function BotaoCompartilhar({ anexo, rotulo = "Compartilhar no chat" }: { anexo: Anexo; rotulo?: string }) {
  return (
    <a className="botao-texto" href={`/gestor/chat?anexo=${encodeURIComponent(JSON.stringify(anexo))}`}>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z" /></svg> {rotulo}
    </a>
  );
}
