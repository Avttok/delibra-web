"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { AtSign, Building2, Check, Copy, KeyRound, Plus, Smartphone, Star, Trash2, UserRound } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { formatarPix, lerPix, normalizarPix, ROTULO_PIX, type TipoPix } from "@/lib/pix/identificar";
import { useConta } from "@/features/conta/conta";
import { toast } from "@/features/ui/toast";

export interface ChavePix { id: string; usuario_id: string; tipo_chave: string; chave: string; titular: string; principal: boolean; criado_em: string }

const ICONE = { cpf: UserRound, cnpj: Building2, telefone: Smartphone, email: AtSign, aleatoria: KeyRound } as const;
export function IconePix({ tipo, size = 15 }: { tipo: string; size?: number }) {
  const I = ICONE[tipo as TipoPix] ?? KeyRound;
  return <I size={size} aria-hidden />;
}

const ERROS: Record<string, string> = {
  chave_repetida: "Essa chave já está cadastrada.",
  chave_invalida: "A chave não confere com o tipo.",
  titular_invalido: "Informe o nome do titular.",
  tipo_invalido: "Tipo de chave inválido.",
};

/** Todas as chaves PIX que a conta pode ver (a própria; gestor e Dev veem as de todos). */
export function useChavesPix() {
  const [chaves, setChaves] = useState<ChavePix[]>([]);
  const recarregar = useCallback(async () => {
    const { data } = await supabase().from("chaves_pix").select("*").order("principal", { ascending: false }).order("criado_em");
    setChaves((data ?? []) as ChavePix[]);
  }, []);
  useEffect(() => { void recarregar(); }, [recarregar]);
  return { chaves, recarregar };
}

const copiar = (t: string) => { navigator.clipboard?.writeText(t); toast("Chave PIX copiada.", "ok"); };

/** Minhas chaves PIX: adicionar quantas quiser (tipo reconhecido sozinho), escolher a principal, remover. */
export function MinhasChavesPix({ chaves, onMudou, meuNome }: { chaves: ChavePix[]; onMudou: () => void; meuNome?: string }) {
  const { id: eu } = useConta();
  const minhas = chaves.filter((c) => c.usuario_id === eu);
  const [aberto, setAberto] = useState(false);
  const [entrada, setEntrada] = useState("");
  const [titular, setTitular] = useState("");
  const [escolhido, setEscolhido] = useState<TipoPix | null>(null);
  const [salvando, setSalvando] = useState(false);
  const leitura = useMemo(() => lerPix(entrada), [entrada]);
  const tipo = escolhido && leitura.tipos.includes(escolhido) ? escolhido : leitura.tipos[0];

  useEffect(() => { if (aberto && !titular && meuNome) setTitular(meuNome); }, [aberto, titular, meuNome]);

  async function rpc(nome: string, args: Record<string, unknown>, ok?: string) {
    const { error } = await supabase().rpc(nome, args);
    if (error) { toast(ERROS[error.message] ?? error.message, "erro"); return false; }
    if (ok) toast(ok, "ok");
    onMudou();
    return true;
  }

  async function adicionar() {
    if (!tipo) return;
    setSalvando(true);
    const ok = await rpc("adicionar_chave_pix", { p_tipo: tipo, p_chave: normalizarPix(entrada, tipo), p_titular: titular.trim() }, `${ROTULO_PIX[tipo]} cadastrado.`);
    setSalvando(false);
    if (ok) { setEntrada(""); setEscolhido(null); setAberto(false); }
  }

  return (
    <div className="bloco">
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span className="rotulo" style={{ flex: 1 }}><KeyRound size={12} aria-hidden /> Minhas chaves PIX</span>
        {!aberto && <button className="botao-texto" onClick={() => setAberto(true)}><Plus size={15} aria-hidden /> Adicionar</button>}
      </div>
      {minhas.length === 0 && !aberto && <p className="dica" style={{ margin: 0 }}>Cadastre a chave para onde a sua parte vai quando a corrida terminar.</p>}
      {minhas.map((c) => (
        <div key={c.id} className={`linha-pix ${c.principal ? "principal" : ""}`}>
          <span className="linha-pix-icone"><IconePix tipo={c.tipo_chave} /></span>
          <span className="linha-pix-texto">
            <small>{ROTULO_PIX[c.tipo_chave as TipoPix] ?? c.tipo_chave}{c.principal && <span className="selo" style={{ color: "var(--ouro)", marginLeft: 6 }}><Star size={10} aria-hidden /> Principal</span>}</small>
            <strong>{formatarPix(c.chave, c.tipo_chave)}</strong>
            <small>{c.titular}</small>
          </span>
          {!c.principal && <button className="botao-icone" title="Tornar principal" onClick={() => rpc("definir_chave_pix_principal", { p_id: c.id }, "Repasses vão para esta chave.")}><Star size={15} /></button>}
          <button className="botao-icone" title="Copiar" onClick={() => copiar(c.chave)}><Copy size={15} /></button>
          <button className="botao-icone" title="Remover" onClick={() => confirm(`Remover a chave ${formatarPix(c.chave, c.tipo_chave)}?`) && rpc("remover_chave_pix", { p_id: c.id }, "Chave removida.")}><Trash2 size={15} /></button>
        </div>
      ))}

      {aberto && (
        <div className="nova-pix">
          <label className="campo"><span>Chave</span>
            <input value={entrada} autoFocus placeholder="CPF, CNPJ, celular, e-mail ou aleatória" onChange={(e) => { setEntrada(e.target.value); setEscolhido(null); }} /></label>
          {!entrada.trim() ? <p className="dica" style={{ margin: 0 }}>O tipo é reconhecido sozinho.</p>
            : leitura.erro ? <p className="erro" style={{ margin: 0 }}>{leitura.erro}</p>
            : leitura.tipos.length > 1 ? (
              <div style={{ display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" }}>
                <span className="dica">Serve como CPF e como celular. Qual é?</span>
                {leitura.tipos.map((t) => <button key={t} type="button" className={`chip ${t === tipo ? "ativo" : ""}`} onClick={() => setEscolhido(t)}><IconePix tipo={t} size={13} /> {ROTULO_PIX[t]}</button>)}
              </div>
            ) : tipo && <p className="dica" style={{ margin: 0, color: "var(--verde)" }}><IconePix tipo={tipo} size={13} /> {ROTULO_PIX[tipo]} · {formatarPix(normalizarPix(entrada, tipo), tipo)}</p>}
          <label className="campo"><span>Nome do titular</span><input value={titular} onChange={(e) => setTitular(e.target.value)} /></label>
          <div style={{ display: "flex", gap: 8 }}>
            <button className="botao-ouro" disabled={!tipo || titular.trim().length < 3 || salvando} onClick={adicionar}><Check size={16} aria-hidden /> {salvando ? "Salvando…" : "Adicionar chave"}</button>
            <button className="botao-texto" onClick={() => { setAberto(false); setEntrada(""); }}>Cancelar</button>
          </div>
        </div>
      )}
    </div>
  );
}

/** Chaves da equipe (gestor e Dev): todas as chaves de cada pessoa, a principal em destaque. */
export function ChavesEquipe({ chaves, nome }: { chaves: ChavePix[]; nome: (id: string) => string }) {
  const { id: eu } = useConta();
  const porPessoa = useMemo(() => {
    const m = new Map<string, ChavePix[]>();
    for (const c of chaves) if (c.usuario_id !== eu) m.set(c.usuario_id, [...(m.get(c.usuario_id) ?? []), c]);
    return [...m.entries()].sort((a, b) => nome(a[0]).localeCompare(nome(b[0])));
  }, [chaves, eu, nome]);
  if (porPessoa.length === 0) return <p className="dica">Ninguém da equipe cadastrou chave PIX ainda.</p>;
  return (
    <div className="pix-equipe">
      {porPessoa.map(([id, cs]) => (
        <div key={id} className="pix-pessoa">
          <span className="pix-nome">{nome(id)}</span>
          <div className="pix-chaves">{cs.map((c) => (
            <button key={c.id} type="button" className={`pix-chave ${c.principal ? "principal" : ""}`} onClick={() => copiar(c.chave)} title={`${c.titular} · ${ROTULO_PIX[c.tipo_chave as TipoPix] ?? c.tipo_chave} · toque para copiar`}>
              <IconePix tipo={c.tipo_chave} size={14} />
              <span className="pix-texto"><strong>{formatarPix(c.chave, c.tipo_chave)}</strong><small>{ROTULO_PIX[c.tipo_chave as TipoPix] ?? c.tipo_chave} · {c.titular}</small></span>
              {c.principal ? <Star size={13} aria-label="principal" fill="currentColor" /> : <Copy size={13} aria-hidden />}
            </button>
          ))}</div>
        </div>
      ))}
    </div>
  );
}
