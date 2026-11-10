"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  BadgePercent, Building2, CalendarRange, Check, ChevronDown, CodeXml, Eye, EyeOff, Handshake, MessagesSquare, Plus, Receipt, Route, Save, Trash2, Users,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

const brl = (v: number | string | null | undefined) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const num = (v: number | string | null | undefined, d = 0) => Number(v ?? 0).toLocaleString("pt-BR", { maximumFractionDigits: d });

export interface Organizacao {
  id: string; nome: string; slug: string | null; documento: string | null; logo_url: string | null; cor: string | null;
  dono_id: string | null; status: "teste" | "ativa" | "suspensa" | "cancelada";
  cobranca_modelo: "percentual" | "licenca" | "isento"; cobranca_pct: number; mensalidade: number; vencimento_dia: number;
  compartilhar: "nunca" | "sem_livre" | "sempre" | "parceiros"; compartilhar_apos_min: number; receber_de_outras: boolean; parceiros: string[];
  observacoes: string | null; criado_em: string;
  dono?: { id: string; nome: string; foto: string | null } | null; gestores?: number; motoboys?: number; online?: number; clientes?: number;
  licenca?: { modelo: string; valor: number; pct: number; inicio: string } | null;
}

const STATUS: Record<Organizacao["status"], { rotulo: string; cor: string }> = {
  teste: { rotulo: "Em teste", cor: "#a78bfa" }, ativa: { rotulo: "Ativa", cor: "#22c55e" },
  suspensa: { rotulo: "Suspensa", cor: "#f59e0b" }, cancelada: { rotulo: "Cancelada", cor: "#ef4444" },
};
const MODELO: Record<Organizacao["cobranca_modelo"], string> = { percentual: "Percentual do faturamento", licenca: "Licença mensal", isento: "Isenta" };
const ALCANCE: Record<Organizacao["compartilhar"], { rotulo: string; dica: string }> = {
  nunca: { rotulo: "Nunca", dica: "As rotas só vão para os motoboys desta empresa." },
  sem_livre: { rotulo: "Sem motoboy livre", dica: "Se ninguém da empresa pegar, depois do tempo abaixo a rota aparece para motoboys de outras empresas que aceitam receber." },
  sempre: { rotulo: "Sempre", dica: "Motoboys de outras empresas que aceitam receber também veem e recebem as rotas (os da casa continuam primeiro)." },
  parceiros: { rotulo: "Só parceiras", dica: "Só os motoboys das empresas escolhidas como parceiras." },
};

function resumoCobranca(o: Organizacao) {
  return o.cobranca_modelo === "percentual" ? `${num(o.cobranca_pct, 2)}% do faturamento` : o.cobranca_modelo === "licenca" ? `${brl(o.mensalidade)}/mês` : "Isenta";
}

/** Dev: ficar oculto (aparece como "Dev", com o ícone </>, em mapa, equipe, clientes e chat). */
export function DevOculto({ oculto, onMudou }: { oculto: boolean; onMudou: () => void }) {
  const [ocupado, setOcupado] = useState(false);
  return (
    <label className="opcao dev-oculto">
      <span>{oculto ? <EyeOff size={14} aria-hidden /> : <Eye size={14} aria-hidden />} Ficar oculto
        <small className="dica">Ninguém vê seu nome nem sua foto: no chat você aparece como Dev, com o ícone <CodeXml size={11} aria-hidden style={{ verticalAlign: -1 }} />.</small></span>
      <input type="checkbox" role="switch" checked={oculto} disabled={ocupado} onChange={async (e) => {
        setOcupado(true);
        const { error } = await supabase().rpc("dev_ocultar", { p_ocultar: e.target.checked });
        setOcupado(false);
        if (error) return toast(error.message, "erro");
        toast(e.target.checked ? "Você está oculto." : "Você voltou a aparecer.", "ok");
        onMudou();
      }} />
    </label>
  );
}

// ===================================================================== Empresas
export function EmpresasDev() {
  const [lista, setLista] = useState<Organizacao[]>([]);
  const [sel, setSel] = useState<string | "nova" | null>(null);
  const [foco, setFoco] = useState<string | null>(null);
  const [pessoas, setPessoas] = useState<{ id: string; nome: string; organizacao_id: string | null; papeis: string[] }[]>([]);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [{ data }, { data: eu }, { data: ps }] = await Promise.all([
      sb.rpc("dev_organizacoes"),
      sb.auth.getUser().then(async ({ data: u }) => sb.from("perfis").select("org_em_foco").eq("id", u.user?.id ?? "").maybeSingle()),
      sb.from("perfis").select("id,nome,organizacao_id,papeis").order("nome"),
    ]);
    setLista((data as Organizacao[]) ?? []);
    setFoco((eu?.org_em_foco as string | null) ?? null);
    setPessoas((ps as typeof pessoas) ?? []);
  }, []);
  useEffect(() => { void carregar(); }, [carregar]);

  async function focar(id: string | null) {
    const { error } = await supabase().rpc("dev_focar_org", { p_org: id });
    if (error) return toast(error.message, "erro");
    setFoco(id);
    toast(id ? `Os painéis agora mostram só ${lista.find((o) => o.id === id)?.nome}.` : "Os painéis voltaram a mostrar todas as empresas.", "ok");
    setTimeout(() => window.location.reload(), 600);
  }

  const atual = sel && sel !== "nova" ? lista.find((o) => o.id === sel) ?? null : null;
  return (
    <div className="plataforma">
      <div className="plataforma-topo">
        <p className="dica" style={{ margin: 0 }}>Cada empresa é uma transportadora na Delibra, com a própria equipe, clientes, rotas, chat e ajustes. Você vê todas.</p>
        <button className="botao-ouro" onClick={() => setSel("nova")}><Plus size={16} aria-hidden /> Nova empresa</button>
      </div>
      <div className="foco-empresa">
        <span className="rotulo">Os painéis mostram</span>
        <select value={foco ?? ""} onChange={(e) => void focar(e.target.value || null)}>
          <option value="">Todas as empresas</option>
          {lista.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
        </select>
        <span className="dica">Escolher uma empresa faz o mapa, pedidos, equipe e ajustes mostrarem só ela (como se você fosse o gestor dela).</span>
      </div>
      {sel === "nova" && <FormEmpresa org={null} todas={lista} pessoas={pessoas} onFechar={() => setSel(null)} onSalvo={async (id) => { await carregar(); setSel(id); }} />}
      <div className="empresas-lista">
        {lista.length === 0 && <p className="vazio">Nenhuma empresa ainda. Crie a primeira para cadastrar o gestor dela.</p>}
        {lista.map((o) => (
          <div key={o.id} className={`empresa-cartao${sel === o.id ? " aberta" : ""}`}>
            <button type="button" className="empresa-cabeca" onClick={() => setSel(sel === o.id ? null : o.id)}>
              <span className="empresa-logo" style={{ background: o.cor ?? undefined, backgroundImage: o.logo_url ? `url("${o.logo_url}")` : undefined }}>
                {!o.logo_url && o.nome.charAt(0).toUpperCase()}
              </span>
              <span className="empresa-texto">
                <strong>{o.nome}{foco === o.id && <small className="selo" style={{ color: "var(--ouro)" }}><Eye size={11} /> olhando</small>}</strong>
                <span className="dica">{o.dono?.nome ? `Gestor: ${o.dono.nome}` : "Sem gestor"} · {resumoCobranca(o)}</span>
              </span>
              <span className="selo" style={{ color: STATUS[o.status].cor }}>{STATUS[o.status].rotulo}</span>
              <ChevronDown size={16} aria-hidden style={{ transform: sel === o.id ? "rotate(180deg)" : undefined }} />
            </button>
            <div className="empresa-numeros">
              <span><Users size={13} aria-hidden /> {o.motoboys ?? 0} motoboys <small>({o.online ?? 0} online)</small></span>
              <span><Building2 size={13} aria-hidden /> {o.clientes ?? 0} clientes</span>
              <span><Route size={13} aria-hidden /> {ALCANCE[o.compartilhar].rotulo}</span>
            </div>
            {atual?.id === o.id && <FormEmpresa org={o} todas={lista} pessoas={pessoas} onFechar={() => setSel(null)} onSalvo={() => void carregar()} onFocar={() => void focar(o.id)} />}
          </div>
        ))}
      </div>
    </div>
  );
}

function FormEmpresa({ org, todas, pessoas, onFechar, onSalvo, onFocar }: {
  org: Organizacao | null; todas: Organizacao[]; pessoas: { id: string; nome: string; organizacao_id: string | null; papeis: string[] }[];
  onFechar: () => void; onSalvo: (id: string) => void; onFocar?: () => void;
}) {
  const [f, setF] = useState<Partial<Organizacao>>(() => org ?? {
    nome: "", status: "teste", cobranca_modelo: "percentual", cobranca_pct: 5, mensalidade: 0, vencimento_dia: 10,
    compartilhar: "nunca", compartilhar_apos_min: 3, receber_de_outras: false, parceiros: [],
  });
  const [ocupado, setOcupado] = useState(false);
  const [licencas, setLicencas] = useState<{ id: string; modelo: string; valor: number; pct: number; inicio: string; fim: string | null; status: string }[]>([]);
  useEffect(() => {
    if (org) void supabase().rpc("dev_licencas", { p_org: org.id }).then(({ data }) => setLicencas((data as typeof licencas) ?? []));
  }, [org]);
  const muda = <K extends keyof Organizacao>(k: K, v: Organizacao[K]) => setF((x) => ({ ...x, [k]: v }));
  const candidatosDono = pessoas.filter((p) => !p.papeis.includes("dev") && (!p.organizacao_id || p.organizacao_id === org?.id));

  async function salvar() {
    if (!f.nome?.trim()) return toast("Dê um nome para a empresa.", "aviso");
    setOcupado(true);
    const { data, error } = await supabase().rpc("dev_salvar_organizacao", { p: { ...f, id: org?.id ?? null } });
    setOcupado(false);
    if (error) return toast(error.message, "erro");
    toast(org ? "Empresa atualizada." : "Empresa criada.", "ok", { titulo: "Salvo" });
    onSalvo(data as string);
    if (!org) onFechar();
  }

  return (
    <div className="empresa-form">
      <div className="grade-2">
        <label className="campo"><span>Nome</span><input value={f.nome ?? ""} onChange={(e) => muda("nome", e.target.value)} placeholder="Transportadora Exemplo" /></label>
        <label className="campo"><span>CNPJ</span><input value={f.documento ?? ""} onChange={(e) => muda("documento", e.target.value)} inputMode="numeric" /></label>
        <label className="campo"><span>Gestor (dono)</span>
          <select value={f.dono_id ?? ""} onChange={(e) => muda("dono_id", e.target.value || null)}>
            <option value="">Escolha depois</option>
            {candidatosDono.map((p) => <option key={p.id} value={p.id}>{p.nome || p.id.slice(0, 8)}</option>)}
          </select></label>
        <label className="campo"><span>Situação</span>
          <select value={f.status} onChange={(e) => muda("status", e.target.value as Organizacao["status"])}>
            {(Object.keys(STATUS) as Organizacao["status"][]).map((k) => <option key={k} value={k}>{STATUS[k].rotulo}</option>)}
          </select></label>
      </div>

      <span className="rotulo"><BadgePercent size={13} aria-hidden /> Cobrança da plataforma</span>
      <div className="segmentado" style={{ gridTemplateColumns: "repeat(3, 1fr)" }} role="radiogroup">
        {(Object.keys(MODELO) as Organizacao["cobranca_modelo"][]).map((k) => (
          <button key={k} type="button" className={f.cobranca_modelo === k ? "ativo" : ""} onClick={() => muda("cobranca_modelo", k)}>{MODELO[k]}</button>
        ))}
      </div>
      <div className="grade-2">
        {f.cobranca_modelo === "percentual" && <label className="campo"><span>Percentual (%)</span><input type="number" min={0} max={100} step={0.5} value={f.cobranca_pct ?? 5} onChange={(e) => muda("cobranca_pct", Number(e.target.value))} /></label>}
        {f.cobranca_modelo === "licenca" && <label className="campo"><span>Mensalidade (R$)</span><input type="number" min={0} step={10} value={f.mensalidade ?? 0} onChange={(e) => muda("mensalidade", Number(e.target.value))} /></label>}
        {f.cobranca_modelo !== "isento" && <label className="campo"><span>Dia do vencimento</span><input type="number" min={1} max={28} value={f.vencimento_dia ?? 10} onChange={(e) => muda("vencimento_dia", Number(e.target.value))} /></label>}
      </div>
      <p className="dica" style={{ margin: 0 }}>
        {f.cobranca_modelo === "percentual" ? "A plataforma fica com esse percentual de cada rota concluída (sai da parte da empresa, não do motoboy)."
          : f.cobranca_modelo === "licenca" ? "A empresa paga a mensalidade e nenhuma rota tem percentual da plataforma."
          : "Nada é cobrado desta empresa."}
      </p>

      <span className="rotulo"><Handshake size={13} aria-hidden /> Rotas desta empresa chegam a motoboys de outras?</span>
      <div className="segmentado" style={{ gridTemplateColumns: "repeat(4, 1fr)" }} role="radiogroup">
        {(Object.keys(ALCANCE) as Organizacao["compartilhar"][]).map((k) => (
          <button key={k} type="button" className={f.compartilhar === k ? "ativo" : ""} onClick={() => muda("compartilhar", k)}>{ALCANCE[k].rotulo}</button>
        ))}
      </div>
      <p className="dica" style={{ margin: 0 }}>{ALCANCE[f.compartilhar ?? "nunca"].dica}</p>
      {f.compartilhar === "sem_livre" && <label className="campo"><span>Esperar quantos minutos antes de abrir para outras</span><input type="number" min={0} max={240} value={f.compartilhar_apos_min ?? 3} onChange={(e) => muda("compartilhar_apos_min", Number(e.target.value))} /></label>}
      {f.compartilhar === "parceiros" && (
        <div className="linha-chips">
          {todas.filter((o) => o.id !== org?.id).map((o) => {
            const on = (f.parceiros ?? []).includes(o.id);
            return <button key={o.id} type="button" className={`chip${on ? " ativo" : ""}`} onClick={() => muda("parceiros", on ? (f.parceiros ?? []).filter((x) => x !== o.id) : [...(f.parceiros ?? []), o.id])}>{on && <Check size={12} aria-hidden />} {o.nome}</button>;
          })}
          {todas.length < 2 && <span className="dica">Crie outra empresa para escolher parceiras.</span>}
        </div>
      )}
      <label className="opcao"><span>Os motoboys desta empresa recebem rotas de outras empresas</span>
        <input type="checkbox" role="switch" checked={Boolean(f.receber_de_outras)} onChange={(e) => muda("receber_de_outras", e.target.checked)} /></label>
      <label className="campo"><span>Anotações (só você vê)</span><textarea rows={2} value={f.observacoes ?? ""} onChange={(e) => muda("observacoes", e.target.value)} /></label>

      <div className="linha-botoes">
        <button className="botao-ouro" disabled={ocupado} onClick={() => void salvar()}><Save size={15} aria-hidden /> {org ? "Salvar" : "Criar empresa"}</button>
        {onFocar && <button className="botao-texto" onClick={onFocar}><Eye size={15} aria-hidden /> Olhar só esta empresa</button>}
        <button className="botao-texto" onClick={onFechar}>Fechar</button>
      </div>

      {org && licencas.length > 0 && (
        <details className="licencas">
          <summary><Receipt size={13} aria-hidden /> Histórico de cobrança ({licencas.length})</summary>
          <table className="dev-tabela">
            <thead><tr><th>Modelo</th><th>Valor</th><th>De</th><th>Até</th></tr></thead>
            <tbody>{licencas.map((l) => (
              <tr key={l.id}><td>{MODELO[l.modelo as Organizacao["cobranca_modelo"]] ?? l.modelo}</td>
                <td>{l.modelo === "percentual" ? `${num(l.pct, 2)}%` : l.modelo === "licenca" ? brl(l.valor) : "—"}</td>
                <td>{new Date(l.inicio + "T12:00").toLocaleDateString("pt-BR")}</td><td>{l.fim ? new Date(l.fim + "T12:00").toLocaleDateString("pt-BR") : "valendo"}</td></tr>
            ))}</tbody>
          </table>
        </details>
      )}
    </div>
  );
}

// ===================================================================== Faturamento
interface LinhaFat {
  id: string; nome: string; status: Organizacao["status"]; logo: string | null; cor: string | null; modelo: Organizacao["cobranca_modelo"]; pct: number; mensalidade: number;
  rotas: number; entregas: number; pedidos: number; km: number; faturamento: number; repasse: number; gestao: number; receita_dev: number; ticket_medio: number;
  clientes: number; clientes_ativos: number; motoboys: number; motoboys_ativos: number; gestores: number;
  serie: { dia: string; faturamento: number; rotas: number; dev: number }[]; top_clientes: { nome: string; rotas: number; faturamento: number }[];
}
interface Fat { de: string; ate: string; dias: number; totais: Record<string, number>; empresas: LinhaFat[]; serie: { dia: string; faturamento: number; rotas: number; dev: number }[] }

const hoje = () => new Date(new Date().toLocaleString("en-US", { timeZone: "America/Sao_Paulo" }));
const iso = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const PERIODOS: { k: string; rotulo: string; faixa: () => [string, string] }[] = [
  { k: "mes", rotulo: "Este mês", faixa: () => { const h = hoje(); return [iso(new Date(h.getFullYear(), h.getMonth(), 1)), iso(h)]; } },
  { k: "anterior", rotulo: "Mês passado", faixa: () => { const h = hoje(); return [iso(new Date(h.getFullYear(), h.getMonth() - 1, 1)), iso(new Date(h.getFullYear(), h.getMonth(), 0))]; } },
  { k: "30", rotulo: "30 dias", faixa: () => { const h = hoje(); return [iso(new Date(h.getTime() - 29 * 864e5)), iso(h)]; } },
  { k: "ano", rotulo: "Este ano", faixa: () => { const h = hoje(); return [iso(new Date(h.getFullYear(), 0, 1)), iso(h)]; } },
];

function Barras({ serie, campo }: { serie: { dia: string; faturamento: number; dev: number }[]; campo: "faturamento" | "dev" }) {
  const max = Math.max(1, ...serie.map((s) => Number(s[campo] ?? 0)));
  if (!serie.length) return <p className="dica" style={{ margin: 0 }}>Nenhuma rota concluída no período.</p>;
  return (
    <div className="fat-barras" role="img" aria-label="Faturamento por dia">
      {serie.map((s) => (
        <span key={s.dia} title={`${new Date(s.dia + "T12:00").toLocaleDateString("pt-BR")}: ${brl(s[campo])}`} style={{ height: `${Math.max(4, (Number(s[campo] ?? 0) / max) * 100)}%` }} />
      ))}
    </div>
  );
}

export function FaturamentoDev() {
  const [periodo, setPeriodo] = useState("mes");
  const [faixa, setFaixa] = useState<[string, string]>(PERIODOS[0].faixa());
  const [dados, setDados] = useState<Fat | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    setErro(null);
    void supabase().rpc("dev_faturamento", { p_de: faixa[0], p_ate: faixa[1] }).then(({ data, error }) => {
      if (error) return setErro(error.message);
      setDados(data as Fat);
    });
  }, [faixa]);
  const maxRec = useMemo(() => Math.max(1, ...(dados?.empresas ?? []).map((e) => Number(e.receita_dev))), [dados]);

  return (
    <div className="plataforma">
      <div className="fat-periodo">
        <div className="fichas-filtro">
          {PERIODOS.map((p) => <button key={p.k} type="button" className={periodo === p.k ? "ativo" : ""} onClick={() => { setPeriodo(p.k); setFaixa(p.faixa()); }}>{p.rotulo}</button>)}
          <button type="button" className={periodo === "outro" ? "ativo" : ""} onClick={() => setPeriodo("outro")}><CalendarRange size={13} aria-hidden /> Outro</button>
        </div>
        {periodo === "outro" && (
          <div className="linha-botoes">
            <label className="campo"><span>De</span><input type="date" value={faixa[0]} onChange={(e) => setFaixa([e.target.value, faixa[1]])} /></label>
            <label className="campo"><span>Até</span><input type="date" value={faixa[1]} onChange={(e) => setFaixa([faixa[0], e.target.value])} /></label>
          </div>
        )}
      </div>
      {erro && <p className="erro">{erro}</p>}
      {!dados ? <p className="dica">Carregando…</p> : (<>
        <div className="dev-grade">
          <div className="dev-num destaque"><strong>{brl(dados.totais.receita_dev)}</strong><span>Receita da plataforma</span></div>
          <div className="dev-num"><strong>{brl(dados.totais.faturamento)}</strong><span>Faturado pelas empresas</span></div>
          <div className="dev-num"><strong>{num(dados.totais.rotas)}</strong><span>Rotas concluídas</span></div>
          <div className="dev-num"><strong>{num(dados.totais.entregas)}</strong><span>Entregas</span></div>
          <div className="dev-num"><strong>{num(dados.totais.km, 1)} km</strong><span>Rodados</span></div>
          <div className="dev-num"><strong>{num(dados.totais.ativas)} / {num(dados.totais.empresas)}</strong><span>Empresas ativas</span></div>
          <div className="dev-num"><strong>{num(dados.totais.motoboys)}</strong><span>Motoboys</span></div>
          <div className="dev-num"><strong>{num(dados.totais.clientes)}</strong><span>Clientes</span></div>
        </div>
        <section className="fat-bloco">
          <span className="rotulo">Faturamento das empresas por dia</span>
          <Barras serie={dados.serie} campo="faturamento" />
        </section>
        <section className="fat-bloco">
          <span className="rotulo">Quanto cada empresa rende</span>
          {dados.empresas.length === 0 && <p className="vazio">Nenhuma empresa ainda.</p>}
          {dados.empresas.map((e) => (
            <div key={e.id} className={`fat-empresa${aberta === e.id ? " aberta" : ""}`}>
              <button type="button" className="fat-linha" onClick={() => setAberta(aberta === e.id ? null : e.id)}>
                <span className="empresa-logo pequeno" style={{ background: e.cor ?? undefined, backgroundImage: e.logo ? `url("${e.logo}")` : undefined }}>{!e.logo && e.nome.charAt(0)}</span>
                <span className="fat-nome"><strong>{e.nome}</strong><small className="dica">{e.modelo === "percentual" ? `${num(e.pct, 2)}%` : e.modelo === "licenca" ? `${brl(e.mensalidade)}/mês` : "Isenta"} · {num(e.rotas)} rotas · {brl(e.faturamento)}</small></span>
                <span className="fat-medidor"><span style={{ width: `${(Number(e.receita_dev) / maxRec) * 100}%` }} /></span>
                <strong className="fat-valor">{brl(e.receita_dev)}</strong>
              </button>
              {aberta === e.id && (
                <div className="fat-detalhe">
                  <div className="dev-grade">
                    <div className="dev-num"><strong>{brl(e.faturamento)}</strong><span>Faturado</span></div>
                    <div className="dev-num"><strong>{brl(e.repasse)}</strong><span>Para motoboys</span></div>
                    <div className="dev-num"><strong>{brl(e.gestao)}</strong><span>Fica com a empresa</span></div>
                    <div className="dev-num"><strong>{brl(e.ticket_medio)}</strong><span>Ticket médio</span></div>
                    <div className="dev-num"><strong>{num(e.pedidos)}</strong><span>Pedidos</span></div>
                    <div className="dev-num"><strong>{num(e.entregas)}</strong><span>Entregas</span></div>
                    <div className="dev-num"><strong>{num(e.km, 1)} km</strong><span>Rodados</span></div>
                    <div className="dev-num"><strong>{e.motoboys_ativos} / {e.motoboys}</strong><span>Motoboys ativos</span></div>
                    <div className="dev-num"><strong>{e.clientes_ativos} / {e.clientes}</strong><span>Clientes ativos</span></div>
                    <div className="dev-num"><strong>{e.gestores}</strong><span>Gestores e supervisores</span></div>
                  </div>
                  <span className="rotulo">Por dia</span>
                  <Barras serie={e.serie} campo="faturamento" />
                  {e.top_clientes.length > 0 && (<>
                    <span className="rotulo">Maiores clientes</span>
                    <table className="dev-tabela"><tbody>{e.top_clientes.map((c) => <tr key={c.nome}><td>{c.nome}</td><td>{num(c.rotas)} rotas</td><td>{brl(c.faturamento)}</td></tr>)}</tbody></table>
                  </>)}
                </div>
              )}
            </div>
          ))}
        </section>
        <p className="dica">Conta só rotas concluídas e reais (sem modo teste). Licença mensal entra proporcional aos dias do período. O pagamento acontece fora da plataforma.</p>
      </>)}
    </div>
  );
}

// ===================================================================== Conversas
interface ConversaDev {
  id: string; tipo: "geral" | "direta" | "grupo"; nome: string | null; ultima_em: string; ultima_previa: string | null;
  organizacao_id: string | null; organizacao: string | null; mensagens: number; sou_membro: boolean;
  membros: { id: string; nome: string; foto: string | null; papeis: string[] }[];
}

export function ConversasDev() {
  const [lista, setLista] = useState<ConversaDev[]>([]);
  const [aberta, setAberta] = useState<string | null>(null);
  const [msgs, setMsgs] = useState<{ id: string; autor_id: string | null; texto: string | null; anexo: { tipo: string; titulo?: string } | null; criada_em: string; apagada_em: string | null }[]>([]);
  const [busca, setBusca] = useState("");
  const carregar = useCallback(() => supabase().rpc("dev_conversas").then(({ data }) => setLista((data as ConversaDev[]) ?? [])), []);
  useEffect(() => { void carregar(); }, [carregar]);
  useEffect(() => {
    if (!aberta) return setMsgs([]);
    void supabase().from("chat_mensagens").select("id,autor_id,texto,anexo,criada_em,apagada_em").eq("conversa_id", aberta).order("criada_em", { ascending: false }).limit(300)
      .then(({ data }) => setMsgs(((data ?? []) as typeof msgs).reverse()));
  }, [aberta]);

  const nomeDe = (c: ConversaDev) => c.nome ?? (c.tipo === "direta" ? c.membros.map((m) => m.nome).join(" e ") : "Conversa");
  const visiveis = lista.filter((c) => `${nomeDe(c)} ${c.organizacao ?? ""}`.toLowerCase().includes(busca.toLowerCase()));
  const atual = lista.find((c) => c.id === aberta);
  const autor = (id: string | null) => atual?.membros.find((m) => m.id === id)?.nome ?? "Alguém";

  async function apagar(c: ConversaDev) {
    if (!window.confirm(`Apagar "${nomeDe(c)}" e as ${c.mensagens} mensagens? Não dá para desfazer.`)) return;
    const { error } = await supabase().rpc("dev_apagar_conversa", { p_conversa: c.id });
    if (error) return toast(error.message, "erro");
    toast("Conversa apagada.", "ok");
    setAberta(null);
    void carregar();
  }

  return (
    <div className="plataforma">
      <p className="dica" style={{ margin: 0 }}>Todas as conversas da plataforma. Você lê sem aparecer como membro; o que pode ser enviado no chat fica em Ajustes → Comunicação.</p>
      <input className="busca-dev" placeholder="Buscar por nome ou empresa" value={busca} onChange={(e) => setBusca(e.target.value)} />
      <div className="conversas-dev">
        <div className="conversas-dev-lista">
          {visiveis.map((c) => (
            <button key={c.id} type="button" className={`conversa-dev${aberta === c.id ? " ativo" : ""}`} onClick={() => setAberta(c.id)}>
              <MessagesSquare size={15} aria-hidden />
              <span><strong>{nomeDe(c)}</strong><small className="dica">{c.organizacao ?? "Plataforma"} · {c.tipo === "geral" ? "Geral" : c.tipo === "grupo" ? `Grupo de ${c.membros.length}` : "Direta"} · {c.mensagens} msgs</small></span>
            </button>
          ))}
          {visiveis.length === 0 && <p className="vazio">Nenhuma conversa.</p>}
        </div>
        <div className="conversas-dev-ler">
          {!atual ? <p className="vazio">Escolha uma conversa para ler.</p> : (<>
            <div className="linha-botoes" style={{ justifyContent: "space-between" }}>
              <strong>{nomeDe(atual)}</strong>
              <button className="botao-texto perigo" onClick={() => void apagar(atual)}><Trash2 size={14} aria-hidden /> Apagar conversa</button>
            </div>
            <div className="conversas-dev-msgs">
              {msgs.map((m) => (
                <div key={m.id} className="msg-dev">
                  <small className="dica">{autor(m.autor_id)} · {new Date(m.criada_em).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}</small>
                  <p>{m.apagada_em ? <em className="dica">Mensagem apagada{m.texto ? `: ${m.texto}` : ""}</em> : m.texto ?? (m.anexo ? `[${m.anexo.tipo}${m.anexo.titulo ? `: ${m.anexo.titulo}` : ""}]` : "")}</p>
                </div>
              ))}
              {msgs.length === 0 && <p className="vazio">Sem mensagens.</p>}
            </div>
          </>)}
        </div>
      </div>
    </div>
  );
}
