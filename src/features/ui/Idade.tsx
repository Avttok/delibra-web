"use client";

import { useEffect, useState } from "react";
import { Hourglass } from "lucide-react";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";

/** "criado há 25 min", e em destaque quando passou do tempo (Ajustes → Pedidos → Avisar se ficar parado). */
export function Idade({ desde, aberto, limiteMin }: { desde: string | null | undefined; aberto: boolean; limiteMin?: number }) {
  const cfg = useConfiguracoes() as unknown as Record<string, unknown>;
  const limite = limiteMin ?? Number(cfg.alerta_parado_min ?? 30);
  const [agora, setAgora] = useState(() => Date.now());
  useEffect(() => { const t = setInterval(() => setAgora(Date.now()), 30_000); return () => clearInterval(t); }, []);
  if (!desde) return null;
  const min = Math.max(0, Math.round((agora - new Date(desde).getTime()) / 60000));
  const txt = min < 1 ? "agora" : min < 60 ? `há ${min} min` : min < 1440 ? `há ${Math.floor(min / 60)} h${min % 60 ? ` ${min % 60} min` : ""}` : `há ${Math.floor(min / 1440)} d`;
  const alerta = aberto && limite > 0 && min >= limite;
  return (
    <span className={`idade${alerta ? " alerta" : ""}`} title={`Criado em ${new Date(desde).toLocaleString("pt-BR")}`}>
      <Hourglass size={11} aria-hidden /> {txt}
    </span>
  );
}
