"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { Check, CircleHelp, Copy, Ghost, History, Pencil, Plus, Search, Trash2, X } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { useConta } from "@/features/conta/conta";
import { catalogoChaves, mostrarValor, rotuloChave, ROTULO_TIPO, type ChaveDev, type ModuloBasico } from "./chaves";

export type Escopo = "global" | "empresa" | "cliente" | "pessoa" | "papel";
export interface Regra {
  id?: string; chave: string; escopo: Escopo; alvo: string | null; valor: unknown;
  condicoes: { dias?: number[]; de?: string; ate?: string; papeis?: string[]; teste?: boolean };
  porque: string | null; valida_de: string | null; valida_ate: string | null; ativo: boolean;
  versao?: number; alvo_nome?: string | null; vencida?: boolean; autor?: string | null; atualizado_em?: string;
}
const ESCOPOS: { id: Escopo; rotulo: string; dica: string }[] = [
  { id: "global", rotulo: "Todo o sistema", dica: "Vale para todas as empresas e pessoas (menos você)." },
  { id: "empresa", rotulo: "Uma empresa", dica: "Equipe e clientes de uma transportadora." },
  { id: "cliente", rotulo: "Um cliente", dica: "Todas as contas de um cliente." },
  { id: "papel", rotulo: "Um cargo", dica: "Todos os motoboys, gestores, supervisores ou clientes." },
  { id: "pessoa", rotulo: "Uma pessoa", dica: "Só esta conta. Para você mesmo, escolha a sua conta." },
];
const PAPEIS = [["motoboy", "Motoboys"], ["gestor", "Gestores"], ["supervisor", "Supervisores"], ["cliente", "Clientes"]] as const;
const DIAS = ["Seg", "Ter", "Qua", "Qui", "Sex", "Sáb", "Dom"];
const VAZIA: Regra = { chave: "", escopo: "global", alvo: null, valor: false, condicoes: {}, porque: "", valida_de: null, valida_ate: null, ativo: true };

export function erroDev(m: string) {
  return m.includes("apenas_dev") ? "Só o Dev." : m.includes("chave_obrigatoria") ? "Escolha o que a regra controla."
    : m.includes("alvo_obrigatorio") ? "Escolha para quem a regra vale." : m;
}

/** Módulos do banco + catálogo (ações, especiais e ajustes), carregado uma vez. */
export function useCatalogo() {
  const [modulos, setModulos] = useState<ModuloBasico[]>([]);
  useEffect(() => { void supabase().from("modulos").select("chave,nome,grupo").order("ordem").then(({ data }) => setModulos((data ?? []) as ModuloBasico[])); }, []);
  return useMemo(() => catalogoChaves(modulos), [modulos]);
}

interface Opcao { id: string; nome: string; extra?: string | null }
export function useAlvos() {
  const [empresas, setEmpresas] = useState<Opcao[]>([]);
  const [clientes, setClientes] = useState<Opcao[]>([]);
  useEffect(() => {
    const sb = supabase();
    void Promise.all([sb.from("organizacoes").select("id,nome").order("nome"), sb.from("empresas").select("id,nome,organizacao_id").order("nome").limit(2000)]).then(([o, e]) => {
      const orgs = (o.data ?? []) as Opcao[];
      setEmpresas(orgs);
      setClientes(((e.data ?? []) as { id: string; nome: string; organizacao_id: string | null }[]).map((c) => ({ id: c.id, nome: c.nome, extra: orgs.find((x) => x.id === c.organizacao_id)?.nome })));
    });
  }, []);
  return { empresas, clientes };
}

/** Busca qualquer conta pelo nome (o Dev vê todas). */
export function BuscaPessoa({ valor, nome, onEscolher, rotulo = "Pessoa" }: { valor: string | null; nome?: string | null; onEscolher: (id: string, nome: string) => void; rotulo?: string }) {
  const [q, setQ] = useState("");
  const [res, setRes] = useState<{ id: string; nome: string; papeis: string[] }[]>([]);
  useEffect(() => {
    const t = q.trim();
    if (t.length < 2) { setRes([]); return; }
    const h = setTimeout(() => void supabase().from("perfis").select("id,nome,papeis").ilike("nome", `%${t}%`).limit(12).then(({ data }) => setRes((data ?? []) as typeof res)), 250);
    return () => clearTimeout(h);
  }, [q]);
  return (
    <div className="busca-pessoa">
      <label className="campo"><span>{rotulo}</span>
        <input placeholder={valor ? (nome ?? "Escolhida") : "Digite o nome"} value={q} onChange={(e) => setQ(e.target.value)} />
      </label>
      {valor && !q && <span className="dica">Escolhida: <strong>{nome ?? valor}</strong></span>}
      {res.length > 0 && (
        <div className="busca-pessoa-lista">
          {res.map((p) => <button type="button" key={p.id} onClick={() => { onEscolher(p.id, p.nome); setQ(""); setRes([]); }}>{p.nome} <span className="dica">{p.papeis.join(", ")}</span></button>)}
        </div>
      )}
    </div>
  );
}

function resumoCondicoes(c: Regra["condicoes"]) {
  const p: string[] = [];
  if (c.dias?.length) p.push(c.dias.map((d) => DIAS[d - 1]).join(", "));
  if (c.de && c.ate) p.push(`${c.de}–${c.ate}`);
  if (c.papeis?.length) p.push(`só ${c.papeis.join(", ")}`);
  if (c.teste === true) p.push("só no modo teste");
  if (c.teste === false) p.push("só no real");
  return p.join(" · ");
}
const paraLocal = (iso: string | null) => (iso ? new Date(new Date(iso).getTime() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16) : "");
const deLocal = (v: string) => (v ? new Date(v).toISOString() : null);

/** Editor de uma regra: o quê, para quem, qual valor, quando e por quê. */
export function EditorRegra({ inicial, catalogo, onFechar, onSalvou }: { inicial: Regra; catalogo: ChaveDev[]; onFechar: () => void; onSalvou: () => void }) {
  const [r, setR] = useState<Regra>(inicial);
  const [buscaChave, setBuscaChave] = useState("");
  const [nomeAlvo, setNomeAlvo] = useState<string | null>(inicial.alvo_nome ?? null);
  const [salvando, setSalvando] = useState(false);
  const { empresas, clientes } = useAlvos();
  const def = catalogo.find((c) => c.chave === r.chave);
  const t = buscaChave.trim().toLowerCase();
  const achadas = t ? catalogo.filter((c) => `${c.rotulo} ${c.chave} ${c.grupo}`.toLowerCase().includes(t)).slice(0, 30) : [];
  const muda = (p: Partial<Regra>) => setR((x) => ({ ...x, ...p }));
  const cond = (p: Partial<Regra["condicoes"]>) => setR((x) => ({ ...x, condicoes: Object.fromEntries(Object.entries({ ...x.condicoes, ...p }).filter(([, v]) => v !== undefined && v !== "" && !(Array.isArray(v) && !v.length))) }));

  async function salvar() {
    setSalvando(true);
    let valor = r.valor;
    if (def?.valor === "numero") valor = Number(r.valor);
    const { error } = await supabase().rpc("dev_salvar_regra", { p: { ...r, valor, porque: r.porque ?? "" } });
    setSalvando(false);
    if (error) return toast(erroDev(error.message), "erro");
    toast(r.id ? "Regra atualizada." : "Regra criada. Já está valendo.", "ok", { titulo: "Fantasma" });
    onSalvou();
  }

  return (
    <div className="modal-fundo" onClick={onFechar}>
      <div className="modal vidro regra-editor" role="dialog" aria-label="Regra do Dev" onClick={(e) => e.stopPropagation()}>
        <div className="modal-cabeca"><strong><Ghost size={16} aria-hidden /> {r.id ? `Regra · versão ${r.versao ?? 1}` : "Nova regra"}</strong>
          <button className="botao-icone" aria-label="Fechar" onClick={onFechar}><X size={16} aria-hidden /></button></div>

        <section className="regra-passo">
          <span className="rotulo">O que ela controla</span>
          {def ? (
            <div className="regra-chave-escolhida"><span className="chip">{ROTULO_TIPO[def.tipo]}</span> <strong>{def.rotulo}</strong> <code>{def.chave}</code>
              <button className="botao-texto" onClick={() => muda({ chave: "" })}>Trocar</button></div>
          ) : (<>
            <label className="busca-mini"><Search size={14} aria-hidden /><input autoFocus placeholder="Módulo, ação, permissão ou ajuste" value={buscaChave} onChange={(e) => setBuscaChave(e.target.value)} /></label>
            <div className="regra-chaves">{achadas.map((c) => (
              <button key={c.chave} type="button" onClick={() => { muda({ chave: c.chave, valor: c.valor === "booleano" ? false : c.valor === "numero" ? 0 : (c.opcoes?.[0]?.valor ?? "") }); setBuscaChave(""); }}>
                <span className="chip">{ROTULO_TIPO[c.tipo]}</span> {c.rotulo} <span className="dica">{c.grupo}</span>
              </button>))}
              {t && !achadas.length && <button type="button" onClick={() => { muda({ chave: buscaChave.trim() }); setBuscaChave(""); }}>Usar a chave “{buscaChave.trim()}”</button>}
            </div>
          </>)}
        </section>

        <section className="regra-passo">
          <span className="rotulo">Para quem</span>
          <div className="segmentado" style={{ gridTemplateColumns: "repeat(5, 1fr)" }}>
            {ESCOPOS.map((e) => <button key={e.id} type="button" className={r.escopo === e.id ? "ativo" : ""} onClick={() => { muda({ escopo: e.id, alvo: null }); setNomeAlvo(null); }}>{e.rotulo}</button>)}
          </div>
          <p className="dica">{ESCOPOS.find((e) => e.id === r.escopo)?.dica}</p>
          {r.escopo === "empresa" && <select value={r.alvo ?? ""} onChange={(e) => muda({ alvo: e.target.value })}><option value="">Escolha a empresa</option>{empresas.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}</select>}
          {r.escopo === "cliente" && <select value={r.alvo ?? ""} onChange={(e) => muda({ alvo: e.target.value })}><option value="">Escolha o cliente</option>{clientes.map((o) => <option key={o.id} value={o.id}>{o.nome}{o.extra ? ` · ${o.extra}` : ""}</option>)}</select>}
          {r.escopo === "papel" && <select value={r.alvo ?? ""} onChange={(e) => muda({ alvo: e.target.value })}><option value="">Escolha o cargo</option>{PAPEIS.map(([p, n]) => <option key={p} value={p}>{n}</option>)}</select>}
          {r.escopo === "pessoa" && <BuscaPessoa valor={r.alvo} nome={nomeAlvo} onEscolher={(id, n) => { muda({ alvo: id }); setNomeAlvo(n); }} />}
        </section>

        <section className="regra-passo">
          <span className="rotulo">Valor</span>
          {(!def || def.valor === "booleano") ? (
            <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
              <button type="button" className={r.valor === true ? "ativo" : ""} onClick={() => muda({ valor: true })}><Check size={14} aria-hidden /> {def?.tipo === "modulo" ? "Ligado" : "Sim / libera"}</button>
              <button type="button" className={r.valor === false ? "ativo" : ""} onClick={() => muda({ valor: false })}><X size={14} aria-hidden /> {def?.tipo === "modulo" ? "Desligado" : "Não / bloqueia"}</button>
            </div>
          ) : def.valor === "opcoes" && def.opcoes ? (
            <select value={String(r.valor ?? "")} onChange={(e) => muda({ valor: def.opcoes!.find((o) => String(o.valor) === e.target.value)?.valor ?? e.target.value })}>
              {def.opcoes.map((o) => <option key={String(o.valor)} value={String(o.valor)}>{o.rotulo}</option>)}
            </select>
          ) : (
            <input type={def.valor === "numero" ? "number" : "text"} value={String(r.valor ?? "")} onChange={(e) => muda({ valor: e.target.value })} />
          )}
        </section>

        <details className="regra-passo" open={Boolean(resumoCondicoes(r.condicoes) || r.valida_de || r.valida_ate)}>
          <summary className="rotulo">Quando (opcional)</summary>
          <div className="regra-dias">{DIAS.map((d, i) => {
            const on = r.condicoes.dias?.includes(i + 1) ?? false;
            return <label key={d} className={`chip${on ? " ativo" : ""}`}><input type="checkbox" checked={on} onChange={() => cond({ dias: on ? r.condicoes.dias!.filter((x) => x !== i + 1) : [...(r.condicoes.dias ?? []), i + 1].sort() })} /> {d}</label>;
          })}</div>
          <div className="regra-linha">
            <label className="campo"><span>Das</span><input type="time" value={r.condicoes.de ?? ""} onChange={(e) => cond({ de: e.target.value })} /></label>
            <label className="campo"><span>Até</span><input type="time" value={r.condicoes.ate ?? ""} onChange={(e) => cond({ ate: e.target.value })} /></label>
          </div>
          <div className="regra-dias">{PAPEIS.map(([p, n]) => {
            const on = r.condicoes.papeis?.includes(p) ?? false;
            return <label key={p} className={`chip${on ? " ativo" : ""}`}><input type="checkbox" checked={on} onChange={() => cond({ papeis: on ? r.condicoes.papeis!.filter((x) => x !== p) : [...(r.condicoes.papeis ?? []), p] })} /> Só {n.toLowerCase()}</label>;
          })}</div>
          <div className="segmentado" style={{ gridTemplateColumns: "repeat(3, 1fr)" }}>
            {([[undefined, "Real e teste"], [false, "Só no real"], [true, "Só no modo teste"]] as const).map(([v, n]) => <button key={n} type="button" className={r.condicoes.teste === v ? "ativo" : ""} onClick={() => cond({ teste: v })}>{n}</button>)}
          </div>
          <div className="regra-linha">
            <label className="campo"><span>Começa em</span><input type="datetime-local" value={paraLocal(r.valida_de)} onChange={(e) => muda({ valida_de: deLocal(e.target.value) })} /></label>
            <label className="campo"><span>Acaba em</span><input type="datetime-local" value={paraLocal(r.valida_ate)} onChange={(e) => muda({ valida_ate: deLocal(e.target.value) })} /></label>
          </div>
        </details>

        <section className="regra-passo">
          <label className="campo"><span>Por quê</span><input placeholder="Aparece no “por quê” da matriz e no registro" value={r.porque ?? ""} onChange={(e) => muda({ porque: e.target.value })} /></label>
          <label className="linha-check"><input type="checkbox" checked={r.ativo} onChange={(e) => muda({ ativo: e.target.checked })} /> Regra ativa</label>
        </section>
        <div className="acoes-modal">
          <button className="botao-texto" onClick={onFechar}>Cancelar</button>
          <button className="botao-ouro" disabled={salvando || !r.chave || (r.escopo !== "global" && !r.alvo)} onClick={() => void salvar()}>{salvando ? "Salvando…" : r.id ? "Salvar mudanças" : "Criar regra"}</button>
        </div>
      </div>
    </div>
  );
}

function HistoricoRegra({ id, onFechar, onRestaurou }: { id: string; onFechar: () => void; onRestaurou: () => void }) {
  const [l, setL] = useState<{ versao: number; operacao: string; dados: Regra; por: string | null; em: string }[] | null>(null);
  useEffect(() => { void supabase().rpc("dev_regras_historico", { p_id: id }).then(({ data }) => setL((data ?? []) as typeof l)); }, [id]);
  async function restaurar(v: number) {
    const { error } = await supabase().rpc("dev_restaurar_regra", { p_id: id, p_versao: v });
    if (error) return toast(erroDev(error.message), "erro");
    toast(`Regra voltou para a versão ${v}.`, "ok"); onRestaurou();
  }
  return (
    <div className="modal-fundo" onClick={onFechar}>
      <div className="modal vidro" role="dialog" aria-label="Versões da regra" onClick={(e) => e.stopPropagation()}>
        <div className="modal-cabeca"><strong><History size={16} aria-hidden /> Versões</strong><button className="botao-icone" aria-label="Fechar" onClick={onFechar}><X size={16} aria-hidden /></button></div>
        {!l ? <p className="dica">Carregando…</p> : l.map((h, i) => (
          <div key={i} className="versao-linha">
            <div><strong>v{h.versao} · {h.operacao}</strong> <span className="dica">{new Date(h.em).toLocaleString("pt-BR")}{h.por ? ` · ${h.por}` : ""}</span>
              <p className="dica">Valor {mostrarValor(h.dados.valor)} · {h.dados.ativo ? "ativa" : "parada"}{h.dados.porque ? ` · ${h.dados.porque}` : ""}</p></div>
            {i > 0 && <button className="botao-texto" onClick={() => void restaurar(h.versao)}>Voltar para esta</button>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** Regras do Fantasma: a lista, o editor, as versões e o teste do “por quê”. */
export function RegrasDev({ soMinhas = false }: { soMinhas?: boolean }) {
  const conta = useConta();
  const catalogo = useCatalogo();
  const [regras, setRegras] = useState<Regra[] | null>(null);
  const [editando, setEditando] = useState<Regra | null>(null);
  const [historico, setHistorico] = useState<string | null>(null);
  const [busca, setBusca] = useState("");
  const [filtro, setFiltro] = useState<"todas" | "ativas" | "paradas">("todas");
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_regras");
    if (error) return toast(erroDev(error.message), "erro");
    setRegras(data as Regra[]);
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);
  const t = busca.trim().toLowerCase();
  const lista = (regras ?? []).filter((r) => (!soMinhas || (r.escopo === "pessoa" && r.alvo === conta.id))
    && (filtro === "todas" || (filtro === "ativas" ? r.ativo && !r.vencida : !r.ativo || r.vencida))
    && (!t || `${rotuloChave(catalogo, r.chave)} ${r.chave} ${r.alvo_nome ?? ""} ${r.porque ?? ""}`.toLowerCase().includes(t)));

  async function alternar(r: Regra) {
    const { error } = await supabase().rpc("dev_salvar_regra", { p: { ...r, ativo: !r.ativo } });
    if (error) return toast(erroDev(error.message), "erro");
    void carregar();
  }
  async function apagar(r: Regra) {
    if (!window.confirm(`Apagar a regra “${rotuloChave(catalogo, r.chave)}”? As versões ficam guardadas.`)) return;
    const { error } = await supabase().rpc("dev_apagar_regra", { p_id: r.id });
    if (error) return toast(erroDev(error.message), "erro");
    toast("Regra apagada.", "ok"); void carregar();
  }
  const nova: Regra = soMinhas ? { ...VAZIA, escopo: "pessoa", alvo: conta.id, alvo_nome: "Você" } : VAZIA;

  return (
    <div className="fantasma">
      {!soMinhas && (
        <div className="fantasma-explica">
          <Ghost size={28} aria-hidden />
          <p>Uma regra passa por cima de qualquer ajuste, módulo ou permissão — no site, no app e no servidor. Vale a mais específica:
            <strong> pessoa › cliente › empresa › cargo › sistema</strong>. Você só é afetado pelas regras que fizer para a sua própria conta.</p>
        </div>
      )}
      <div className="modulos-barra">
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar regra" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <div className="filtro">{(["todas", "ativas", "paradas"] as const).map((f) => <button key={f} className={filtro === f ? "ativo" : ""} onClick={() => setFiltro(f)}>{f[0].toUpperCase() + f.slice(1)}</button>)}</div>
        <span className="espaco" />
        <button className="botao-ouro" onClick={() => setEditando(nova)}><Plus size={15} aria-hidden /> Nova regra</button>
      </div>
      {!regras ? <p className="dica">Carregando…</p> : !lista.length ? <p className="vazio">{soMinhas ? "Nenhuma regra para você: tudo liberado, sem filtro." : "Nenhuma regra. O sistema segue os ajustes de cada empresa."}</p> : (
        <div className="regras-lista">
          {lista.map((r) => {
            const def = catalogo.find((c) => c.chave === r.chave);
            const parada = !r.ativo || r.vencida;
            return (
              <article key={r.id} className={`regra-cartao${parada ? " parada" : ""}`}>
                <div className="regra-cabeca">
                  {def && <span className="chip">{ROTULO_TIPO[def.tipo]}</span>}
                  <strong>{def?.rotulo ?? r.chave}</strong>
                  <span className={`regra-valor ${r.valor === false ? "nao" : r.valor === true ? "sim" : ""}`}>{def?.tipo === "modulo" ? (r.valor ? "Ligado" : "Desligado") : mostrarValor(r.valor)}</span>
                </div>
                <p className="dica">{ESCOPOS.find((e) => e.id === r.escopo)?.rotulo}{r.alvo_nome ? `: ${r.alvo_nome}` : ""}
                  {resumoCondicoes(r.condicoes) && ` · ${resumoCondicoes(r.condicoes)}`}
                  {r.valida_ate && ` · até ${new Date(r.valida_ate).toLocaleString("pt-BR")}`}{r.vencida && " (venceu)"}</p>
                {r.porque && <p className="regra-porque">“{r.porque}”</p>}
                <div className="regra-acoes">
                  <label className="linha-check"><input type="checkbox" checked={r.ativo} onChange={() => void alternar(r)} /> Ativa</label>
                  <span className="dica">v{r.versao}{r.autor ? ` · ${r.autor}` : ""}</span>
                  <span className="espaco" />
                  <button className="botao-icone" title="Editar" aria-label="Editar" onClick={() => setEditando(r)}><Pencil size={15} aria-hidden /></button>
                  <button className="botao-icone" title="Duplicar" aria-label="Duplicar" onClick={() => setEditando({ ...r, id: undefined, versao: undefined })}><Copy size={15} aria-hidden /></button>
                  <button className="botao-icone" title="Versões" aria-label="Versões" onClick={() => setHistorico(r.id!)}><History size={15} aria-hidden /></button>
                  <button className="botao-icone" title="Apagar" aria-label="Apagar" onClick={() => void apagar(r)}><Trash2 size={15} aria-hidden /></button>
                </div>
              </article>
            );
          })}
        </div>
      )}
      {!soMinhas && <ExplicarDev catalogo={catalogo} />}
      {editando && <EditorRegra inicial={editando} catalogo={catalogo} onFechar={() => setEditando(null)} onSalvou={() => { setEditando(null); void carregar(); conta.recarregar(); }} />}
      {historico && <HistoricoRegra id={historico} onFechar={() => setHistorico(null)} onRestaurou={() => { setHistorico(null); void carregar(); }} />}
    </div>
  );
}

interface Explicacao { valor: unknown; fonte: string; motivo: string; regra: string | null }
/** “Por quê?”: o que vale para uma pessoa e de onde vem. */
export function ExplicarDev({ catalogo }: { catalogo: ChaveDev[] }) {
  const [pessoa, setPessoa] = useState<{ id: string; nome: string } | null>(null);
  const [chave, setChave] = useState("");
  const [res, setRes] = useState<Explicacao | null>(null);
  async function explicar() {
    if (!pessoa || !chave) return;
    const { data, error } = await supabase().rpc("dev_explicar", { p_pessoa: pessoa.id, p_chave: chave });
    if (error) return toast(erroDev(error.message), "erro");
    setRes(data as Explicacao);
  }
  return (
    <section className="explicar-dev vidro-sutil">
      <span className="rotulo"><CircleHelp size={14} aria-hidden /> Testar: por que fulano vê isso?</span>
      <div className="regra-linha">
        <BuscaPessoa valor={pessoa?.id ?? null} nome={pessoa?.nome} onEscolher={(id, nome) => { setPessoa({ id, nome }); setRes(null); }} />
        <label className="campo"><span>O quê</span>
          <select value={chave} onChange={(e) => { setChave(e.target.value); setRes(null); }}>
            <option value="">Escolha</option>
            {(["modulo", "acao", "especial", "ajuste"] as const).map((tp) => (
              <optgroup key={tp} label={ROTULO_TIPO[tp]}>{catalogo.filter((c) => c.tipo === tp).map((c) => <option key={c.chave} value={c.chave}>{c.rotulo}</option>)}</optgroup>
            ))}
          </select>
        </label>
        <button className="botao-ouro" disabled={!pessoa || !chave} onClick={() => void explicar()}>Explicar</button>
      </div>
      {res && <p className="explicar-res"><strong>{mostrarValor(res.valor)}</strong> — {res.motivo}</p>}
    </section>
  );
}

/** Matriz pessoa × permissão de uma empresa, com o porquê de cada célula. Clique muda só para aquela pessoa. */
export function MatrizDev() {
  const catalogo = useCatalogo();
  const { empresas } = useAlvos();
  const [org, setOrg] = useState("");
  const [chaves, setChaves] = useState<string[]>(["modulo:pedidos", "modulo:carteira", "modulo:chat", "acao:criar_contas", "acao:ver_carteira", "especial_ignora_local", "especial_cliente_edita_aprovado"]);
  const [linhas, setLinhas] = useState<{ id: string; nome: string; papeis: string[]; cargo: string | null; cliente: string | null; valores: Record<string, Explicacao> }[] | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [editando, setEditando] = useState<Regra | null>(null);
  const [mais, setMais] = useState("");
  const montar = useCallback(async () => {
    if (!org) return;
    setCarregando(true);
    const { data, error } = await supabase().rpc("dev_matriz", { p_org: org, p_chaves: chaves });
    setCarregando(false);
    if (error) return toast(erroDev(error.message), "erro");
    setLinhas(data as typeof linhas);
  }, [org, chaves]);
  useEffect(() => { void montar(); }, [montar]);
  return (
    <div className="matriz-dev">
      <div className="modulos-barra">
        <select value={org} onChange={(e) => setOrg(e.target.value)} aria-label="Empresa"><option value="">Escolha a empresa</option>{empresas.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}</select>
        <select value={mais} onChange={(e) => { if (e.target.value && !chaves.includes(e.target.value)) setChaves([...chaves, e.target.value]); setMais(""); }} aria-label="Adicionar coluna">
          <option value="">+ coluna</option>
          {(["modulo", "acao", "especial", "ajuste"] as const).map((tp) => <optgroup key={tp} label={ROTULO_TIPO[tp]}>{catalogo.filter((c) => c.tipo === tp && !chaves.includes(c.chave)).map((c) => <option key={c.chave} value={c.chave}>{c.rotulo}</option>)}</optgroup>)}
        </select>
        {carregando && <span className="dica">Calculando…</span>}
      </div>
      {!org ? <p className="vazio">Escolha uma empresa para ver o que cada pessoa (equipe e clientes) pode, e por quê.</p> : linhas && (
        <div className="matriz-rolagem">
          <table className="dev-tabela matriz">
            <thead><tr><th>Pessoa</th>{chaves.map((k) => <th key={k}><span>{rotuloChave(catalogo, k)}</span><button className="botao-texto" aria-label="Tirar coluna" onClick={() => setChaves(chaves.filter((x) => x !== k))}><X size={12} aria-hidden /></button></th>)}</tr></thead>
            <tbody>{linhas.map((l) => (
              <tr key={l.id}>
                <td><strong>{l.nome}</strong><span className="dica">{l.cliente ? `cliente · ${l.cliente}` : l.cargo ?? l.papeis.join(", ")}</span></td>
                {chaves.map((k) => {
                  const c = l.valores[k];
                  return (
                    <td key={k}>
                      <button type="button" className={`celula ${c?.valor === true ? "sim" : c?.valor === false ? "nao" : ""} fonte-${c?.fonte}`} title={`${c?.motivo ?? ""} — clique para mudar só para ${l.nome}`}
                        onClick={() => setEditando({ ...VAZIA, chave: k, escopo: "pessoa", alvo: l.id, alvo_nome: l.nome, valor: typeof c?.valor === "boolean" ? !c.valor : c?.valor ?? true })}>
                        {c?.valor === true ? <Check size={14} aria-hidden /> : c?.valor === false ? <X size={14} aria-hidden /> : mostrarValor(c?.valor)}
                        <small>{c?.motivo}</small>
                      </button>
                    </td>
                  );
                })}
              </tr>
            ))}</tbody>
          </table>
        </div>
      )}
      {editando && <EditorRegra inicial={editando} catalogo={catalogo} onFechar={() => setEditando(null)} onSalvou={() => { setEditando(null); void montar(); }} />}
    </div>
  );
}
