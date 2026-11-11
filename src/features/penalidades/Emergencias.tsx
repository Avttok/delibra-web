"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { Check, MapPin, Route, Siren } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

type Emergencia = { id: string; motoboy_nome: string; corrida_id: string | null; lat: number | null; lng: number | null; criado_em: string; resolvida_em: string | null };

/** Alertas de emergência abertos: faixa vermelha pulsando no topo do painel até alguém marcar "Resolvido". */
export function EmergenciasAbertas() {
  const [lista, setLista] = useState<Emergencia[]>([]);
  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("emergencias_abertas");
    setLista(((data as Emergencia[] | null) ?? []).filter((e) => !e.resolvida_em));
  }, []);
  useEffect(() => { void carregar(); const t = setInterval(carregar, 10_000); return () => clearInterval(t); }, [carregar]);
  if (!lista.length) return null;
  return (
    <div className="emergencias" role="alert">
      {lista.slice(0, 3).map((e) => (
        <div key={e.id} className="emergencia">
          <Siren size={20} aria-hidden className="emergencia-icone" />
          <div className="emergencia-texto">
            <strong>Emergência · {e.motoboy_nome}</strong>
            <span>Apertou o botão às {new Date(e.criado_em).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })}</span>
          </div>
          <div className="linha-botoes">
            {e.lat != null && e.lng != null && (
              <a className="botao-texto" href={`https://www.google.com/maps?q=${e.lat},${e.lng}`} target="_blank" rel="noreferrer"><MapPin size={15} aria-hidden /> Onde está</a>
            )}
            {e.corrida_id && <Link className="botao-texto" href={`/gestor/corridas?c=${e.corrida_id}`}><Route size={15} aria-hidden /> Rota</Link>}
            <button type="button" className="botao-ouro" onClick={async () => {
              const { error } = await supabase().rpc("resolver_emergencia", { p_id: e.id, p_nota: null });
              if (error) return toast(error.message, "erro");
              toast("Marcado como resolvido.", "ok"); void carregar();
            }}><Check size={15} aria-hidden /> Resolvido</button>
          </div>
        </div>
      ))}
    </div>
  );
}
