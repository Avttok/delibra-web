"use client";

import { useEffect, useState } from "react";
import { LocateFixed, MapPin, Package, Star } from "lucide-react";

export type EmpresaCard = { slug: string; nome: string; logo: string | null; cor: string | null; modo: string; nota: number | null; avaliacoes: number; entregas: number; lat?: number | null; lng?: number | null };

function km(a: { lat: number; lng: number }, b: { lat: number; lng: number }) {
  const r = (x: number) => (x * Math.PI) / 180, R = 6371;
  const d = Math.sin(r(b.lat - a.lat) / 2) ** 2 + Math.cos(r(a.lat)) * Math.cos(r(b.lat)) * Math.sin(r(b.lng - a.lng) / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(d));
}

/** Onde a pessoa está (só se ela deixar), para mostrar a distância até a área de cada transportadora. */
export function usePosicao() {
  const [pos, setPos] = useState<{ lat: number; lng: number } | null>(null);
  const [pedido, setPedido] = useState(false);
  const pedir = () => {
    setPedido(true);
    navigator.geolocation?.getCurrentPosition((p) => setPos({ lat: p.coords.latitude, lng: p.coords.longitude }), () => setPedido(false), { timeout: 8000, maximumAge: 600_000 });
  };
  useEffect(() => {
    // já liberou antes: mostra direto, sem perguntar de novo
    void navigator.permissions?.query({ name: "geolocation" as PermissionName }).then((s) => { if (s.state === "granted") pedir(); }).catch(() => null);
  }, []);
  return { pos, pedir, pedido };
}

/** Cards das transportadoras: nota, entregas, como entra e a distância até a área de atuação. */
export function EmpresasCards({ empresas, onEscolher, ordenarPorPerto = true }: { empresas: EmpresaCard[]; onEscolher: (slug: string) => void; ordenarPorPerto?: boolean }) {
  const { pos, pedir, pedido } = usePosicao();
  const dist = (e: EmpresaCard) => (pos && e.lat != null && e.lng != null ? km(pos, { lat: Number(e.lat), lng: Number(e.lng) }) : null);
  const lista = pos && ordenarPorPerto ? [...empresas].sort((a, b) => (dist(a) ?? 1e9) - (dist(b) ?? 1e9)) : empresas;
  return (
    <>
      {!pos && empresas.some((e) => e.lat != null) && (
        <button type="button" className="botao-texto" onClick={pedir} disabled={pedido} style={{ justifySelf: "start" }}>
          <LocateFixed size={15} aria-hidden /> {pedido ? "Procurando você…" : "Mostrar as mais perto de mim"}
        </button>
      )}
      <div className="empresas-cards">
        {lista.map((e) => {
          const d = dist(e);
          return (
            <button key={e.slug} type="button" className="empresa-card vidro" style={{ ["--cor-empresa" as string]: e.cor ?? "var(--ouro)" }} onClick={() => onEscolher(e.slug)}>
              <span className="empresa-card-logo" style={{ backgroundImage: e.logo ? `url("${e.logo}")` : undefined }}>{!e.logo && e.nome.charAt(0)}</span>
              <strong>{e.nome}</strong>
              <span className="empresa-card-numeros">
                {e.nota != null ? <span><Star size={13} aria-hidden /> {e.nota.toLocaleString("pt-BR")} <small>({e.avaliacoes})</small></span> : <span className="dica">Sem avaliações ainda</span>}
                {e.entregas > 0 && <span><Package size={13} aria-hidden /> {e.entregas.toLocaleString("pt-BR")} entregas</span>}
                {d != null && <span className="empresa-card-dist"><MapPin size={13} aria-hidden /> {d < 1 ? "Atende aqui perto" : `a ${d < 10 ? d.toFixed(1).replace(".", ",") : Math.round(d)} km`}</span>}
              </span>
              <span className="dica">{e.modo === "instantaneo" ? "Conta liberada na hora" : "A empresa aprova seu cadastro"}</span>
            </button>
          );
        })}
      </div>
    </>
  );
}
