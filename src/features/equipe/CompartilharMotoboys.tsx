"use client";

import { useCallback, useEffect, useState } from "react";
import { Building2, Check, CodeXml, Globe, Handshake, ListChecks, Lock } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

interface Dados {
  permitido: boolean; modo: string; orgs: string[]; padrao_dev: boolean;
  empresas: { id: string; nome: string }[];
  motoboys: { id: string; nome: string; foto: string | null; modo: string; orgs: string[] }[];
}

const DA_EMPRESA: [string, string, LucideIcon][] = [["padrao", "Como o Dev definiu", CodeXml], ["nenhuma", "Nenhuma", Lock], ["todas", "Todas", Globe], ["escolhidas", "Escolher", ListChecks]];
const DO_MOTOBOY: [string, string, LucideIcon][] = [["empresa", "Igual à empresa", Building2], ["nunca", "Nunca", Lock], ["todas", "Todas", Globe], ["escolhidas", "Escolher", ListChecks]];

function Escolha({ opcoes, modo, orgs, empresas, onMudar }: { opcoes: [string, string, LucideIcon][]; modo: string; orgs: string[]; empresas: Dados["empresas"]; onMudar: (m: string, o: string[]) => void }) {
  return (
    <>
      <div className="linha-botoes" role="radiogroup">
        {opcoes.map(([k, r, I]) => <button key={k} type="button" role="radio" aria-checked={modo === k} className={`chip${modo === k ? " ativo" : ""}`} onClick={() => onMudar(k, orgs)}><I size={13} aria-hidden /> {r}</button>)}
      </div>
      {modo === "escolhidas" && (
        <div className="linha-botoes">
          {empresas.length === 0 && <span className="dica">Ainda não há outras empresas na plataforma.</span>}
          {empresas.map((e) => {
            const on = orgs.includes(e.id);
            return <button key={e.id} type="button" className={`chip${on ? " ativo" : ""}`} onClick={() => onMudar(modo, on ? orgs.filter((x) => x !== e.id) : [...orgs, e.id])}>
              {on ? <Check size={13} aria-hidden /> : <Building2 size={13} aria-hidden />} {e.nome}</button>;
          })}
        </div>
      )}
    </>
  );
}

/** Ajustes → Despacho: com quem a empresa compartilha os motoboys (se o Dev deixar), no geral e por motoboy. */
export function CompartilharMotoboys() {
  const [d, setD] = useState<Dados | null>(null);
  const carregar = useCallback(() => { void supabase().rpc("compartilhamento_motoboys").then(({ data }) => data && setD(data as Dados)); }, []);
  useEffect(carregar, [carregar]);
  if (!d) return null;
  async function salvar(modo: string, orgs: string[], motoboy?: string) {
    const { error } = await supabase().rpc("salvar_compartilhamento_motoboys", { p_modo: modo, p_orgs: orgs, p_motoboy: motoboy ?? null });
    if (error) return toast(error.message.includes("compartilhar_desligado") ? "O Dev não liberou compartilhar motoboys." : error.message, "erro");
    toast("Compartilhamento salvo.", "ok"); carregar();
  }
  return (
    <div className="bloco compartilhar-motoboys">
      <span className="rotulo"><Handshake size={12} aria-hidden /> Seus motoboys em outras empresas</span>
      {!d.permitido ? <p className="dica" style={{ margin: 0 }}>O Dev não liberou o compartilhamento de motoboys entre empresas.</p> : <>
        <p className="dica" style={{ margin: 0 }}>Rotas de outras empresas podem chegar aos seus motoboys, sempre depois dos motoboys delas.</p>
        <Escolha opcoes={DA_EMPRESA} modo={d.modo} orgs={d.orgs} empresas={d.empresas} onMudar={(m, o) => salvar(m, o)} />
        {d.modo === "padrao" && <p className="dica" style={{ margin: 0 }}>{d.padrao_dev ? "Hoje: o Dev deixa seus motoboys receberem de outras empresas." : "Hoje: o Dev não manda rotas de outras empresas para seus motoboys."}</p>}
        <details>
          <summary className="dica">Escolha de cada motoboy ({d.motoboys.filter((m) => m.modo !== "empresa").length} diferente{d.motoboys.filter((m) => m.modo !== "empresa").length === 1 ? "" : "s"})</summary>
          {d.motoboys.map((m) => (
            <div key={m.id} className="compartilhar-motoboy">
              <strong>{m.nome}</strong>
              <Escolha opcoes={DO_MOTOBOY} modo={m.modo} orgs={m.orgs} empresas={d.empresas} onMudar={(md, o) => salvar(md, o, m.id)} />
            </div>
          ))}
        </details>
      </>}
    </div>
  );
}
