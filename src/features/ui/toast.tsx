"use client";

import { useEffect, useState } from "react";
import { AlertTriangle, CheckCircle2, Info, X } from "lucide-react";

export type TipoToast = "ok" | "erro" | "info" | "aviso";
interface Item { id: number; texto: string; tipo: TipoToast; titulo?: string; duracao: number }

let seq = 0;
const ouvintes = new Set<(t: Item) => void>();

/** Mostra um aviso rápido no canto da tela (igual ao app). Pode chamar de qualquer lugar. */
export function toast(texto: string, tipo: TipoToast = "ok", opcoes: { titulo?: string; duracao?: number } = {}) {
  const item = { id: ++seq, texto, tipo, titulo: opcoes.titulo, duracao: opcoes.duracao ?? (tipo === "erro" || tipo === "aviso" ? 6000 : 3500) };
  ouvintes.forEach((f) => f(item));
}

const ICONE = { ok: CheckCircle2, erro: AlertTriangle, aviso: AlertTriangle, info: Info };

/** Onde os avisos aparecem. Fica uma vez no layout. */
export function Toasts() {
  const [itens, setItens] = useState<Item[]>([]);
  useEffect(() => {
    const f = (t: Item) => {
      setItens((l) => [...l.slice(-3), t]);
      setTimeout(() => setItens((l) => l.filter((x) => x.id !== t.id)), t.duracao);
    };
    ouvintes.add(f);
    return () => { ouvintes.delete(f); };
  }, []);
  return (
    <div className="toasts" aria-live="polite">
      {itens.map((t) => {
        const Icone = ICONE[t.tipo];
        return (
          <div key={t.id} className={`toast toast-${t.tipo} vidro`} role={t.tipo === "erro" ? "alert" : "status"}>
            <Icone size={18} aria-hidden className="toast-icone" />
            <span className="toast-texto">{t.titulo && <strong>{t.titulo}</strong>}<span>{t.texto}</span></span>
            <button className="toast-fechar" onClick={() => setItens((l) => l.filter((x) => x.id !== t.id))} aria-label="Fechar"><X size={15} /></button>
          </div>
        );
      })}
    </div>
  );
}
