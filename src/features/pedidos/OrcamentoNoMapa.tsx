"use client";

import { useEffect, useState } from "react";
import { MapaCorridas, type PinoParada } from "@/features/corridas/MapaCorridas";
import { codificarPolyline, geo } from "@/features/geo";

type Ponto = { id: string; tipo: "coleta" | "entrega"; lat: number; lng: number };

/**
 * "Como chegou no valor" no mapa (igual ao app): da coleta até cada entrega, pelo caminho
 * das ruas (padrão) ou em linha reta quando o gestor escolheu assim, com o valor de cada uma.
 */
export function OrcamentoNoMapa({ pontos, linhas, trajeto }: {
  pontos: Ponto[]; linhas: { chave?: string; valor?: number }[]; trajeto?: string | null;
}) {
  const reta = trajeto === "reta";
  const coleta = pontos.find((p) => p.tipo === "coleta");
  const entregas = pontos.filter((p) => p.tipo === "entrega");
  const chave = pontos.map((p) => `${p.lat},${p.lng}`).join(";") + (reta ? "r" : "");
  const [rotas, setRotas] = useState<string[]>([]);
  useEffect(() => {
    if (!coleta) return;
    let vivo = true;
    const retas = entregas.map((e) => codificarPolyline([[coleta.lat, coleta.lng], [e.lat, e.lng]]));
    setRotas(retas);
    if (reta) return;
    void Promise.all(entregas.map((e, i) => geo.calcularRota([{ lat: coleta.lat, lng: coleta.lng }, { lat: e.lat, lng: e.lng }])
      .then((r) => r?.polyline ?? retas[i]).catch(() => retas[i]))).then((p) => { if (vivo) setRotas(p); });
    return () => { vivo = false; };
  }, [chave]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!coleta) return null;
  const valor = (i: number) => linhas.find((l) => l.chave === `entrega_${i + 1}`)?.valor;
  const pinos: PinoParada[] = [
    { chave: coleta.id, lat: coleta.lat, lng: coleta.lng, tipo: "coleta", rotulo: "1" },
    ...entregas.map((e, i) => ({ chave: e.id, lat: e.lat, lng: e.lng, tipo: "entrega" as const, rotulo: String(i + 2) })),
  ];
  return (
    <div className="orcamento-mapa">
      <div className="orcamento-mapa-caixa"><MapaCorridas paradas={pinos} rotas={rotas} caminhoAuto={false} legenda={false} enquadrar={chave} /></div>
      <p className="dica" style={{ margin: 0 }}>{reta ? "Linha reta da coleta até cada entrega (ajuste do gestor)." : "O caminho pelas ruas da coleta até cada entrega."}</p>
      {entregas.some((_, i) => valor(i) != null) && (
        <ul className="orcamento-mapa-lista">
          {entregas.map((e, i) => valor(i) != null && <li key={e.id}><span className="orcamento-mapa-n">{i + 2}</span> Entrega {i + 1}<strong>{valor(i)!.toLocaleString("pt-BR", { style: "currency", currency: "BRL" })}</strong></li>)}
        </ul>
      )}
    </div>
  );
}
