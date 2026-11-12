"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import {
  BadgePercent, Building2, CalendarRange, Check, ChevronDown, CodeXml, Eye, EyeOff, Handshake, MessagesSquare, Plus, Receipt, Route, Save, Siren, Trash2, Users,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { IconeEmpresa } from "@/features/empresa/IconeEmpresa";

const brl = (v: number | string | null | undefined) => Number(v ?? 0).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const num = (v: number | string | null | undefined, d = 0) => Number(v ?? 0).toLocaleString("pt-BR", { maximumFractionDigits: d });

export interface Organizacao {
  id: string; nome: string; nome_app?: string | null; nome_topo?: string | null; slug: string | null; documento: string | null; logo_url: string | null; cor: string | null;
  dono_id: string | null; status: "teste" | "ativa" | "suspensa" | "cancelada";
  cobranca_modelo: "percentual" | "licenca" | "isento"; cobranca_pct: number; mensalidade: number; vencimento_dia: number;
  compartilhar: "nunca" | "sem_livre" | "sempre" | "parceiros"; compartilhar_apos_min: number; receber_de_outras: boolean; parceiros: string[];
  observacoes: string | null; criado_em: string;
  cobranca_periodo?: "mensal" | "anual" | "vitalicia"; suspensa_motivo?: string | null; limites?: { motoboys?: number; gestores?: number; clientes?: number } | null;
  rotas_30d?: number; faturado_30d?: number; ultimo_pedido?: string | null;
  dono?: { id: string; nome: string; foto: string | null } | null; gestores?: number; motoboys?: number; online?: number; clientes?: number;
  licenca?: { modelo: string; valor: number; pct: number; inicio: string } | null;
}

const STATUS: Record<Organizacao["status"], { rotulo: string; cor: string }> = {
  teste: { rotulo: "Em teste", cor: "#a78bfa" }, ativa: { rotulo: "Ativa", cor: "#22c55e" },
  suspensa: { rotulo: "Suspensa", cor: "#f59e0b" }, cancelada: { rotulo: "Cancelada", cor: "#ef4444" },
};
const MODELO: Record<Organizacao["cobranca_modelo"], string> = { percentual: "Percentual do faturamento", licenca: "Licença", isento: "Isenta" };
const PERIODO: Record<NonNullable<Organizacao["cobranca_periodo"]>, { rotulo: string; valor: string; sufixo: string }> = {
  mensal: { rotulo: "Mensal", valor: "Valor por mês (R$)", sufixo: "/mês" },
  anual: { rotulo: "Anual", valor: "Valor por ano (R$)", sufixo: "/ano" },
  vitalicia: { rotulo: "Vitalícia", valor: "Valor único (R$)", sufixo: " (vitalícia)" },
};
const ALCANCE: Record<Organizacao["compartilhar"], { rotulo: string; dica: string }> = {
  nunca: { rotulo: "Nunca", dica: "As rotas só vão para os motoboys desta empresa." },
  sem_livre: { rotulo: "Sem motoboy livre", dica: "Se ninguém da empresa pegar, depois do tempo abaixo a rota aparece para motoboys de outras empresas que aceitam receber." },
  sempre: { rotulo: "Sempre", dica: "Motoboys de outras empresas que aceitam receber também veem e recebem as rotas (os da casa continuam primeiro)." },
  parceiros: { rotulo: "Só parceiras", dica: "Só os motoboys das empresas escolhidas como parceiras." },
};

function resumoCobranca(o: Organizacao) {
  return o.cobranca_modelo === "percentual" ? `${num(o.cobranca_pct, 2)}% do faturamento` : o.cobranca_modelo === "licenca" ? `${brl(o.mensalidade)}${PERIODO[o.cobranca_periodo ?? "mensal"].sufixo}` : "Isenta";
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
  // de quais empresas o Dev recebe as emergências
  const [sos, setSos] = useState<string[]>([]);
  useEffect(() => { void supabase().rpc("dev_emergencia_orgs").then(({ data }) => setSos((data as string[]) ?? [])); }, []);
  async function trocarSos(id: string) {
    const { data, error } = await supabase().rpc("dev_emergencia_receber_org", { p_org: id, p_ligar: !sos.includes(id) });
    if (error) return toast(error.message, "erro");
    setSos((data as string[]) ?? []);
    toast(sos.includes(id) ? "Você não recebe mais as emergências desta empresa." : "Você passa a receber as emergências desta empresa.", "ok");
  }

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
              <span><Route size={13} aria-hidden /> {num(o.rotas_30d)} rotas em 30 dias · {brl(o.faturado_30d)}</span>
              <span><Handshake size={13} aria-hidden /> {ALCANCE[o.compartilhar].rotulo}</span>
              <button type="button" className={`botao-texto${sos.includes(o.id) ? " ativo" : ""}`} onClick={() => void trocarSos(o.id)} title="Receber no celular as emergências dos motoboys desta empresa">
                <Siren size={13} aria-hidden /> {sos.includes(o.id) ? "Recebo as emergências" : "Receber emergências"}</button>
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
  // dono novo: cria a conta do gestor junto com a empresa
  const [donoNovo, setDonoNovo] = useState<{ nome: string; email: string } | null>(null);
  const [acesso, setAcesso] = useState<string | null>(null);
  const [licencas, setLicencas] = useState<{ id: string; modelo: string; valor: number; pct: number; inicio: string; fim: string | null; status: string; periodo?: string }[]>([]);
  useEffect(() => {
    if (org) void supabase().rpc("dev_licencas", { p_org: org.id }).then(({ data }) => setLicencas((data as typeof licencas) ?? []));
  }, [org]);
  const muda = <K extends keyof Organizacao>(k: K, v: Organizacao[K]) => setF((x) => ({ ...x, [k]: v }));
  const candidatosDono = pessoas.filter((p) => !p.papeis.includes("dev") && (!p.organizacao_id || p.organizacao_id === org?.id));

  async function salvar() {
    if (!f.nome?.trim()) return toast("Dê um nome para a empresa.", "aviso");
    if (donoNovo && (!donoNovo.nome.trim() || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(donoNovo.email.trim()))) return toast("Preencha o nome e um e-mail válido do gestor.", "aviso");
    setOcupado(true);
    const sb = supabase();
    const { data, error } = await sb.rpc("dev_salvar_organizacao", { p: { ...f, id: org?.id ?? null, ...(donoNovo ? { dono_id: null } : {}) } });
    if (error) { setOcupado(false); return toast(error.message, "erro"); }
    const idOrg = data as string;
    if (donoNovo) {
      const senha = gerarSenhaDono();
      const { data: s } = await sb.auth.getSession();
      const r = await fetch("/api/equipe/criar", { method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${s.session?.access_token ?? ""}` },
        body: JSON.stringify({ nome: donoNovo.nome.trim(), email: donoNovo.email.trim().toLowerCase(), senha, papeis: ["gestor"], organizacao_id: idOrg }) });
      const j = (await r.json().catch(() => ({}))) as { ok?: boolean; id?: string; erro?: string };
      if (!r.ok || !j.id) {
        setOcupado(false);
        return toast(j.erro === "email_existe" ? "Esse e-mail já tem conta. Escolha a pessoa na lista." : `A empresa foi criada, mas a conta do gestor não (${j.erro ?? r.status}).`, "erro");
      }
      await sb.rpc("dev_salvar_organizacao", { p: { ...f, id: idOrg, dono_id: j.id } });
      setAcesso(`${f.nome?.trim()}\nGestor: ${donoNovo.nome.trim()}\nE-mail: ${donoNovo.email.trim().toLowerCase()}\nSenha: ${senha}\nSite: ${window.location.origin}/gestor`);
      setDonoNovo(null);
      setOcupado(false);
      onSalvo(idOrg);
      return;
    }
    setOcupado(false);
    toast(org ? "Empresa atualizada." : "Empresa criada.", "ok", { titulo: "Salvo" });
    onSalvo(idOrg);
    if (!org) onFechar();
  }

  if (acesso) return (
    <div className="empresa-form">
      <p className="dica" style={{ margin: 0 }}>Empresa criada com o gestor. Passe estes dados para ele: a senha não aparece de novo.</p>
      <pre className="acesso-criado">{acesso}</pre>
      <div className="linha-botoes linha-botoes-iguais">
        <button type="button" className="botao-texto" onClick={() => { void navigator.clipboard?.writeText(acesso); toast("Acesso copiado.", "ok"); }}>Copiar acesso</button>
        <button type="button" className="botao" onClick={() => { setAcesso(null); onFechar(); }}>Pronto</button>
      </div>
    </div>
  );

  return (
    <div className="empresa-form">
      {org?.id && (
        <details className="avancado">
          <summary>Ícone e nome do app (no lugar do Delibra)</summary>
          <NomeAppDev org={org} onSalvo={() => onSalvo(org.id)} />
          <IconeEmpresa orgId={org.id} nome={org.nome_app || org.nome} logo={org.logo_url} cor={org.cor} onSalvar={async (logo, extras) => {
            const { error } = await supabase().rpc("dev_marca_organizacao", { p_org: org.id, p: { logo_url: logo ?? "", ...(extras ?? {}) } });
            if (!error) onSalvo(org.id);
            return error?.message ?? null;
          }} />
        </details>
      )}
      <div className="grade-2">
        <label className="campo"><span>Nome</span><input value={f.nome ?? ""} onChange={(e) => muda("nome", e.target.value)} placeholder="Transportadora Exemplo" /></label>
        <label className="campo"><span>CNPJ</span><input value={f.documento ?? ""} onChange={(e) => muda("documento", e.target.value)} inputMode="numeric" /></label>
        <label className="campo"><span>Gestor (dono)</span>
          <select value={donoNovo ? "__novo" : f.dono_id ?? ""} onChange={(e) => {
            if (e.target.value === "__novo") { setDonoNovo({ nome: "", email: "" }); muda("dono_id", null); }
            else { setDonoNovo(null); muda("dono_id", e.target.value || null); }
          }}>
            <option value="">Escolha depois</option>
            <option value="__novo">+ Criar conta nova de gestor</option>
            {candidatosDono.map((p) => <option key={p.id} value={p.id}>{p.nome || p.id.slice(0, 8)}</option>)}
          </select></label>
        {donoNovo && <>
          <label className="campo"><span>Nome do gestor</span><input value={donoNovo.nome} onChange={(e) => setDonoNovo({ ...donoNovo, nome: e.target.value })} placeholder="Pablo" /></label>
          <label className="campo"><span>E-mail do gestor</span><input type="email" value={donoNovo.email} onChange={(e) => setDonoNovo({ ...donoNovo, email: e.target.value })} placeholder="gestor@empresa.com" /></label>
        </>}
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
        {f.cobranca_modelo === "licenca" && <label className="campo"><span>Licença</span>
          <select value={f.cobranca_periodo ?? "mensal"} onChange={(e) => muda("cobranca_periodo", e.target.value as Organizacao["cobranca_periodo"])}>
            {(Object.keys(PERIODO) as NonNullable<Organizacao["cobranca_periodo"]>[]).map((k) => <option key={k} value={k}>{PERIODO[k].rotulo}</option>)}
          </select></label>}
        {f.cobranca_modelo === "licenca" && <label className="campo"><span>{PERIODO[f.cobranca_periodo ?? "mensal"].valor}</span><input type="number" min={0} step={10} value={f.mensalidade ?? 0} onChange={(e) => muda("mensalidade", Number(e.target.value))} /></label>}
        {f.cobranca_modelo !== "isento" && !(f.cobranca_modelo === "licenca" && f.cobranca_periodo === "vitalicia") && <label className="campo"><span>Dia do vencimento</span><input type="number" min={1} max={28} value={f.vencimento_dia ?? 10} onChange={(e) => muda("vencimento_dia", Number(e.target.value))} /></label>}
      </div>
      <p className="dica" style={{ margin: 0 }}>
        {f.cobranca_modelo === "percentual" ? "A plataforma fica com esse percentual de cada rota concluída (sai da parte da empresa, não do motoboy)."
          : f.cobranca_modelo === "licenca" ? (f.cobranca_periodo === "vitalicia" ? "A empresa paga uma vez e usa sem mensalidade. Nenhuma rota tem percentual da plataforma."
            : f.cobranca_periodo === "anual" ? "A empresa paga uma vez por ano. Nenhuma rota tem percentual da plataforma." : "A empresa paga todo mês. Nenhuma rota tem percentual da plataforma.")
          : "Nada é cobrado desta empresa."}
      </p>

      {(f.status === "suspensa" || f.status === "cancelada") && (
        <label className="campo"><span>Motivo (a equipe da empresa vê ao entrar)</span>
          <input value={f.suspensa_motivo ?? ""} onChange={(e) => muda("suspensa_motivo", e.target.value)} placeholder="Ex.: mensalidade em atraso" /></label>
      )}
      {(f.status === "suspensa" || f.status === "cancelada") && <p className="dica" style={{ margin: 0 }}>Suspensa ou cancelada: gestores e motoboys desta empresa ficam sem acesso até você reativar.</p>}

      <span className="rotulo"><Users size={13} aria-hidden /> Limites do plano</span>
      <div className="grade-3">
        {(["motoboys", "gestores", "clientes"] as const).map((k) => (
          <label key={k} className="campo"><span>Máx. de {k}</span>
            <input type="number" min={0} placeholder="sem limite" value={f.limites?.[k] ?? ""}
              onChange={(e) => { const v = e.target.value === "" ? undefined : Math.max(0, Number(e.target.value)); const l = { ...(f.limites ?? {}) }; if (v == null || v === 0) delete l[k]; else l[k] = v; muda("limites", l); }} /></label>
        ))}
      </div>

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

      {org && <DetalheEmpresa org={org} todas={todas} onMudou={() => onSalvo(org.id)} onExcluida={() => { onFechar(); onSalvo(""); }} />}

      {org && licencas.length > 0 && (
        <details className="licencas">
          <summary><Receipt size={13} aria-hidden /> Histórico de cobrança ({licencas.length})</summary>
          <table className="dev-tabela">
            <thead><tr><th>Modelo</th><th>Valor</th><th>De</th><th>Até</th></tr></thead>
            <tbody>{licencas.map((l) => (
              <tr key={l.id}><td>{MODELO[l.modelo as Organizacao["cobranca_modelo"]] ?? l.modelo}{l.modelo === "licenca" && l.periodo ? ` ${PERIODO[l.periodo as "mensal"]?.rotulo.toLowerCase() ?? ""}` : ""}</td>
                <td>{l.modelo === "percentual" ? `${num(l.pct, 2)}%` : l.modelo === "licenca" ? brl(l.valor) : "—"}</td>
                <td>{new Date(l.inicio + "T12:00").toLocaleDateString("pt-BR")}</td><td>{l.fim ? new Date(l.fim + "T12:00").toLocaleDateString("pt-BR") : "valendo"}</td></tr>
            ))}</tbody>
          </table>
        </details>
      )}
    </div>
  );
}

// ===================================================================== Detalhe da empresa
interface DetalheOrg {
  equipe: { id: string; nome: string; foto: string | null; papeis: string[]; email: string | null; ultimo_acesso: string | null; dono: boolean; status: string | null; posicao_em: string | null; versao_app: number | null }[];
  numeros: Record<string, number | string | null>;
  clientes_lista: { id: string; nome: string; pedidos: number }[];
}
const PAPEL: Record<string, string> = { gestor: "Gestor", supervisor: "Supervisor", motoboy: "Motoboy", cliente: "Cliente" };
const quandoFoi = (iso: string | null) => {
  if (!iso) return "nunca";
  const min = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (min < 2) return "agora"; if (min < 60) return `há ${min} min`; if (min < 1440) return `há ${Math.round(min / 60)} h`;
  return new Date(iso).toLocaleDateString("pt-BR");
};

function DetalheEmpresa({ org, todas, onMudou, onExcluida }: { org: Organizacao; todas: Organizacao[]; onMudou: () => void; onExcluida: () => void }) {
  const [d, setD] = useState<DetalheOrg | null>(null);
  const [busca, setBusca] = useState("");
  const [excluir, setExcluir] = useState<{ senha: string; nome: string } | null>(null);
  const carregar = useCallback(() => {
    void supabase().rpc("dev_empresa_detalhe", { p_org: org.id }).then(({ data, error }) => { if (error) toast(error.message, "erro"); else setD(data as DetalheOrg); });
  }, [org.id]);
  useEffect(() => { carregar(); }, [carregar]);
  if (!d) return <p className="dica">Carregando a empresa…</p>;
  const n = d.numeros;
  const equipe = d.equipe.filter((p) => !busca || `${p.nome} ${p.email ?? ""}`.toLowerCase().includes(busca.toLowerCase()));

  async function mover(id: string, destino: string) {
    const { error } = await supabase().rpc("dev_mover_pessoa", { p_usuario: id, p_org: destino || null });
    if (error) return toast(error.message.includes("limite_") ? "A empresa de destino chegou ao limite do plano." : error.message, "erro");
    toast("Pessoa movida.", "ok"); carregar(); onMudou();
  }
  async function confirmarExclusao() {
    if (!excluir) return;
    const { data, error } = await supabase().rpc("dev_excluir_organizacao", { p_org: org.id, p_senha: excluir.senha, p_confirmar: excluir.nome });
    const r = data as { ok?: boolean; erro?: string; restantes?: number; contas_sem_empresa?: number } | null;
    if (error) return toast(error.message.includes("confirmacao_errada") ? "Digite o nome da empresa exatamente como está." : error.message, "erro");
    if (r?.erro) return toast(r.erro === "senha_incorreta" ? `Senha incorreta (${r.restantes} tentativas).` : "Muitas tentativas. Espere 15 minutos.", "erro");
    toast(`Empresa excluída. ${r?.contas_sem_empresa ?? 0} conta(s) ficaram sem empresa.`, "ok");
    onExcluida();
  }

  return (
    <div className="empresa-detalhe">
      <div className="dev-grade">
        <div className="dev-num"><strong>{num(n.pedidos_30d)}</strong><span>Pedidos 30 dias</span></div>
        <div className="dev-num"><strong>{num(n.rotas_30d)}</strong><span>Rotas 30 dias</span></div>
        <div className="dev-num"><strong>{brl(n.faturado_30d)}</strong><span>Faturado 30 dias</span></div>
        <div className="dev-num"><strong>{brl(n.faturado_total)}</strong><span>Faturado total</span></div>
        <div className="dev-num"><strong>{num(n.em_andamento)}</strong><span>Rotas agora</span></div>
        <div className="dev-num"><strong>{num(n.clientes)}</strong><span>Clientes</span></div>
        <div className="dev-num"><strong>{num(n.zonas)}</strong><span>Zonas</span></div>
        <div className="dev-num"><strong>{quandoFoi(n.ultimo_pedido as string | null)}</strong><span>Último pedido</span></div>
      </div>

      <span className="rotulo"><Users size={13} aria-hidden /> Equipe ({d.equipe.length})</span>
      {d.equipe.length > 6 && <label className="busca-mini"><input placeholder="Buscar na equipe" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>}
      <div className="lista-simples">
        {equipe.length === 0 && <p className="dica" style={{ margin: 0 }}>Ninguém nesta empresa ainda.</p>}
        {equipe.map((p) => (
          <div key={p.id} className="linha-item">
            <span>
              <strong>{p.nome || "Sem nome"}</strong>{p.dono && <small className="selo" style={{ color: "var(--ouro)" }}>dono</small>}
              <span className="dica"> · {p.papeis.map((x) => PAPEL[x] ?? x).join(", ")}{p.email ? ` · ${p.email}` : ""}</span>
              <span className="dica" style={{ display: "block" }}>Entrou {quandoFoi(p.ultimo_acesso)}{p.versao_app ? ` · app build ${p.versao_app}` : ""}{p.status && p.status !== "offline" ? ` · ${p.status === "em_corrida" ? "em corrida" : "online"}` : ""}</span>
            </span>
            <select aria-label={`Mover ${p.nome}`} value="" onChange={(e) => e.target.value && void mover(p.id, e.target.value === "__nenhuma" ? "" : e.target.value)}>
              <option value="">Mover…</option>
              {todas.filter((o) => o.id !== org.id).map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
              <option value="__nenhuma">Sem empresa</option>
            </select>
          </div>
        ))}
      </div>

      {d.clientes_lista.length > 0 && (
        <details className="avancado">
          <summary><Building2 size={13} aria-hidden /> Clientes ({d.clientes_lista.length})</summary>
          <div className="lista-simples">{d.clientes_lista.map((c) => <div key={c.id} className="linha-item"><span>{c.nome}</span><span className="dica">{num(c.pedidos)} pedidos</span></div>)}</div>
        </details>
      )}

      <details className="avancado perigo">
        <summary><Trash2 size={13} aria-hidden /> Excluir empresa</summary>
        <p className="dica">Apaga a empresa com clientes, pedidos, rotas, faturas, holerites, zonas e chat dela. As contas das pessoas continuam, sem empresa (dá para mover depois). Não dá para desfazer.</p>
        {!excluir ? <button className="botao-texto perigo-texto" onClick={() => setExcluir({ senha: "", nome: "" })}><Trash2 size={14} aria-hidden /> Quero excluir</button> : (
          <div className="grade-2">
            <label className="campo"><span>Digite o nome: {org.nome}</span><input value={excluir.nome} onChange={(e) => setExcluir({ ...excluir, nome: e.target.value })} /></label>
            <label className="campo"><span>Sua senha</span><input type="password" value={excluir.senha} onChange={(e) => setExcluir({ ...excluir, senha: e.target.value })} /></label>
            <div className="linha-botoes">
              <button className="botao-perigo" disabled={excluir.nome !== org.nome || !excluir.senha} onClick={() => void confirmarExclusao()}><Trash2 size={14} aria-hidden /> Excluir de vez</button>
              <button className="botao-texto" onClick={() => setExcluir(null)}>Cancelar</button>
            </div>
          </div>
        )}
      </details>
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

/** Dev: nome do app que esta empresa mostra no lugar de "Delibra". */
function NomeAppDev({ org, onSalvo }: { org: Organizacao; onSalvo: () => void }) {
  const [nome, setNome] = useState(org.nome_app ?? "");
  const [topo, setTopo] = useState(org.nome_topo ?? "");
  const [salvando, setSalvando] = useState(false);
  async function salvar() {
    const v = nome.trim();
    if (v && (v.length < 2 || v.length > 30)) return toast("O nome do app precisa ter de 2 a 30 letras.", "erro");
    setSalvando(true);
    const { error } = await supabase().rpc("dev_marca_organizacao", { p_org: org.id, p: { nome_app: v, nome_topo: topo.trim() } });
    setSalvando(false);
    if (error) return toast(error.message, "erro");
    toast(v ? `O app desta empresa agora se chama ${v}.` : "Voltou a se chamar Delibra.", "ok");
    onSalvo();
  }
  return (
    <div className="grade-2" style={{ alignItems: "flex-end", marginBottom: 10 }}>
      <label className="campo"><span>Nome do app</span><input value={nome} maxLength={30} placeholder="Delibra" onChange={(e) => setNome(e.target.value)} /></label>
      <label className="campo"><span>Texto ao lado da logo (topo)</span><input value={topo} maxLength={30} placeholder={nome || "igual ao nome do app"} onChange={(e) => setTopo(e.target.value)} /></label>
      <button type="button" className="botao" disabled={salvando || (nome.trim() === (org.nome_app ?? "") && topo.trim() === (org.nome_topo ?? ""))} onClick={salvar}>{salvando ? "Salvando…" : "Salvar nomes"}</button>
    </div>
  );
}

/** Senha fácil de ditar (sem l/1, O/0), igual à das contas da equipe. */
function gerarSenhaDono() {
  const letras = "abcdefghjkmnpqrstuvwxyz", numeros = "23456789";
  const pega = (t: string) => t[crypto.getRandomValues(new Uint32Array(1))[0] % t.length];
  const parte = () => Array.from({ length: 4 }, () => pega(letras)).join("");
  return `${parte()}-${parte()}-${Array.from({ length: 2 }, () => pega(numeros)).join("")}`;
}
