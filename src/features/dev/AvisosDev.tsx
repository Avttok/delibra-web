"use client";

import { useEffect, useState } from "react";
import { Info, Megaphone, TriangleAlert, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";

interface Aviso { id: string; texto: string; nivel: "info" | "aviso" | "urgente"; ate: string | null }

/** Faixa com os avisos que o Dev mandou para esta pessoa (por empresa e por cargo). Fecha só nesta sessão. */
export function AvisosDev() {
  const [avisos, setAvisos] = useState<Aviso[]>([]);
  const [fechados, setFechados] = useState<string[]>(() => {
    try { return JSON.parse(sessionStorage.getItem("pwex_avisos_fechados") ?? "[]"); } catch { return []; }
  });
  useEffect(() => {
    const ler = () => void supabase().rpc("avisos_para_mim").then(({ data }) => setAvisos((data ?? []) as Aviso[]));
    ler();
    const t = setInterval(ler, 60_000);
    return () => clearInterval(t);
  }, []);
  const fechar = (id: string) => {
    const n = [...fechados, id];
    setFechados(n);
    try { sessionStorage.setItem("pwex_avisos_fechados", JSON.stringify(n)); } catch { /* sem armazenamento */ }
  };
  const lista = avisos.filter((a) => a.nivel === "urgente" || !fechados.includes(a.id));
  if (!lista.length) return null;
  return (
    <div className="avisos-dev" role="status">
      {lista.map((a) => {
        const I = a.nivel === "urgente" ? TriangleAlert : a.nivel === "aviso" ? Megaphone : Info;
        return (
          <div key={a.id} className={`aviso-dev ${a.nivel}`}>
            <I size={16} aria-hidden />
            <span>{a.texto}</span>
            {a.nivel !== "urgente" && <button type="button" className="botao-icone" aria-label="Fechar aviso" onClick={() => fechar(a.id)}><X size={14} aria-hidden /></button>}
          </div>
        );
      })}
    </div>
  );
}

interface Novidade { id: string; versao: string; area: string; titulo: string; texto: string | null; em: string }
const ROTULO_AREA: Record<string, string> = { todos: "Para todos", motoboy: "Motoboy", gestor: "Gestor", supervisor: "Supervisor", cliente: "Cliente", dev: "Dev" };

/** "O que mudou": cada pessoa vê só as novidades das áreas dela (o servidor filtra). */
export function BotaoNovidades() {
  const [aberto, setAberto] = useState(false);
  const [lista, setLista] = useState<Novidade[] | null>(null);
  useEffect(() => {
    if (!aberto || lista) return;
    void supabase().rpc("minhas_novidades", { p_limite: 60 }).then(({ data }) => setLista((data ?? []) as Novidade[]));
  }, [aberto, lista]);
  const versoes = [...new Set((lista ?? []).map((n) => n.versao))];
  return (
    <>
      <button type="button" className="botao-texto" onClick={() => setAberto(true)} title="O que mudou"><Megaphone size={16} aria-hidden /> <span className="so-largo">Novidades</span></button>
      {aberto && (
        <div className="modal-fundo" onClick={() => setAberto(false)}>
          <div className="modal vidro novidades-modal" role="dialog" aria-label="Novidades" onClick={(e) => e.stopPropagation()}>
            <div className="modal-cabeca"><strong>O que mudou</strong><button className="botao-icone" aria-label="Fechar" onClick={() => setAberto(false)}><X size={16} aria-hidden /></button></div>
            {!lista ? <p className="dica">Carregando…</p> : !lista.length ? <p className="vazio">Nada novo por aqui.</p> : versoes.map((v) => (
              <section key={v} className="novidades-versao">
                <span className="rotulo">{v}</span>
                {lista.filter((n) => n.versao === v).map((n) => (
                  <div key={n.id} className="novidade">
                    <strong>{n.titulo}</strong> {n.area !== "todos" && <span className="chip">{ROTULO_AREA[n.area] ?? n.area}</span>}
                    {n.texto && <p className="dica">{n.texto}</p>}
                  </div>
                ))}
              </section>
            ))}
          </div>
        </div>
      )}
    </>
  );
}
