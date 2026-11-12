"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { ChevronDown, Eye, EyeOff, Pencil, RotateCcw, ShieldCheck } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { AREAS, GRUPOS, PARAMETROS, type GrupoParametro } from "@/features/configuracoes/definicoes";
import { ACOES_GESTOR } from "@/features/conta/permissoes";

type Mapa = Record<string, string>;
const NIVEIS = [
  { v: "editar", r: "Muda", ic: Pencil },
  { v: "ver", r: "Só vê", ic: Eye },
  { v: "oculto", r: "Escondido", ic: EyeOff },
] as const;

/** Nível que vale para um alvo, seguindo a mesma ordem do banco: chave > grupo > área; empresa > padrão. */
function efetivo(alvo: string, proprias: Mapa, padrao: Mapa, chaveGrupo?: string, chaveArea?: string): { v: string; de: "aqui" | "padrao" | "acima" | "sistema" } {
  if (proprias[alvo]) return { v: proprias[alvo], de: "aqui" };
  if (padrao[alvo]) return { v: padrao[alvo], de: "padrao" };
  for (const acima of [chaveGrupo, chaveArea].filter(Boolean) as string[]) {
    if (proprias[acima]) return { v: proprias[acima], de: "acima" };
    if (padrao[acima]) return { v: padrao[acima], de: "acima" };
  }
  const area = alvo.startsWith("area:") ? alvo.slice(5) : chaveArea?.slice(5);
  return { v: area === "sistema" ? "oculto" : "editar", de: "sistema" };
}

function Seletor({ valor, herdado, onMudar }: { valor: string | undefined; herdado: string; onMudar: (v: string | null) => void }) {
  return (
    <div className="perm-seletor" role="radiogroup">
      {NIVEIS.map((n) => {
        const ativo = (valor ?? herdado) === n.v;
        return (
          <button key={n.v} type="button" role="radio" aria-checked={ativo} className={`${ativo ? "ativo" : ""}${ativo && !valor ? " herdado" : ""} nivel-${n.v}`}
            title={ativo && !valor ? "Vem de cima (padrão ou grupo)" : undefined} onClick={() => onMudar(valor === n.v ? null : n.v)}>
            <n.ic size={13} aria-hidden /> {n.r}
          </button>
        );
      })}
    </div>
  );
}

/**
 * O que os gestores podem: cada área, grupo e ajuste (muda, só vê ou escondido) e as ações sensíveis.
 * "Padrão" vale para todas as empresas; numa empresa, o que for marcado vence o padrão.
 */
export function PermissoesDev() {
  const [orgs, setOrgs] = useState<{ id: string; nome: string }[]>([]);
  const [org, setOrg] = useState<string>("");
  const [dados, setDados] = useState<{ proprias: Mapa; padrao: Mapa } | null>(null);
  const [aberto, setAberto] = useState<string | null>(null);
  const [areaAberta, setAreaAberta] = useState<string | null>("sistema");

  useEffect(() => { void supabase().rpc("dev_organizacoes").then(({ data }) => setOrgs(((data ?? []) as { id: string; nome: string }[]).map((o) => ({ id: o.id, nome: o.nome })))); }, []);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_permissoes", { p_org: org || null });
    if (error) return toast(error.message, "erro");
    setDados(data as { proprias: Mapa; padrao: Mapa });
  }, [org]);
  useEffect(() => { setDados(null); void carregar(); }, [carregar]);

  async function definir(alvo: string, nivel: string | null) {
    setDados((d) => d && { ...d, proprias: (() => { const n = { ...d.proprias }; if (nivel) n[alvo] = nivel; else delete n[alvo]; return n; })() });
    const { error } = await supabase().rpc("dev_definir_permissao", { p_org: org || null, p_alvo: alvo, p_nivel: nivel });
    if (error) { toast(error.message, "erro"); void carregar(); }
  }

  const grupos = useMemo(() => (Object.keys(GRUPOS) as GrupoParametro[]), []);
  if (!dados) return <p className="dica">Carregando…</p>;
  const { proprias, padrao } = dados;
  const nProprias = Object.keys(proprias).length;

  return (
    <section className="dev-sec">
      <div className="dev-sec-cabeca">
        <h2><ShieldCheck size={18} aria-hidden /> Permissões dos gestores</h2>
        <select value={org} onChange={(e) => setOrg(e.target.value)} aria-label="Para quem">
          <option value="">Padrão (todas as empresas)</option>
          {orgs.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
        </select>
      </div>
      <p className="dica" style={{ margin: 0 }}>
        {org ? "Só para esta empresa: o que você marcar aqui vence o padrão. Desmarque para voltar a seguir o padrão." : "Vale para todas as empresas, menos no que você mudar dentro de cada uma."}
        {" "}Supervisores seguem estas regras e, além delas, o que o gestor liberar para eles.
        {nProprias > 0 && <> · <b>{nProprias}</b> regra(s) marcada(s) aqui.</>}
      </p>

      <h3 className="perm-titulo">Ações</h3>
      <div className="perm-acoes">
        {ACOES_GESTOR.map((a) => {
          const alvo = `acao:${a.chave}`;
          const v = proprias[alvo] ?? padrao[alvo] ?? "sim";
          return (
            <div key={a.chave} className={`perm-acao${v === "nao" ? " nao" : ""}`}>
              <span><strong>{a.rotulo}</strong><small>{a.dica}</small></span>
              {proprias[alvo] && <button type="button" className="perm-limpar" title="Voltar ao padrão" onClick={() => definir(alvo, null)}><RotateCcw size={12} aria-hidden /></button>}
              <input type="checkbox" role="switch" aria-label={a.rotulo} checked={v !== "nao"} onChange={(e) => definir(alvo, e.target.checked ? "sim" : "nao")} />
            </div>
          );
        })}
      </div>

      <h3 className="perm-titulo">Ajustes</h3>
      <div className="perm-areas">
        {AREAS.map((a) => {
          const alvoA = `area:${a.chave}`;
          const ea = efetivo(alvoA, proprias, padrao);
          const gs = grupos.filter((g) => GRUPOS[g].area === a.chave);
          return (
            <div key={a.chave} className="perm-area">
              <div className="perm-linha perm-linha-area">
                <button type="button" className="perm-abrir" aria-expanded={areaAberta === a.chave} onClick={() => setAreaAberta(areaAberta === a.chave ? null : a.chave)}>
                  <ChevronDown size={15} aria-hidden style={{ transform: areaAberta === a.chave ? "rotate(180deg)" : undefined }} />
                  <span><strong>{a.titulo}</strong><small>{a.chave === "sistema" ? "Escondida dos gestores até você liberar." : a.descricao}</small></span>
                </button>
                <Seletor valor={proprias[alvoA]} herdado={ea.v} onMudar={(v) => definir(alvoA, v)} />
              </div>
              {areaAberta === a.chave && gs.map((g) => {
                const alvoG = `grupo:${g}`;
                const eg = efetivo(alvoG, proprias, padrao, undefined, alvoA);
                const ps = PARAMETROS.filter((p) => p.grupo === g);
                return (
                  <div key={g} className="perm-grupo">
                    <div className="perm-linha">
                      <button type="button" className="perm-abrir" aria-expanded={aberto === g} onClick={() => setAberto(aberto === g ? null : g)}>
                        <ChevronDown size={14} aria-hidden style={{ transform: aberto === g ? "rotate(180deg)" : undefined }} />
                        <span><strong>{GRUPOS[g].titulo}</strong><small>{ps.length} ajuste(s)</small></span>
                      </button>
                      <Seletor valor={proprias[alvoG]} herdado={eg.v} onMudar={(v) => definir(alvoG, v)} />
                    </div>
                    {aberto === g && ps.map((p) => {
                      const alvoC = `chave:${p.chave}`;
                      const ec = efetivo(alvoC, proprias, padrao, alvoG, alvoA);
                      return (
                        <div key={p.chave} className="perm-linha perm-chave">
                          <span><strong>{p.rotulo}</strong>{p.soDev && <small>Só o Dev muda, qualquer que seja a escolha.</small>}</span>
                          <Seletor valor={proprias[alvoC]} herdado={ec.v} onMudar={(v) => definir(alvoC, v)} />
                        </div>
                      );
                    })}
                  </div>
                );
              })}
            </div>
          );
        })}
      </div>
    </section>
  );
}
