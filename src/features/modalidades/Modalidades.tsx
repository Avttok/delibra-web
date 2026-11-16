"use client";

import { useCallback, useEffect, useState } from "react";
import { Plus, Save, Trash2 } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { useConta } from "@/features/conta/conta";
import { PERMISSOES_SUPERVISOR } from "@/features/conta/Cargos";
import { ACOES_GESTOR } from "@/features/conta/permissoes";
import { ALVOS_CORRIDA, ALVOS_PEDIDO, aplicarRotulos } from "./rotulos";

/*
 * Ajustes → Modalidades: o que muda a FORMA do trabalho de cada empresa, sem programar.
 *  - Campos próprios (pedido, parada, cliente, motoboy)
 *  - Nomes próprios (status e tipos de parada)
 *  - Taxas e bônus (regras extras de preço e de pagamento)
 *  - Cargos (conjuntos de permissões para a equipe)
 */

const ERROS: Record<string, string> = {
  acao_bloqueada: "Você não tem permissão para isso. Fale com o suporte.",
  campo_repetido: "Já existe um campo com esse nome aqui.",
  cargo_repetido: "Já existe um cargo com esse nome.",
  so_supervisor: "Dê o cargo de supervisor à pessoa antes.",
  apenas_gestor: "Só o gestor muda isso.",
};
const erro = (m: string) => ERROS[Object.keys(ERROS).find((k) => m.includes(k)) ?? ""] ?? "Não deu agora. Tente de novo.";
async function rpc<T = unknown>(nome: string, args?: Record<string, unknown>): Promise<T | null> {
  const { data, error } = await supabase().rpc(nome, args);
  if (error) { toast(erro(error.message), "erro"); return null; }
  return data as T;
}
function useTiposPedido() {
  const [t, setT] = useState<{ chave: string; nome: string }[]>([]);
  useEffect(() => { void supabase().from("tipos_pedido").select("chave,nome").order("ordem").then(({ data }) => setT((data ?? []) as typeof t)); }, []);
  return t;
}
const alternar = <T,>(l: T[], v: T) => (l.includes(v) ? l.filter((x) => x !== v) : [...l, v]);

function Chips<T extends string | number>({ opcoes, valor, onMudar }: { opcoes: [T, string][]; valor: T[]; onMudar: (v: T[]) => void }) {
  return (
    <div className="linha-chips">
      {opcoes.map(([v, r]) => <button key={String(v)} type="button" className={`chip${valor.includes(v) ? " ativo" : ""}`} onClick={() => onMudar(alternar(valor, v))}>{r}</button>)}
    </div>
  );
}

// =====================================================================================================  campos próprios
type Campo = {
  id?: string; entidade: "pedido" | "ponto" | "cliente" | "motoboy"; ponto_tipo: "coleta" | "entrega" | null; tipos_pedido: string[];
  chave?: string; rotulo: string; dica: string | null; tipo: string; opcoes: string[]; obrigatorio: boolean; quem_preenche: string; etapa?: "chegou" | "concluir";
  visivel_cliente: boolean; visivel_motoboy: boolean; ordem: number; ativo: boolean; da_plataforma?: boolean;
};
const ENTIDADES: [Campo["entidade"], string, string][] = [
  ["pedido", "No pedido", "Quem pede preenche (ex.: número da nota, centro de custo)."],
  ["ponto", "Na parada", "O motoboy responde ao concluir a coleta ou a entrega (ex.: dinheiro recebido, temperatura, foto da nota)."],
  ["cliente", "No cadastro do cliente", "Dados a mais de cada cliente (ex.: contrato, horário de recebimento)."],
  ["motoboy", "No cadastro do motoboy", "Dados a mais de cada motoboy (ex.: tamanho do baú, MEI)."],
];
const TIPOS_CAMPO: [string, string][] = [["texto", "Texto"], ["numero", "Número"], ["dinheiro", "Dinheiro"], ["sim_nao", "Sim ou não"], ["escolha", "Escolha"],
  ["data", "Data"], ["telefone", "Telefone"], ["documento", "Documento"], ["foto", "Foto (parada)"]];
const QUEM: [string, string][] = [["qualquer", "Qualquer um"], ["cliente", "O cliente"], ["gestor", "A equipe"], ["motoboy", "O motoboy"]];

export function CamposProprios() {
  const conta = useConta();
  const tipos = useTiposPedido();
  const [lista, setLista] = useState<Campo[] | null>(null);
  const [ed, setEd] = useState<Campo | null>(null);
  const carregar = useCallback(async () => setLista((await rpc<Campo[]>("campos_editor")) ?? []), []);
  useEffect(() => { void carregar(); }, [carregar]);
  const novo = (entidade: Campo["entidade"]): Campo => ({ entidade, ponto_tipo: entidade === "ponto" ? "entrega" : null, tipos_pedido: [], rotulo: "", dica: null, tipo: "texto",
    opcoes: [], obrigatorio: false, quem_preenche: entidade === "ponto" ? "motoboy" : entidade === "pedido" ? "qualquer" : "gestor", visivel_cliente: true, visivel_motoboy: true, ordem: 0, ativo: true });
  async function salvar() {
    if (!ed) return;
    if (await rpc("salvar_campo", { p: ed })) { toast("Campo salvo.", "ok"); setEd(null); void carregar(); }
  }
  async function apagar(id: string) { if (await rpc("apagar_campo", { p_id: id }) !== null) { setEd(null); void carregar(); } }
  if (!lista) return <p className="dica">Carregando…</p>;
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Campos que a sua operação precisa e o sistema não tem. Aparecem no app e no site, entram na API e nos relatórios.</p>
      {ENTIDADES.map(([ent, titulo, dica]) => (
        <section key={ent} className="bloco">
          <div className="api-titulo"><strong>{titulo}</strong>
            <button type="button" className="botao-ouro pequeno" onClick={() => setEd(novo(ent))}><Plus size={14} aria-hidden /> Novo campo</button></div>
          <p className="dica" style={{ margin: 0 }}>{dica}</p>
          {ed && ed.entidade === ent && (
            <div className="catalogo-form vidro">
              <label className="campo"><span>Nome do campo</span><input value={ed.rotulo} placeholder="Ex.: Dinheiro recebido" onChange={(e) => setEd({ ...ed, rotulo: e.target.value })} /></label>
              <label className="campo"><span>Dica (opcional)</span><input value={ed.dica ?? ""} onChange={(e) => setEd({ ...ed, dica: e.target.value })} /></label>
              <span className="rotulo">Tipo</span>
              <div className="linha-chips">{TIPOS_CAMPO.filter(([t]) => t !== "foto" || ent === "ponto").map(([t, r]) => <button key={t} type="button" className={`chip${ed.tipo === t ? " ativo" : ""}`} onClick={() => setEd({ ...ed, tipo: t })}>{r}</button>)}</div>
              {ed.tipo === "escolha" && <label className="campo"><span>Opções (uma por linha)</span><textarea rows={3} value={ed.opcoes.join("\n")} onChange={(e) => setEd({ ...ed, opcoes: e.target.value.split("\n") })} /></label>}
              {ent === "ponto" && <>
                <span className="rotulo">Em qual parada</span>
                <div className="linha-chips">{([[null, "Coleta e entrega"], ["coleta", "Só coleta"], ["entrega", "Só entrega"]] as [Campo["ponto_tipo"], string][]).map(([t, r]) => <button key={String(t)} type="button" className={`chip${ed.ponto_tipo === t ? " ativo" : ""}`} onClick={() => setEd({ ...ed, ponto_tipo: t })}>{r}</button>)}</div>
                <span className="rotulo">Quando o motoboy responde</span>
                <div className="linha-chips">{([["chegou", "Ao chegar no endereço"], ["concluir", "Ao concluir a parada"]] as ["chegou" | "concluir", string][]).map(([t, r]) => <button key={t} type="button" className={`chip${(ed.etapa ?? "concluir") === t ? " ativo" : ""}`} onClick={() => setEd({ ...ed, etapa: t })}>{r}</button>)}</div>
              </>}
              {(ent === "pedido" || ent === "ponto") && tipos.length > 1 && <>
                <span className="rotulo">Tipos de pedido (nenhum marcado = todos)</span>
                <Chips opcoes={tipos.map((t) => [t.chave, t.nome] as [string, string])} valor={ed.tipos_pedido} onMudar={(v) => setEd({ ...ed, tipos_pedido: v })} />
              </>}
              <span className="rotulo">Quem preenche</span>
              <div className="linha-chips">{QUEM.map(([q, r]) => <button key={q} type="button" className={`chip${ed.quem_preenche === q ? " ativo" : ""}`} onClick={() => setEd({ ...ed, quem_preenche: q })}>{r}</button>)}</div>
              <label className="opcao"><span>Obrigatório</span><input type="checkbox" role="switch" checked={ed.obrigatorio} onChange={(e) => setEd({ ...ed, obrigatorio: e.target.checked })} /></label>
              <label className="opcao"><span>O cliente vê</span><input type="checkbox" role="switch" checked={ed.visivel_cliente} onChange={(e) => setEd({ ...ed, visivel_cliente: e.target.checked })} /></label>
              <label className="opcao"><span>O motoboy vê</span><input type="checkbox" role="switch" checked={ed.visivel_motoboy} onChange={(e) => setEd({ ...ed, visivel_motoboy: e.target.checked })} /></label>
              <label className="opcao"><span>Ativo</span><input type="checkbox" role="switch" checked={ed.ativo} onChange={(e) => setEd({ ...ed, ativo: e.target.checked })} /></label>
              {conta.dev && !ed.id && <label className="opcao"><span>Vale para todas as empresas (plataforma)</span><input type="checkbox" role="switch" checked={!!ed.da_plataforma} onChange={(e) => setEd({ ...ed, da_plataforma: e.target.checked })} /></label>}
              <div className="linha-botoes">
                <button type="button" className="botao-ouro" disabled={!ed.rotulo.trim()} onClick={salvar}><Save size={15} aria-hidden /> Salvar</button>
                {ed.id && (!ed.da_plataforma || conta.dev) && <button type="button" className="botao-texto perigo" onClick={() => apagar(ed.id!)}><Trash2 size={14} aria-hidden /> Apagar</button>}
                <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
              </div>
            </div>
          )}
          <div className="catalogo-lista">
            {lista.filter((c) => c.entidade === ent).map((c) => (
              <div key={c.id} className={`catalogo-linha ${c.ativo ? "" : "inativa"}`}>
                <button type="button" className="catalogo-linha-corpo" disabled={c.da_plataforma && !conta.dev} onClick={() => setEd(c)}>
                  <span><strong>{c.rotulo}{c.obrigatorio ? " *" : ""}</strong>
                    <small>{TIPOS_CAMPO.find(([t]) => t === c.tipo)?.[1]} · {QUEM.find(([q]) => q === c.quem_preenche)?.[1]}{c.ponto_tipo ? ` · só ${c.ponto_tipo}` : ""}{c.entidade === "ponto" && c.etapa === "chegou" ? " · na chegada" : ""}{c.da_plataforma ? " · da plataforma" : ""}</small></span>
                </button>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

// =====================================================================================================  nomes próprios
export function NomesProprios() {
  const tipos = useTiposPedido();
  const [tipo, setTipo] = useState("");  // "" = todos os tipos de pedido
  const [todos, setTodos] = useState<{ alvo: string; tipo_pedido: string; texto: string; da_plataforma: boolean }[]>([]);
  const [ed, setEd] = useState<Record<string, string>>({});
  const doTipo = useCallback((t: string, r = todos) => Object.fromEntries(r.filter((x) => (x.tipo_pedido ?? "") === t && !x.da_plataforma).map((x) => [x.alvo, x.texto])), [todos]);
  const geral = doTipo("");
  const atual = doTipo(tipo);
  const carregar = useCallback(async (t: string) => {
    const r = (await rpc<{ alvo: string; tipo_pedido: string; texto: string; da_plataforma: boolean }[]>("rotulos_editor")) ?? [];
    setTodos(r);
    setEd(Object.fromEntries(r.filter((x) => (x.tipo_pedido ?? "") === t && !x.da_plataforma).map((x) => [x.alvo, x.texto])));
  }, []);
  useEffect(() => { void carregar(tipo); }, [carregar, tipo]);
  async function salvar(alvo: string) {
    const r = await rpc<Record<string, string>>("salvar_rotulo", { p_alvo: alvo, p_texto: ed[alvo] ?? "", p_tipo_pedido: tipo });
    if (r) { aplicarRotulos(r); toast("Nome salvo.", "ok"); void carregar(tipo); }
  }
  const linha = (alvo: string, padrao: string) => {
    const base = tipo ? geral[alvo] || padrao : padrao;
    return (
      <div key={alvo} className="nome-proprio">
        <span className="dica">{padrao}</span>
        <input value={ed[alvo] ?? ""} placeholder={base} onChange={(e) => setEd({ ...ed, [alvo]: e.target.value })} />
        <button type="button" className="botao-vidro pequeno" disabled={(ed[alvo] ?? "") === (atual[alvo] ?? "")} onClick={() => salvar(alvo)}><Save size={13} aria-hidden /> Salvar</button>
      </div>
    );
  };
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Os nomes que a sua equipe e os seus clientes veem. Vazio = o nome padrão. O funcionamento continua o mesmo.</p>
      {tipos.length > 1 && <>
        <span className="rotulo">Valem para</span>
        <div className="linha-chips">
          <button type="button" className={`chip${tipo === "" ? " ativo" : ""}`} onClick={() => setTipo("")}>Todos os pedidos</button>
          {tipos.map((t) => <button key={t.chave} type="button" className={`chip${tipo === t.chave ? " ativo" : ""}`} onClick={() => setTipo(t.chave)}>{t.nome}</button>)}
        </div>
        {tipo && <p className="dica" style={{ margin: 0 }}>Só nos pedidos deste tipo. Vazio = o nome de “Todos os pedidos”.</p>}
      </>}
      <section className="bloco"><strong>Tipos de parada</strong>{linha("parada:coleta", "Coleta")}{linha("parada:entrega", "Entrega")}</section>
      <section className="bloco"><strong>Status do pedido</strong>{ALVOS_PEDIDO.map(([s, r]) => linha(`pedido:${s}`, r))}</section>
      <section className="bloco"><strong>Status da rota</strong>{ALVOS_CORRIDA.map(([s, r]) => linha(`rota:${s}`, r))}</section>
    </div>
  );
}

// =====================================================================================================  taxas e bônus
type Regra = {
  id?: string; alvo: "preco" | "pagamento"; nome: string; unidade: string; valor: number; franquia: number; minimo: number | null; maximo: number | null;
  condicoes: { dias?: number[]; de?: string; ate?: string; tipos?: string[]; veiculos?: string[]; urgente?: boolean; km_min?: number | null; km_max?: number | null };
  limitar_ao_valor: boolean; ativo: boolean; ordem: number; da_plataforma?: boolean;
};
const UNIDADES: Record<Regra["alvo"], [string, string][]> = {
  preco: [["fixo", "Valor fixo"], ["km", "Por km"], ["ponto", "Por ponto"], ["coleta", "Por coleta"], ["entrega", "Por entrega"], ["volume", "Por volume"], ["kg", "Por kg"],
          ["pct_subtotal", "% do subtotal"], ["pct_declarado", "% do valor declarado"]],
  pagamento: [["fixo", "Valor fixo"], ["km", "Por km"], ["ponto", "Por ponto"], ["coleta", "Por coleta"], ["entrega", "Por entrega"], ["minuto_parado", "Por minuto parado"], ["pct_rota", "% do valor da rota"]],
};
const DIAS: [number, string][] = [[0, "Dom"], [1, "Seg"], [2, "Ter"], [3, "Qua"], [4, "Qui"], [5, "Sex"], [6, "Sáb"]];
const VEICULOS: [string, string][] = [["moto", "Moto"], ["carro", "Carro"], ["bicicleta", "Bicicleta"], ["van", "Van"], ["outro", "Outro"]];
const moeda = (n: number) => n.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });

export function TaxasEBonus() {
  const conta = useConta();
  const tipos = useTiposPedido();
  const [lista, setLista] = useState<Regra[] | null>(null);
  const [ed, setEd] = useState<Regra | null>(null);
  const carregar = useCallback(async () => setLista((await rpc<Regra[]>("regras_extras_editor")) ?? []), []);
  useEffect(() => { void carregar(); }, [carregar]);
  const nova = (alvo: Regra["alvo"]): Regra => ({ alvo, nome: "", unidade: "fixo", valor: 0, franquia: 0, minimo: null, maximo: null, condicoes: {}, limitar_ao_valor: false, ativo: true, ordem: 0 });
  async function salvar() { if (ed && await rpc("salvar_regra_extra", { p: ed })) { toast("Regra salva.", "ok"); setEd(null); void carregar(); } }
  async function apagar(id: string) { if (await rpc("apagar_regra_extra", { p_id: id }) !== null) { setEd(null); void carregar(); } }
  const pct = (u: string) => u.startsWith("pct_");
  const num = (v: string) => (v.trim() === "" ? null : Number(v.replace(",", ".")));
  const resumo = (r: Regra) => {
    const u = UNIDADES[r.alvo].find(([k]) => k === r.unidade)?.[1] ?? r.unidade;
    const c = r.condicoes ?? {};
    const quando = [c.dias?.length ? c.dias.map((d) => DIAS[d]?.[1]).join(", ") : "", c.de && c.ate ? `${c.de}–${c.ate}` : "", c.veiculos?.length ? c.veiculos.join(", ") : "", c.urgente ? "urgente" : ""].filter(Boolean).join(" · ");
    return `${pct(r.unidade) ? `${r.valor}%` : moeda(r.valor)} · ${u}${r.franquia ? ` (${r.franquia} grátis)` : ""}${quando ? ` · ${quando}` : ""}`;
  };
  if (!lista) return <p className="dica">Carregando…</p>;
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Monte taxas e bônus que o cálculo padrão não tem: espera por minuto, pedágio, seguro sobre o valor declarado, adicional noturno ou de fim de semana, bônus por veículo. Cada regra entra como uma linha a mais na conta.</p>
      {(["preco", "pagamento"] as const).map((alvo) => (
        <section key={alvo} className="bloco">
          <div className="api-titulo"><strong>{alvo === "preco" ? "No preço do cliente" : "No pagamento do motoboy"}</strong>
            <button type="button" className="botao-ouro pequeno" onClick={() => setEd(nova(alvo))}><Plus size={14} aria-hidden /> Nova regra</button></div>
          {ed && ed.alvo === alvo && (
            <div className="catalogo-form vidro">
              <label className="campo"><span>Nome (aparece na conta)</span><input value={ed.nome} placeholder={alvo === "preco" ? "Ex.: Adicional noturno" : "Ex.: Espera na coleta"} onChange={(e) => setEd({ ...ed, nome: e.target.value })} /></label>
              <span className="rotulo">Como cobra</span>
              <div className="linha-chips">{UNIDADES[alvo].map(([u, r]) => <button key={u} type="button" className={`chip${ed.unidade === u ? " ativo" : ""}`} onClick={() => setEd({ ...ed, unidade: u })}>{r}</button>)}</div>
              <div className="linha-campos">
                <label className="campo"><span>{pct(ed.unidade) ? "Percentual (%)" : "Valor (R$)"}</span><input inputMode="decimal" value={String(ed.valor)} onChange={(e) => setEd({ ...ed, valor: num(e.target.value) ?? 0 })} /></label>
                {ed.unidade !== "fixo" && <label className="campo"><span>{pct(ed.unidade) ? "Não cobra até (R$)" : "Grátis até"}</span><input inputMode="decimal" value={String(ed.franquia)} onChange={(e) => setEd({ ...ed, franquia: num(e.target.value) ?? 0 })} /></label>}
                <label className="campo"><span>Mínimo (R$)</span><input inputMode="decimal" value={ed.minimo ?? ""} onChange={(e) => setEd({ ...ed, minimo: num(e.target.value) })} /></label>
                <label className="campo"><span>Máximo (R$)</span><input inputMode="decimal" value={ed.maximo ?? ""} onChange={(e) => setEd({ ...ed, maximo: num(e.target.value) })} /></label>
              </div>
              <span className="rotulo">Quando vale (nada marcado = sempre)</span>
              <Chips opcoes={DIAS} valor={ed.condicoes.dias ?? []} onMudar={(v) => setEd({ ...ed, condicoes: { ...ed.condicoes, dias: v } })} />
              <div className="linha-campos">
                <label className="campo"><span>Das</span><input type="time" value={ed.condicoes.de ?? ""} onChange={(e) => setEd({ ...ed, condicoes: { ...ed.condicoes, de: e.target.value } })} /></label>
                <label className="campo"><span>Até</span><input type="time" value={ed.condicoes.ate ?? ""} onChange={(e) => setEd({ ...ed, condicoes: { ...ed.condicoes, ate: e.target.value } })} /></label>
                <label className="campo"><span>A partir de (km)</span><input inputMode="decimal" value={ed.condicoes.km_min ?? ""} onChange={(e) => setEd({ ...ed, condicoes: { ...ed.condicoes, km_min: num(e.target.value) } })} /></label>
                <label className="campo"><span>Até (km)</span><input inputMode="decimal" value={ed.condicoes.km_max ?? ""} onChange={(e) => setEd({ ...ed, condicoes: { ...ed.condicoes, km_max: num(e.target.value) } })} /></label>
              </div>
              <span className="rotulo">Veículo</span>
              <Chips opcoes={VEICULOS} valor={ed.condicoes.veiculos ?? []} onMudar={(v) => setEd({ ...ed, condicoes: { ...ed.condicoes, veiculos: v } })} />
              {tipos.length > 1 && <><span className="rotulo">Tipos de pedido</span><Chips opcoes={tipos.map((t) => [t.chave, t.nome] as [string, string])} valor={ed.condicoes.tipos ?? []} onMudar={(v) => setEd({ ...ed, condicoes: { ...ed.condicoes, tipos: v } })} /></>}
              <label className="opcao"><span>Só em pedido urgente</span><input type="checkbox" role="switch" checked={ed.condicoes.urgente === true} onChange={(e) => { const c = { ...ed.condicoes }; if (e.target.checked) c.urgente = true; else delete c.urgente; setEd({ ...ed, condicoes: c }); }} /></label>
              {alvo === "pagamento" && <label className="opcao"><span>Respeitar o teto (não passar do valor da rota)</span><input type="checkbox" role="switch" checked={ed.limitar_ao_valor} onChange={(e) => setEd({ ...ed, limitar_ao_valor: e.target.checked })} /></label>}
              <label className="opcao"><span>Ativa</span><input type="checkbox" role="switch" checked={ed.ativo} onChange={(e) => setEd({ ...ed, ativo: e.target.checked })} /></label>
              {conta.dev && !ed.id && <label className="opcao"><span>Vale para todas as empresas (plataforma)</span><input type="checkbox" role="switch" checked={!!ed.da_plataforma} onChange={(e) => setEd({ ...ed, da_plataforma: e.target.checked })} /></label>}
              <div className="linha-botoes">
                <button type="button" className="botao-ouro" disabled={!ed.nome.trim()} onClick={salvar}><Save size={15} aria-hidden /> Salvar</button>
                {ed.id && (!ed.da_plataforma || conta.dev) && <button type="button" className="botao-texto perigo" onClick={() => apagar(ed.id!)}><Trash2 size={14} aria-hidden /> Apagar</button>}
                <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
              </div>
            </div>
          )}
          <div className="catalogo-lista">
            {lista.filter((r) => r.alvo === alvo).map((r) => (
              <div key={r.id} className={`catalogo-linha ${r.ativo ? "" : "inativa"}`}>
                <button type="button" className="catalogo-linha-corpo" disabled={r.da_plataforma && !conta.dev} onClick={() => setEd({ ...r, condicoes: r.condicoes ?? {} })}>
                  <span><strong>{r.nome}</strong><small>{resumo(r)}{r.da_plataforma ? " · da plataforma" : ""}</small></span>
                </button>
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}

// =====================================================================================================  cargos
type Cargo = { id?: string; nome: string; icone?: string | null; permissoes: Record<string, boolean>; acoes: Record<string, boolean>; pessoas?: number };

export function CargosPersonalizados() {
  const [lista, setLista] = useState<Cargo[] | null>(null);
  const [ed, setEd] = useState<Cargo | null>(null);
  const carregar = useCallback(async () => setLista((await rpc<Cargo[]>("cargos_da_empresa")) ?? []), []);
  useEffect(() => { void carregar(); }, [carregar]);
  async function salvar() { if (ed && await rpc("salvar_cargo", { p: ed })) { toast("Cargo salvo. Quem tem este cargo já recebeu as permissões.", "ok"); setEd(null); void carregar(); } }
  async function apagar(id: string) { if (await rpc("apagar_cargo", { p_id: id }) !== null) { setEd(null); void carregar(); } }
  if (!lista) return <p className="dica">Carregando…</p>;
  return (
    <div className="catalogo">
      <p className="dica" style={{ margin: 0 }}>Monte cargos como Atendente, Financeiro ou Despachante. Dê o cargo a um supervisor em Pessoas: ele recebe as permissões do cargo, e as ações desligadas aqui ficam bloqueadas só para ele.</p>
      <button type="button" className="botao-ouro" style={{ alignSelf: "flex-start" }} onClick={() => setEd({ nome: "", permissoes: Object.fromEntries(PERMISSOES_SUPERVISOR.map((p) => [p.chave, p.padrao])), acoes: {} })}>
        <Plus size={16} aria-hidden /> Novo cargo
      </button>
      {ed && (
        <div className="catalogo-form vidro">
          <label className="campo"><span>Nome do cargo</span><input value={ed.nome} placeholder="Ex.: Atendente" onChange={(e) => setEd({ ...ed, nome: e.target.value })} /></label>
          <span className="rotulo">O que pode fazer</span>
          {PERMISSOES_SUPERVISOR.map((p) => (
            <label key={p.chave} className="opcao"><span>{p.rotulo}</span><input type="checkbox" role="switch" checked={ed.permissoes[p.chave] ?? p.padrao} onChange={(e) => setEd({ ...ed, permissoes: { ...ed.permissoes, [p.chave]: e.target.checked } })} /></label>
          ))}
          <span className="rotulo">Ações bloqueadas para este cargo</span>
          <div className="linha-chips">
            {ACOES_GESTOR.map((a) => {
              const bloq = ed.acoes[a.chave] === false;
              return <button key={a.chave} type="button" className={`chip${bloq ? " ativo" : ""}`} title={a.dica} onClick={() => { const n = { ...ed.acoes }; if (bloq) delete n[a.chave]; else n[a.chave] = false; setEd({ ...ed, acoes: n }); }}>{a.rotulo}</button>;
            })}
          </div>
          <div className="linha-botoes">
            <button type="button" className="botao-ouro" disabled={!ed.nome.trim()} onClick={salvar}><Save size={15} aria-hidden /> Salvar</button>
            {ed.id && <button type="button" className="botao-texto perigo" onClick={() => apagar(ed.id!)}><Trash2 size={14} aria-hidden /> Apagar</button>}
            <button type="button" className="botao-texto" onClick={() => setEd(null)}>Cancelar</button>
          </div>
        </div>
      )}
      <div className="catalogo-lista">
        {lista.map((k) => (
          <div key={k.id} className="catalogo-linha">
            <button type="button" className="catalogo-linha-corpo" onClick={() => setEd({ ...k, acoes: k.acoes ?? {} })}>
              <span><strong>{k.nome}</strong><small>{Object.values(k.permissoes).filter(Boolean).length} permissões · {Object.keys(k.acoes ?? {}).length} ações bloqueadas · {k.pessoas ?? 0} pessoa(s)</small></span>
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

/** Pessoas → editar: escolher o cargo de um supervisor. */
export function EscolherCargo({ pessoa, atual, onMudou }: { pessoa: string; atual: string | null; onMudou?: () => void }) {
  const [lista, setLista] = useState<Cargo[]>([]);
  useEffect(() => { void supabase().rpc("cargos_da_empresa").then(({ data }) => setLista((data ?? []) as Cargo[])); }, []);
  if (!lista.length) return null;
  return (
    <label className="campo"><span>Cargo</span>
      <select value={atual ?? ""} onChange={async (e) => { if (await rpc("definir_cargo_pessoa", { p_pessoa: pessoa, p_cargo: e.target.value || null }) !== null) { toast("Cargo aplicado.", "ok"); onMudou?.(); } }}>
        <option value="">Sem cargo (permissões avulsas)</option>
        {lista.map((k) => <option key={k.id} value={k.id}>{k.nome}</option>)}
      </select>
    </label>
  );
}
