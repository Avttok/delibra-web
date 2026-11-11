"use client";

import { BotaoCompartilhar } from "@/features/chat/PaginaChat";
import { Penalidades } from "@/features/penalidades/Penalidades";
import { Gavel } from "lucide-react";
import { useEffect, useState } from "react";
import { AlertTriangle, Building2, CalendarClock, CheckCircle2, CircleDot, CreditCard, ExternalLink, FlaskConical, Inbox, KeyRound, Layers, MapPin, Plus, Save, Search, Star, Trash2, UserPlus, UserRound, Wallet, X } from "lucide-react";
import { Icone, SeletorIcone } from "@/features/ui/icones";
import { RegrasDoAlvo } from "@/features/configuracoes/Excecoes";
import { CatalogoZonas } from "@/features/configuracoes/Catalogos";
import { CadastrosPendentes } from "./CadastrosPendentes";
import { toast } from "@/features/ui/toast";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { supabase } from "@/lib/supabase/client";
import { geo } from "@/features/geo";
import { useEmpresas, useEquipe } from "@/features/corridas/dados";
import { ROTULO_MODALIDADE, VALOR_KM_PADRAO, moeda, type Modalidade } from "@/features/precos/estrategias";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { combina } from "@/features/ui/busca";
import { MapaCorridas } from "@/features/corridas/MapaCorridas";
import type { Empresa } from "@/features/corridas/tipos";
import type { DadosCnpj } from "@/lib/cnpj/consulta";

interface Formulario {
  nome: string;
  cnpj: string;
  razao_social: string;
  nome_fantasia: string;
  situacao: string;
  telefone: string;
  email: string;
  endereco: string;
  lat: number | null;
  lng: number | null;
  instrucoes_coleta: string;
  modalidade_preco: Modalidade;
  valor_km: string;
  valor_fixo: string;
  cliente_ve_ao_vivo: boolean;
  observacoes: string;
  favoritos: string[]; // ordem de prioridade
  dados_receita: unknown | null;
  tipo: "pj" | "pf";
  cpf: string;
  pode_express: boolean;
  repasse_pct: string;
  dev_pct: string;
  metodos: string[];
  icone: string | null;
  modo_teste: boolean;
}

const vazio: Formulario = {
  nome: "", cnpj: "", razao_social: "", nome_fantasia: "", situacao: "", telefone: "", email: "",
  endereco: "", lat: null, lng: null, instrucoes_coleta: "",
  modalidade_preco: "por_km", valor_km: String(VALOR_KM_PADRAO), valor_fixo: "", cliente_ve_ao_vivo: false,
  observacoes: "", favoritos: [], dados_receita: null,
  tipo: "pj", cpf: "", pode_express: false, repasse_pct: "", dev_pct: "", metodos: ["pix", "cartao"], icone: null, modo_teste: false,
};

function formatarCpf(s: string) {
  const d = s.replace(/\D/g, "").slice(0, 11);
  return d.replace(/^(\d{3})(\d)/, "$1.$2").replace(/^(\d{3})\.(\d{3})(\d)/, "$1.$2.$3").replace(/\.(\d{3})(\d)/, ".$1-$2");
}
function cpfValido(s: string) {
  const d = s.replace(/\D/g, "");
  if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false;
  const dig = (n: number) => { let t = 0; for (let i = 0; i < n; i++) t += Number(d[i]) * (n + 1 - i); const r = (t * 10) % 11; return r === 10 ? 0 : r; };
  return dig(9) === Number(d[9]) && dig(10) === Number(d[10]);
}

const numero = (s: string) => (s.trim() === "" ? null : Number(s.replace(",", ".")));
const soDigitos = (s: string) => s.replace(/\D/g, "");

function formatarCnpj(s: string) {
  const d = soDigitos(s).slice(0, 14);
  return d.replace(/^(\d{2})(\d)/, "$1.$2").replace(/^(\d{2})\.(\d{3})(\d)/, "$1.$2.$3")
    .replace(/\.(\d{3})(\d)/, ".$1/$2").replace(/(\d{4})(\d)/, "$1-$2");
}

function formatarTelefone(d: string) {
  return d.length === 11 ? d.replace(/(\d{2})(\d{5})(\d{4})/, "($1) $2-$3") : d.replace(/(\d{2})(\d{4})(\d{4})/, "($1) $2-$3");
}

function textoEndereco(e: DadosCnpj["endereco"]) {
  const rua = [e.logradouro, e.numero].filter(Boolean).join(", ");
  const local = [e.bairro, e.cidade && e.uf ? `${e.cidade} - ${e.uf}` : e.cidade].filter(Boolean).join(", ");
  return [rua, local].filter(Boolean).join(", ");
}

/** Contas de acesso do cliente (entram no painel do cliente com e-mail e senha). */
function AcessosCliente({ empresaId, nome }: { empresaId: string; nome: string }) {
  const [contas, setContas] = useState<{ id: string; nome: string }[]>([]);
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState(() => Math.random().toString(36).slice(2, 6) + "-" + Math.random().toString(36).slice(2, 6) + "-" + Math.floor(10 + Math.random() * 89));
  const [criada, setCriada] = useState<string | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const carregar = async () => {
    const { data } = await supabase().from("perfis").select("id,nome").eq("empresa_id", empresaId);
    setContas((data ?? []) as { id: string; nome: string }[]);
  };
  useEffect(() => { carregar(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [empresaId]);
  async function criar() {
    setErro(null);
    const sb = supabase();
    const { data: s } = await sb.auth.getSession();
    const r = await fetch("/api/equipe/criar", { method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${s.session?.access_token ?? ""}` },
      body: JSON.stringify({ nome, email, senha, papeis: ["cliente"], empresa_id: empresaId }) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) return setErro(j.erro === "email_existe" ? "Esse e-mail já tem conta." : j.erro === "senha_curta" ? "Senha com pelo menos 8 caracteres." : j.erro === "email_invalido" ? "E-mail inválido." : `Não deu certo (${j.erro ?? r.status}).`);
    setCriada(`Delibra · ${window.location.host}\nE-mail: ${email.trim().toLowerCase()}\nSenha: ${senha}`);
    toast("O cliente já pode entrar e fazer pedidos.", "ok", { titulo: "Acesso criado" });
    setEmail("");
    carregar();
  }
  return (
    <section className="secao">
      <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><KeyRound size={17} /></span>
        <div><h3>Acesso do cliente</h3><p className="dica">Com o acesso, o cliente faz pedidos, paga e acompanha pelo site.</p></div></div>
      {contas.length > 0 && <p className="dica">Contas: {contas.map((c) => c.nome).join(", ")}</p>}
      <div className="grade-2">
        <label className="campo"><span>E-mail do cliente</span><input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="cliente@email.com" /></label>
        <label className="campo"><span>Senha inicial</span><input value={senha} onChange={(e) => setSenha(e.target.value)} /></label>
      </div>
      {erro && <p className="erro">{erro}</p>}
      {criada && <pre className="acesso-criado">{criada}</pre>}
      <button className="botao-texto" onClick={criar} disabled={!email.trim()}><UserPlus size={15} aria-hidden /> Criar acesso</button>
    </section>
  );
}

export function PainelEmpresas() {
  const cfgGeral = useConfiguracoes() as unknown as Record<string, unknown>;
  const cfgRepasse = Number(cfgGeral.repasse_motoboy_pct ?? 67.5);
  const { empresas, favoritos, recarregar } = useEmpresas();
  const equipe = useEquipe();
  const [selecionada, setSelecionada] = useState<string | "nova" | null>(null);
  useEffect(() => { const q = new URLSearchParams(window.location.search).get("e"); if (q) setSelecionada(q); }, []);
  const [form, setForm] = useState<Formulario>(vazio);
  const [salvando, setSalvando] = useState(false);
  const [consultando, setConsultando] = useState(false);
  const [localizando, setLocalizando] = useState(false);
  const [msg, setMsg] = useState<{ tipo: "ok" | "erro"; texto: string } | null>(null);
  const [aba, setAba] = useState<"cadastro" | "regras" | "zonas" | "penalidades">("cadastro");

  const [buscaCli, setBuscaCli] = useState("");
  const [filtroCli, setFiltroCli] = useState("todos");
  const clientesVisiveis = empresas.filter((e) => (FILTROS_CLIENTE.find(([k]) => k === filtroCli)?.[2] ?? (() => true))(e)
    && combina(buscaCli, e.nome, e.cnpj, e.cpf, (e as Empresa & { email?: string | null }).email, (e as Empresa & { telefone?: string | null }).telefone, (e as Empresa & { endereco?: string | null }).endereco,
      (e as Empresa & { razao_social?: string | null }).razao_social, (e as Empresa & { nome_fantasia?: string | null }).nome_fantasia));

  async function abrirComoCliente() {
    if (!selecionada || selecionada === "nova") return;
    const { error } = await supabase().rpc("entrar_como_cliente", { p_empresa: selecionada });
    if (error) return toast(error.message, "erro");
    window.open("/entrar", "_blank", "noopener");
    toast(`No site do cliente você está como ${form.nome}${form.modo_teste ? " (modo teste)" : ""}.`, "ok");
  }

  useEffect(() => {
    if (selecionada === "nova" || selecionada === null) { setForm(vazio); setMsg(null); return; }
    const e = empresas.find((x) => x.id === selecionada);
    if (!e) return;
    setForm({
      nome: e.nome, cnpj: e.cnpj ? formatarCnpj(e.cnpj) : "",
      razao_social: e.razao_social ?? "", nome_fantasia: e.nome_fantasia ?? "", situacao: e.situacao ?? "",
      telefone: e.telefone ?? "", email: e.email ?? "", endereco: e.endereco ?? "", lat: e.lat, lng: e.lng,
      instrucoes_coleta: e.instrucoes_coleta ?? "",
      modalidade_preco: e.modalidade_preco,
      valor_km: e.valor_km != null ? String(e.valor_km) : "", valor_fixo: e.valor_fixo != null ? String(e.valor_fixo) : "",
      cliente_ve_ao_vivo: e.cliente_ve_ao_vivo, observacoes: e.observacoes ?? "",
      favoritos: favoritos.filter((f) => f.empresa_id === e.id).sort((a, b) => a.ordem - b.ordem).map((f) => f.motoboy_id),
      dados_receita: null,
      tipo: e.tipo === "pf" ? "pf" : "pj", cpf: e.cpf ? formatarCpf(e.cpf) : "", pode_express: Boolean(e.pode_express),
      repasse_pct: e.repasse_pct != null ? String(e.repasse_pct) : "", dev_pct: e.dev_pct != null ? String(e.dev_pct) : "",
      metodos: e.pagamento_metodos ?? ["pix", "cartao"],
      icone: (e as Empresa & { icone?: string | null }).icone ?? null, modo_teste: Boolean((e as Empresa & { modo_teste?: boolean }).modo_teste),
    });
    setAba("cadastro");
    setMsg(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selecionada]);

  const set = (m: Partial<Formulario>) => setForm((f) => ({ ...f, ...m }));

  async function marcarNoMapa(lat: number, lng: number) {
    set({ lat, lng });
    const texto = await geo.enderecoDoPonto(lat, lng);
    setForm((f) => ({ ...f, endereco: f.endereco.trim() ? f.endereco : texto }));
  }

  async function localizar(texto: string) {
    if (!texto.trim()) return setMsg({ tipo: "erro", texto: "Digite o endereço ou clique no mapa abaixo para marcar a coleta." });
    setLocalizando(true);
    const r = await geo.buscarEnderecos(texto).catch(() => []);
    setLocalizando(false);
    if (r[0]) set({ lat: r[0].lat, lng: r[0].lng });
    else setMsg({ tipo: "erro", texto: "Não encontrei esse endereço no mapa. Ajuste o texto e clique em Localizar." });
  }

  async function consultar() {
    setMsg(null);
    const cnpj = soDigitos(form.cnpj);
    if (cnpj.length !== 14) return setMsg({ tipo: "erro", texto: "Digite os 14 dígitos do CNPJ." });
    setConsultando(true);
    const { data } = await supabase().auth.getSession();
    const r = await fetch(`/api/cnpj/${cnpj}`, { headers: { Authorization: `Bearer ${data.session?.access_token ?? ""}` } });
    setConsultando(false);
    const j = await r.json();
    if (!r.ok) return setMsg({ tipo: "erro", texto: `Consulta falhou: ${j.erro ?? r.status}` });
    const d = j as DadosCnpj;
    const endereco = textoEndereco(d.endereco);
    setForm((f) => ({
      ...f,
      nome: f.nome || d.nomeFantasia || d.razaoSocial || "",
      razao_social: d.razaoSocial ?? "",
      nome_fantasia: d.nomeFantasia ?? "",
      situacao: d.situacao ?? "",
      telefone: f.telefone || (d.telefones[0] ? formatarTelefone(d.telefones[0]) : ""),
      email: f.email || d.emails[0] || "",
      endereco: f.endereco || endereco,
      dados_receita: d.bruto,
    }));
    setMsg({ tipo: "ok", texto: `Dados da Receita carregados (${d.fonte === "receitaws" ? "ReceitaWS" : "BrasilAPI"}).` });
    if (!form.endereco && endereco) localizar(endereco);
  }

  function alternarFavorito(id: string) {
    setForm((f) => ({ ...f, favoritos: f.favoritos.includes(id) ? f.favoritos.filter((x) => x !== id) : [...f.favoritos, id] }));
  }

  async function salvar() {
    setMsg(null);
    if (!form.nome.trim()) return setMsg({ tipo: "erro", texto: "Informe o nome." });
    if (form.tipo === "pj" && form.cnpj && soDigitos(form.cnpj).length !== 14) return setMsg({ tipo: "erro", texto: "CNPJ deve ter 14 dígitos." });
    if (form.tipo === "pf" && form.cpf && !cpfValido(form.cpf)) return setMsg({ tipo: "erro", texto: "CPF inválido." });
    if (form.metodos.length === 0) return setMsg({ tipo: "erro", texto: "Escolha pelo menos um meio de pagamento." });
    setSalvando(true);
    const sb = supabase();
    const linha: Record<string, unknown> = {
      nome: form.nome.trim(),
      tipo: form.tipo,
      cnpj: form.tipo === "pj" && form.cnpj ? soDigitos(form.cnpj) : null,
      cpf: form.tipo === "pf" && form.cpf ? soDigitos(form.cpf) : null,
      pode_express: form.pode_express,
      repasse_pct: numero(form.repasse_pct),
      dev_pct: numero(form.dev_pct),
      pagamento_metodos: form.metodos,
      razao_social: form.razao_social || null,
      nome_fantasia: form.nome_fantasia || null,
      situacao: form.situacao || null,
      telefone: form.telefone || null,
      email: form.email || null,
      endereco: form.endereco || null,
      lat: form.lat,
      lng: form.lng,
      instrucoes_coleta: form.instrucoes_coleta || null,
      modalidade_preco: form.modalidade_preco,
      valor_km: numero(form.valor_km) ?? VALOR_KM_PADRAO,
      valor_fixo: numero(form.valor_fixo),
      cliente_ve_ao_vivo: form.cliente_ve_ao_vivo,
      observacoes: form.observacoes.trim() || null,
      icone: form.icone,
      modo_teste: form.modo_teste,
    };
    if (form.dados_receita) { linha.dados_receita = form.dados_receita; linha.consultado_em = new Date().toISOString(); }
    const r = selecionada && selecionada !== "nova"
      ? await sb.from("empresas").update(linha).eq("id", selecionada).select("id").single()
      : await sb.from("empresas").insert(linha).select("id").single();
    if (r.error) {
      setSalvando(false);
      return setMsg({ tipo: "erro", texto: r.error.code === "23505" ? "Já existe empresa com esse CNPJ." : r.error.message });
    }
    const id = (r.data as { id: string }).id;
    await sb.from("empresa_favoritos").delete().eq("empresa_id", id);
    if (form.favoritos.length) {
      await sb.from("empresa_favoritos").insert(form.favoritos.map((m, i) => ({ empresa_id: id, motoboy_id: m, ordem: i })));
    }
    setSalvando(false);
    setSelecionada(id);
    recarregar();
    setMsg({ tipo: "ok", texto: "Salvo." });
  }

  async function excluir() {
    if (!selecionada || selecionada === "nova") return;
    if (!confirm("Excluir esta empresa? As corridas antigas ficam, mas sem vínculo.")) return;
    const { error } = await supabase().from("empresas").delete().eq("id", selecionada);
    if (error) return setMsg({ tipo: "erro", texto: error.message });
    setSelecionada(null);
    recarregar();
  }

  const descricaoPreco = (e: Empresa) =>
    e.modalidade_preco === "por_km" ? `${moeda(e.valor_km)}/km` : e.modalidade_preco === "fixo" ? moeda(e.valor_fixo) : "Por zona";
  const inativa = form.situacao && form.situacao !== "ATIVA";

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={Building2} titulo="Clientes" subtitulo={empresas.length === 1 ? "1 cliente cadastrado" : `${empresas.length} clientes cadastrados`} />
        <button className="botao-ouro" onClick={() => setSelecionada("nova")}><Plus size={17} aria-hidden /> Novo cliente</button>
        <CadastrosPendentes onAprovado={(id) => { recarregar(); if (id) setSelecionada(id); }} />
        {empresas.length > 0 && <>
          <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Nome, CNPJ/CPF, e-mail, telefone…" value={buscaCli} onChange={(e) => setBuscaCli(e.target.value)} /></label>
          <div className="fichas-filtro">
            {FILTROS_CLIENTE.map(([k, r, f]) => <button key={k} type="button" className={filtroCli === k ? "ativo" : ""} onClick={() => setFiltroCli(k)}>{r}{k !== "todos" && <small>{empresas.filter(f).length}</small>}</button>)}
          </div>
        </>}
        {empresas.length > 0 && clientesVisiveis.length === 0 && <p className="vazio">Nenhum cliente encontrado.</p>}
        {clientesVisiveis.map((e) => (
          <button key={e.id} className={`cartao-motoboy ${selecionada === e.id ? "selecionado" : ""}`} onClick={() => setSelecionada(e.id)}>
            <div className="linha">
              <Icone nome={(e as Empresa & { icone?: string | null }).icone} padrao={e.tipo === "pf" ? UserRound : Building2} size={15} style={{ color: "var(--ouro)" }} />
              <strong>{e.nome}</strong>
              {(e as Empresa & { modo_teste?: boolean }).modo_teste && <FlaskConical size={13} aria-label="cliente de teste" style={{ color: "#a78bfa" }} />}
              <span className="espaco" />
              <span className="selo" style={{ color: "var(--ouro)" }}>{descricaoPreco(e)}</span>
            </div>
            <div className="detalhes">
              <span>{e.tipo === "pf" ? <><UserRound size={12} aria-hidden /> {e.cpf ? formatarCpf(e.cpf) : "Pessoa física"}</> : e.cnpj ? formatarCnpj(e.cnpj) : "Empresa"}</span>
              {!e.pode_express && <span><CalendarClock size={12} aria-hidden /> só agendado</span>}
              <span><Star size={12} aria-hidden /> {favoritos.filter((f) => f.empresa_id === e.id).length}</span>
              {e.lat != null && <span><MapPin size={12} aria-hidden /> coleta padrão</span>}
              {e.situacao && e.situacao !== "ATIVA" && <span style={{ color: "var(--vermelho)" }}><AlertTriangle size={12} aria-hidden /> {e.situacao}</span>}
            </div>
          </button>
        ))}
      </aside>

      <main className="conteudo">
        {selecionada === null ? (
          <div className="formulario vidro entrar"><p className="vazio">Selecione um cliente ou cadastre um novo.</p></div>
        ) : (
          <div className="formulario vidro entrar" key={selecionada}>
            <div className="titulo-linha">
              <SeletorIcone valor={form.icone} onMudar={(v) => set({ icone: v })} padrao={form.tipo === "pf" ? UserRound : Building2} rotulo="Ícone do cliente" />
              <h2 className="display" style={{ margin: 0, flex: 1 }}>{selecionada === "nova" ? "Novo cliente" : form.nome}</h2>
              {selecionada !== "nova" && <button className="botao-texto" onClick={abrirComoCliente} title="Abre o site do cliente como se fosse ele"><ExternalLink size={15} aria-hidden /> Ver como cliente</button>}
              {selecionada && selecionada !== "nova" && <BotaoCompartilhar rotulo="Compartilhar" anexo={{ tipo: "cliente", id: selecionada, titulo: form.nome, sub: form.endereco ?? undefined }} />}
            </div>
            {selecionada !== "nova" && (
              <div className="segmentado segmentado-rolavel" style={{ maxWidth: 520 }}>
                <button type="button" className={aba === "cadastro" ? "ativo" : ""} onClick={() => setAba("cadastro")}><Building2 size={14} aria-hidden /> Cadastro</button>
                <button type="button" className={aba === "regras" ? "ativo" : ""} onClick={() => setAba("regras")}><Layers size={14} aria-hidden /> Regras</button>
                <button type="button" className={aba === "zonas" ? "ativo" : ""} onClick={() => setAba("zonas")}><CircleDot size={14} aria-hidden /> Zonas</button>
                <button type="button" className={aba === "penalidades" ? "ativo" : ""} onClick={() => setAba("penalidades")}><Gavel size={14} aria-hidden /> Penalidades</button>
              </div>
            )}
            {aba === "regras" && selecionada !== "nova" && <RegrasDoAlvo escopo="cliente" alvo={selecionada} nome={form.nome} />}
            {aba === "zonas" && selecionada !== "nova" && <CatalogoZonas clienteId={selecionada} />}
            {aba === "penalidades" && selecionada !== "nova" && <Penalidades alvoTipo="cliente" alvoId={selecionada} nome={form.nome} />}
            {(aba === "cadastro" || selecionada === "nova") && <>

            <section className="secao">
              <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><Search size={17} /></span><h3>Identificação</h3></div>
              <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
                <button type="button" className={form.tipo === "pj" ? "ativo" : ""} onClick={() => set({ tipo: "pj" })}><Building2 size={15} aria-hidden /> Empresa (CNPJ)</button>
                <button type="button" className={form.tipo === "pf" ? "ativo" : ""} onClick={() => set({ tipo: "pf" })}><UserRound size={15} aria-hidden /> Pessoa (CPF)</button>
              </div>
              {form.tipo === "pf" && (
                <label className="campo curto"><span>CPF</span>
                  <input value={form.cpf} placeholder="000.000.000-00" inputMode="numeric" onChange={(e) => set({ cpf: formatarCpf(e.target.value) })} /></label>
              )}
              {form.tipo === "pj" && <div className="grade-2">
                <label className="campo"><span>CNPJ</span>
                  <input value={form.cnpj} placeholder="00.000.000/0000-00" onChange={(e) => set({ cnpj: formatarCnpj(e.target.value) })} /></label>
                <div className="campo"><span>&nbsp;</span>
                  <button className="botao-texto" type="button" onClick={consultar} disabled={consultando} style={{ justifyContent: "center", padding: "10px" }}>
                    <Search size={15} aria-hidden /> {consultando ? "Consultando…" : "Consultar na Receita"}
                  </button>
                </div>
              </div>}
              {form.razao_social && (
                <div className={`bloco ${inativa ? "alerta-bloco" : ""}`}>
                  <strong>{form.razao_social}</strong>
                  {form.nome_fantasia && <span className="dica">{form.nome_fantasia}</span>}
                  <span className="dica" style={{ display: "flex", alignItems: "center", gap: 6, color: inativa ? "var(--vermelho)" : "var(--verde)" }}>
                    {inativa ? <AlertTriangle size={13} /> : <CheckCircle2 size={13} />} Situação cadastral: {form.situacao || "—"}
                  </span>
                </div>
              )}
              <div className="grade-2">
                <label className="campo"><span>Nome (como aparece no sistema)</span>
                  <input value={form.nome} onChange={(e) => set({ nome: e.target.value })} /></label>
                <label className="campo"><span>Telefone</span>
                  <input value={form.telefone} onChange={(e) => set({ telefone: e.target.value })} /></label>
              </div>
              <label className="campo"><span>E-mail</span>
                <input type="email" value={form.email} onChange={(e) => set({ email: e.target.value })} /></label>
            </section>

            <section className="secao">
              <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><MapPin size={17} /></span>
                <div><h3>Coleta padrão</h3><p className="dica">Preenche a primeira coleta ao lançar uma corrida para esta empresa.</p></div></div>
              <div className="grade-2">
                <label className="campo"><span>Endereço</span>
                  <input value={form.endereco} onChange={(e) => set({ endereco: e.target.value, lat: null, lng: null })} /></label>
                <div className="campo"><span>&nbsp;</span>
                  <button className="botao-texto" type="button" onClick={() => localizar(form.endereco)} disabled={localizando} style={{ justifyContent: "center", padding: "10px" }}>
                    <MapPin size={15} aria-hidden /> {localizando ? "Localizando…" : form.lat != null ? "Localizado ✓" : "Localizar no mapa"}
                  </button>
                </div>
              </div>
              <div className="mapa-mini">
                <MapaCorridas
                  paradas={form.lat != null && form.lng != null ? [{ chave: "coleta", lat: form.lat, lng: form.lng, tipo: "coleta", rotulo: "C" }] : []}
                  aoClicar={marcarNoMapa}
                  modoEscolha
                  enquadrar={form.lat != null ? `${selecionada}-ok` : `${selecionada}`}
                />
              </div>
              <p className="dica">Clique no mapa para marcar (ou ajustar) o ponto exato da coleta.</p>
              <label className="campo"><span>Instruções para a coleta</span>
                <input value={form.instrucoes_coleta} placeholder="Portaria, doca, horário…" onChange={(e) => set({ instrucoes_coleta: e.target.value })} /></label>
            </section>

            <section className="secao">
              <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><Wallet size={17} /></span><h3>Preço</h3></div>
              <div className="checks">
                {(Object.keys(ROTULO_MODALIDADE) as Modalidade[]).map((m) => (
                  <label key={m}><input type="radio" checked={form.modalidade_preco === m} onChange={() => set({ modalidade_preco: m })} /> {ROTULO_MODALIDADE[m]}</label>
                ))}
              </div>
              {form.modalidade_preco === "por_km" && (
                <label className="campo curto"><span>Valor por km (R$)</span>
                  <input inputMode="decimal" value={form.valor_km} onChange={(e) => set({ valor_km: e.target.value })} /></label>
              )}
              {form.modalidade_preco === "fixo" && (
                <label className="campo curto"><span>Valor fixo por corrida (R$)</span>
                  <input inputMode="decimal" value={form.valor_fixo} onChange={(e) => set({ valor_fixo: e.target.value })} /></label>
              )}
              {form.modalidade_preco === "por_zona" && <p className="dica">Tabela de zonas virá numa próxima fase. Por enquanto o valor é digitado na corrida.</p>}
              <label className="opcao"><span>Cliente pode acompanhar o motoboy ao vivo</span>
                <input type="checkbox" checked={form.cliente_ve_ao_vivo} onChange={(e) => set({ cliente_ve_ao_vivo: e.target.checked })} /></label>
            </section>

            <section className="secao">
              <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><CreditCard size={17} /></span>
                <div><h3>Pedidos e pagamento</h3><p className="dica">Pedido do cliente só é despachado depois de pago. Não há pagamento em dinheiro nem na entrega.</p></div></div>
              <label className="opcao"><span><strong><FlaskConical size={14} aria-hidden style={{ color: "#a78bfa" }} /> Cliente de teste</strong><br /><span className="dica">{form.modo_teste ? "Os pedidos dele são de teste (T): só motoboys em modo teste, fora das faturas reais." : "Pedidos reais."}</span></span>
                <input type="checkbox" role="switch" checked={form.modo_teste} onChange={(e) => set({ modo_teste: e.target.checked })} /></label>
              <label className="opcao"><span><strong>Pode pedir Express</strong><br /><span className="dica">{form.pode_express ? "Pede para agora ou agenda." : "Só pedidos agendados (padrão para cliente novo)."}</span></span>
                <input type="checkbox" role="switch" checked={form.pode_express} onChange={(e) => set({ pode_express: e.target.checked })} /></label>
              <div className="checks">
                {[["pix", "PIX"], ["cartao", "Cartão"]].map(([k, r]) => (
                  <label key={k}><input type="checkbox" checked={form.metodos.includes(k)} onChange={(e) => set({ metodos: e.target.checked ? [...form.metodos, k] : form.metodos.filter((x) => x !== k) })} /> {r}</label>
                ))}
              </div>
              <div className="grade-2">
                <label className="campo curto"><span>Motoboy (%) neste cliente</span>
                  <input inputMode="decimal" placeholder={`padrão: ${cfgRepasse}%`} value={form.repasse_pct} onChange={(e) => set({ repasse_pct: e.target.value })} /></label>
              </div>
              <p className="dica">A gestão fica com o restante. Vazio = usa o padrão das Configurações.</p>
            </section>

            {selecionada !== "nova" && <AcessosCliente empresaId={selecionada} nome={form.nome} />}

            <section className="secao">
              <div className="secao-titulo"><span className="cabeca-icone grad-suave" style={{ width: 34, height: 34, borderRadius: 11 }}><Star size={17} /></span>
                <div><h3>Motoboys favoritos</h3><p className="dica">Clique na ordem de prioridade. Eles recebem primeiro na cascata.</p></div></div>
              <div className="favoritos">
                {equipe.length === 0 && <span className="dica">Nenhum motoboy cadastrado.</span>}
                {equipe.map((m) => {
                  const pos = form.favoritos.indexOf(m.id);
                  return (
                    <button key={m.id} type="button" className={`chip ${pos >= 0 ? "ativo" : ""}`} onClick={() => alternarFavorito(m.id)}>
                      {pos >= 0 && <span className="ordem grad">{pos + 1}</span>}
                      {/* eslint-disable-next-line @next/next/no-img-element */}
                      {m.foto && <img src={m.foto} alt="" className="foto-chip" />}
                      {m.nome}
                    </button>
                  );
                })}
              </div>
              <label className="campo"><span>Observações internas</span>
                <textarea rows={3} value={form.observacoes} onChange={(e) => set({ observacoes: e.target.value })} /></label>
            </section>

            {msg && <p className={msg.tipo === "erro" ? "erro" : "sucesso"}>{msg.texto}</p>}
            <div className="linha-botoes">
              <button className="botao-ouro" disabled={salvando} onClick={salvar}><Save size={16} aria-hidden /> {salvando ? "Salvando…" : "Salvar"}</button>
              {selecionada !== "nova" && <button className="botao-perigo" onClick={excluir}><Trash2 size={16} aria-hidden /> Excluir</button>}
            </div>
            </>}
          </div>
        )}
      </main>
    </>
  );
}

const FILTROS_CLIENTE: [string, string, (e: Empresa) => boolean][] = [
  ["todos", "Todos", () => true], ["pj", "Empresas", (e) => e.tipo !== "pf"], ["pf", "Pessoas", (e) => e.tipo === "pf"],
  ["express", "Express", (e) => e.pode_express !== false], ["agendados", "Só agendados", (e) => e.pode_express === false],
  ["teste", "Teste", (e) => Boolean((e as Empresa & { modo_teste?: boolean }).modo_teste)],
];
