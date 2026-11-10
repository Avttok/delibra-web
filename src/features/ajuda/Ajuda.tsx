"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Bike, Building2, Search, ShieldCheck } from "lucide-react";
import { AJUDA, PUBLICOS, type Artigo, type Publico } from "./ajuda";
import type { ReactNode } from "react";

const ICONE = { cliente: Building2, motoboy: Bike, gestor: ShieldCheck } as const;
const sem = (t: string) => t.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Central de ajuda: (se houver mais de um público) escolha para quem é, busque, abra o artigo. /ajuda?p=…&a=… abre direto. */
export function CentralAjuda({ publicos, topo, rodape, lead }: { publicos: Publico[]; topo: ReactNode; rodape: ReactNode; lead: string }) {
  const [publico, setPublico] = useState<Publico>(publicos[0]);
  const [aberto, setAberto] = useState<string | null>(null);
  const [busca, setBusca] = useState("");
  const alvo = useRef<HTMLDetailsElement | null>(null);

  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    const p = q.get("p") as Publico | null;
    if (p && publicos.includes(p) && AJUDA[p]) setPublico(p);
    const a = q.get("a");
    if (a) { setAberto(a); setTimeout(() => alvo.current?.scrollIntoView({ behavior: "smooth", block: "start" }), 120); }
  }, []);

  function trocar(p: Publico) {
    setPublico(p); setAberto(null);
    const u = new URL(window.location.href); u.searchParams.set("p", p); u.searchParams.delete("a");
    window.history.replaceState(null, "", u);
  }

  const termo = sem(busca.trim());
  const secoes = useMemo(() => (AJUDA[publico] ?? []).map((s) => ({
    ...s,
    artigos: s.artigos.filter((a) => !termo || termo.split(/\s+/).every((w) => sem(`${a.titulo} ${a.texto.join(" ")}`).includes(w))),
  })).filter((s) => s.artigos.length > 0), [publico, termo]);

  return (
    <div className="lp">
      {topo}
      <section className="lp-secao aj-cabeca">
        <h1>Central de ajuda</h1>
        <p className="lp-lead">{lead}</p>
        {publicos.length > 1 && <div className="aj-publicos" role="tablist" aria-label="Para quem">
          {PUBLICOS.filter((p) => publicos.includes(p.k)).map((p) => {
            const I = ICONE[p.k];
            return (
              <button key={p.k} role="tab" aria-selected={publico === p.k} className={publico === p.k ? "ativo" : ""} onClick={() => trocar(p.k)}>
                <I size={20} aria-hidden /><span><strong>{p.nome}</strong><small>{p.resumo}</small></span>
              </button>
            );
          })}
        </div>}
        <label className="aj-busca"><Search size={16} aria-hidden /><input placeholder="Buscar na ajuda" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
      </section>

      <section className="lp-secao aj-corpo">
        {secoes.length === 0 && <p className="lp-lead">Nada encontrado para “{busca}”. Tente outra palavra.</p>}
        {secoes.map((s) => (
          <div key={s.titulo} className="aj-secao">
            <h2>{s.titulo}</h2>
            {s.artigos.map((a) => (
              <details key={a.id} id={a.id} open={aberto === a.id || Boolean(termo)} ref={aberto === a.id ? alvo : undefined}
                onToggle={(e) => { if ((e.target as HTMLDetailsElement).open) setAberto(a.id); }}>
                <summary>{a.titulo}</summary>
                <Texto artigo={a} />
              </details>
            ))}
          </div>
        ))}
      </section>
      {rodape}
    </div>
  );
}

function Texto({ artigo }: { artigo: Artigo }) {
  const blocos: { passos?: string[]; p?: string }[] = [];
  for (const t of artigo.texto) {
    const m = /^\d+\.\s+(.*)$/.exec(t);
    if (m) { const ult = blocos[blocos.length - 1]; if (ult?.passos) ult.passos.push(m[1]); else blocos.push({ passos: [m[1]] }); }
    else blocos.push({ p: t });
  }
  return (
    <div className="aj-texto">
      {blocos.map((b, i) => b.passos ? <ol key={i}>{b.passos.map((x, j) => <li key={j}>{x}</li>)}</ol> : <p key={i}>{b.p}</p>)}
    </div>
  );
}
