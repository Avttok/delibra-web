"use client";

import { useEffect, useState, type ReactNode } from "react";
import { supabase } from "@/lib/supabase/client";

/** O que `chat_cartao` devolve: o estado atual do que foi compartilhado (o mesmo do app). */
type Info = {
  titulo?: string; sub?: string | null; status?: string | null; resumo?: boolean; sem_acesso?: boolean; oculto?: boolean;
  linhas?: { icone?: string; rotulo: string; valor: string }[];
};

const cache = new Map<string, { em: number; info: Info | null }>();

async function buscar(tipo: string, id: string): Promise<Info | null> {
  const k = `${tipo}:${id}`;
  const c = cache.get(k);
  if (c && Date.now() - c.em < 60_000) return c.info;
  const { data } = await supabase().rpc("chat_cartao", { p_tipo: tipo, p_id: id });
  const info = (data as Info | null) ?? null;
  cache.set(k, { em: Date.now(), info });
  return info;
}

/**
 * Cartão compartilhado no chat com o que está acontecendo agora (status, motoboy, entregas…).
 * O motoboy vê o resumo; quem não tem acesso vê só o título. Sem resposta, fica o cartão simples.
 */
export function CartaoChatRico({ tipo, id, simples }: { tipo: string; id?: string | null; simples: ReactNode }) {
  const [info, setInfo] = useState<Info | null | undefined>(undefined);
  const rico = !!id && ["pedido", "rota", "corrida", "cliente", "pessoa"].includes(tipo);
  useEffect(() => {
    if (!rico || !id) return;
    let vivo = true;
    void buscar(tipo === "corrida" ? "rota" : tipo, id).then((i) => { if (vivo) setInfo(i); });
    return () => { vivo = false; };
  }, [rico, tipo, id]);
  if (!rico || !info || info.sem_acesso) return <>{simples}</>;
  return (
    <div className="chat-cartao-rico">
      {simples}
      {(info.status || (info.linhas?.length ?? 0) > 0) && (
        <div className="chat-cartao-detalhe">
          {info.status && <span className="chat-cartao-status">{info.status}</span>}
          {info.linhas?.slice(0, 5).map((l, i) => (
            <div key={i} className="chat-cartao-linha"><span>{l.rotulo}</span><strong>{l.valor}</strong></div>
          ))}
          {info.resumo && <small className="chat-cartao-resumo">Resumo para o motoboy</small>}
        </div>
      )}
    </div>
  );
}
