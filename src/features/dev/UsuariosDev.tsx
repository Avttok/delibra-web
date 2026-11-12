"use client";

import { useCallback, useEffect, useState } from "react";
import { Activity, Battery, Bike, Building2, Check, CodeXml, Database, KeyRound, Lock, LockOpen, PlugZap, Power, RefreshCw, Search, ShieldCheck, Timer, UserCog, UserRound, Users, Wifi } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";
import { chamar, ExcluirConta } from "@/features/equipe/ContasEquipe";

type Usuario = {
  id: string; nome: string; email: string | null; papeis: string[]; foto: string | null; organizacao_id: string | null; organizacao: string | null; empresa: string | null;
  criado_em: string | null; ultimo_acesso: string | null; bloqueado: boolean | null; modo_teste: boolean | null;
  motoboy: { status: string; versao: string | null; posicao_em: string | null; bateria: number | null; aparelho: string | null; suspenso_ate: string | null } | null;
};
const CARGOS: { p: string; r: string; ic: typeof Bike }[] = [
  { p: "gestor", r: "Gestor", ic: ShieldCheck }, { p: "supervisor", r: "Supervisor", ic: UserCog }, { p: "motoboy", r: "Motoboy", ic: Bike }, { p: "cliente", r: "Cliente", ic: UserRound }, { p: "dev", r: "Dev", ic: CodeXml },
];

function ha(iso: string | null) {
  if (!iso) return "nunca";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? "agora" : s < 3600 ? `há ${Math.floor(s / 60)} min` : s < 86400 ? `há ${Math.floor(s / 3600)} h` : `há ${Math.floor(s / 86400)} d`;
}
function senhaNova() {
  const l = "abcdefghjkmnpqrstuvwxyz", n = "23456789", r = (s: string) => s[Math.floor(Math.random() * s.length)];
  return `${Array.from({ length: 4 }, () => r(l)).join("")}-${Array.from({ length: 4 }, () => r(l)).join("")}-${r(n)}${r(n)}`;
}

/** Todas as contas do sistema, de qualquer empresa, com as ações do Dev. */
export function UsuariosDev() {
  const [busca, setBusca] = useState("");
  const [org, setOrg] = useState("");
  const [cargo, setCargo] = useState("");
  const [lista, setLista] = useState<Usuario[] | null>(null);
  const [orgs, setOrgs] = useState<{ id: string; nome: string }[]>([]);
  const [aberto, setAberto] = useState<string | null>(null);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_usuarios", { p_busca: busca.trim() || null, p_org: org || null, p_limite: 500 });
    if (error) return toast(error.message, "erro");
    setLista((data ?? []) as Usuario[]);
  }, [busca, org]);
  useEffect(() => { const t = setTimeout(() => void carregar(), 250); return () => clearTimeout(t); }, [carregar]);
  useEffect(() => { void supabase().rpc("dev_organizacoes").then(({ data }) => setOrgs(((data ?? []) as { id: string; nome: string }[]).map((o) => ({ id: o.id, nome: o.nome })))); }, []);
  const vis = (lista ?? []).filter((u) => !cargo || u.papeis.includes(cargo));
  const conta = (p: string) => (lista ?? []).filter((u) => u.papeis.includes(p)).length;
  // separados por empresa (sem empresa e Dev por último)
  const grupos = Object.entries(vis.reduce<Record<string, Usuario[]>>((m, u) => { const k = u.organizacao ?? (u.papeis.includes("dev") ? "Plataforma (Dev)" : "Sem empresa"); (m[k] ??= []).push(u); return m; }, {}))
    .sort(([a], [b]) => (a.startsWith("Plataforma") || a === "Sem empresa" ? 1 : 0) - (b.startsWith("Plataforma") || b === "Sem empresa" ? 1 : 0) || a.localeCompare(b));

  return (
    <section className="dev-sec">
      <div className="dev-sec-cabeca">
        <h2><Users size={18} aria-hidden /> Usuários</h2>
        <span className="dica">{lista ? `${vis.length} de ${lista.length} contas` : "Carregando…"}</span>
      </div>
      <div className="dev-filtros">
        <label className="dev-busca"><Search size={15} aria-hidden /><input placeholder="Nome, e-mail ou empresa" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <select value={org} onChange={(e) => setOrg(e.target.value)} aria-label="Empresa"><option value="">Todas as empresas</option>{orgs.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}</select>
        <div className="escolhas" role="radiogroup" aria-label="Cargo">
          <button type="button" className={!cargo ? "ativo" : ""} onClick={() => setCargo("")}>Todos</button>
          {CARGOS.map((c) => <button key={c.p} type="button" className={cargo === c.p ? "ativo" : ""} onClick={() => setCargo(c.p)}>{c.r} <small>{conta(c.p)}</small></button>)}
        </div>
      </div>
      {grupos.map(([nomeOrg, us]) => (
        <div key={nomeOrg} className="dev-usuarios-grupo">
          <h3><Building2 size={14} aria-hidden /> {nomeOrg} <small>{us.length} conta(s)</small></h3>
          <ul className="dev-usuarios">
            {us.map((u) => <LinhaUsuario key={u.id} u={u} orgs={orgs} aberto={aberto === u.id} onAbrir={() => setAberto(aberto === u.id ? null : u.id)} onMudou={() => void carregar()} />)}
          </ul>
        </div>
      ))}
      {lista && !vis.length && <p className="vazio">Ninguém com esse filtro.</p>}
    </section>
  );
}

function LinhaUsuario({ u, orgs, aberto, onAbrir, onMudou }: { u: Usuario; orgs: { id: string; nome: string }[]; aberto: boolean; onAbrir: () => void; onMudou: () => void }) {
  const [papeis, setPapeis] = useState(u.papeis);
  const [ocupado, setOcupado] = useState(false);
  const [senha, setSenha] = useState<string | null>(null);
  useEffect(() => setPapeis(u.papeis), [u.papeis.join()]); // eslint-disable-line react-hooks/exhaustive-deps
  const mudouPapeis = [...papeis].sort().join() !== [...u.papeis].sort().join();
  const online = u.motoboy && u.motoboy.status !== "offline";
  async function rodar(f: () => Promise<string | null>, ok: string) {
    setOcupado(true); const e = await f(); setOcupado(false);
    if (e) return toast(e, "erro");
    toast(ok, "ok"); onMudou();
  }
  const rpc = async (nome: string, args: Record<string, unknown>) => { const { error } = await supabase().rpc(nome, args); return error ? error.message : null; };
  const api = async (rota: string, corpo: unknown) => { const r = await chamar(rota, corpo); return r.ok ? null : (r.erro ?? "Não deu certo."); };

  return (
    <li className={`dev-usuario${aberto ? " aberto" : ""}`}>
      <button type="button" className="dev-usuario-linha" onClick={onAbrir} aria-expanded={aberto}>
        {u.foto ? <img className="avatar" src={u.foto} alt="" /> : <span className="avatar dev-avatar">{u.nome.slice(0, 1).toUpperCase()}</span>}
        <span className="dev-usuario-nome"><strong>{u.nome}</strong><small>{u.email ?? "sem e-mail"}</small></span>
        <span className="dev-usuario-org"><Building2 size={12} aria-hidden /> {u.organizacao ?? "Sem empresa"}{u.empresa ? ` · ${u.empresa}` : ""}</span>
        <span className="dev-usuario-selos">
          {u.papeis.map((p) => { const c = CARGOS.find((x) => x.p === p); return c ? <span key={p} className={`dev-selo ${p}`}><c.ic size={11} aria-hidden /> {c.r}</span> : null; })}
          {u.bloqueado && <span className="dev-selo bloqueado"><Lock size={11} aria-hidden /> Bloqueada</span>}
          {online && <span className="dev-selo online"><Wifi size={11} aria-hidden /> {u.motoboy!.status.replace("_", " ")}</span>}
        </span>
        <span className="dev-usuario-quando">{ha(u.ultimo_acesso)}</span>
      </button>
      {aberto && (
        <div className="dev-usuario-painel">
          <div className="dev-usuario-info">
            <span><Timer size={13} aria-hidden /> Criada {u.criado_em ? new Date(u.criado_em).toLocaleDateString("pt-BR") : "—"}</span>
            <span><Activity size={13} aria-hidden /> Último acesso {ha(u.ultimo_acesso)}</span>
            {u.motoboy && <>
              <span><PlugZap size={13} aria-hidden /> App {u.motoboy.versao ?? "—"}{u.motoboy.aparelho ? ` · ${u.motoboy.aparelho}` : ""}</span>
              <span><Battery size={13} aria-hidden /> {u.motoboy.bateria != null ? `${u.motoboy.bateria}%` : "—"} · posição {ha(u.motoboy.posicao_em)}</span>
              {u.motoboy.suspenso_ate && new Date(u.motoboy.suspenso_ate) > new Date() && <span className="erro">Suspenso até {new Date(u.motoboy.suspenso_ate).toLocaleString("pt-BR")}</span>}
            </>}
            <span className="dica">ID {u.id}</span>
          </div>
          <div className="dev-usuario-acoes">
            <div>
              <span className="rotulo">Cargos</span>
              <div className="linha-chips">
                {CARGOS.map((c) => (
                  <label key={c.p} className={`chip-marca${papeis.includes(c.p) ? " ativo" : ""}`}>
                    <input type="checkbox" checked={papeis.includes(c.p)} onChange={(e) => setPapeis((l) => (e.target.checked ? [...l, c.p] : l.filter((x) => x !== c.p)))} /><c.ic size={13} aria-hidden /> {c.r}
                  </label>
                ))}
              </div>
              {mudouPapeis && <button className="botao-ouro" disabled={ocupado} onClick={() => rodar(() => rpc("dev_definir_papeis", { p_id: u.id, p_papeis: papeis }), "Cargos salvos.")}><Check size={14} aria-hidden /> Salvar cargos</button>}
            </div>
            <div>
              <span className="rotulo">Empresa</span>
              <select defaultValue={u.organizacao_id ?? ""} disabled={ocupado} onChange={(e) => rodar(() => rpc("dev_mover_pessoa", { p_usuario: u.id, p_org: e.target.value || null }), "Conta movida de empresa.")}>
                <option value="">Sem empresa</option>{orgs.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
              </select>
            </div>
            <div className="linha-botoes">
              <button className="botao-texto" disabled={ocupado} onClick={() => { const s = senhaNova(); void rodar(async () => { const e = await api("/api/equipe/senha", { id: u.id, senha: s }); if (!e) setSenha(s); return e; }, "Senha trocada."); }}><KeyRound size={14} aria-hidden /> Nova senha</button>
              <button className="botao-texto" disabled={ocupado} onClick={() => rodar(() => api("/api/equipe/bloquear", { id: u.id, bloquear: !u.bloqueado }), u.bloqueado ? "Conta liberada." : "Conta bloqueada.")}>
                {u.bloqueado ? <><LockOpen size={14} aria-hidden /> Liberar</> : <><Lock size={14} aria-hidden /> Bloquear</>}</button>
              {online && <button className="botao-texto" disabled={ocupado} onClick={() => rodar(() => rpc("dev_forcar_offline", { p_motoboy: u.id }), "Motoboy ficou offline.")}><Power size={14} aria-hidden /> Deixar offline</button>}
            </div>
            {senha && <pre className="acesso-criado">{`E-mail: ${u.email}\nSenha: ${senha}`}</pre>}
            {!u.papeis.includes("dev") && <ExcluirConta id={u.id} nome={u.nome} email={u.email ?? ""} onExcluida={onMudou} />}
          </div>
        </div>
      )}
    </li>
  );
}

type Saude = {
  banco_mb: number; tabelas: { nome: string; mb: number; linhas: number }[]; pings_1h: number; pings_24h: number; motoboys_online: number; contas: number; empresas: number;
  rotas_ativas: number; emergencias_abertas?: number; mensagens_24h?: number; tarefas?: { nome: string; quando: string; ativa: boolean; ultima: string | null; falhas_24h: number; erro: string | null }[];
  migracoes?: { nome: string; em: string }[];
};

/** Saúde do sistema: banco, GPS, tarefas automáticas e migrações, com ferramentas de manutenção. */
export function SaudeDev() {
  const [s, setS] = useState<Saude | null>(null);
  const [ocupado, setOcupado] = useState(false);
  const carregar = useCallback(async () => {
    const { data, error } = await supabase().rpc("dev_saude");
    if (error) return toast(error.message, "erro");
    setS(data as Saude);
  }, []);
  useEffect(() => { void carregar(); const t = setInterval(() => void carregar(), 60_000); return () => clearInterval(t); }, [carregar]);
  async function afinar() {
    setOcupado(true);
    const { data, error } = await supabase().rpc("dev_afinar_gps");
    setOcupado(false);
    if (error) return toast(error.message, "erro");
    const d = data as { rotas: number; fora_de_rota: number };
    toast(`GPS afinado: ${d.rotas.toLocaleString("pt-BR")} pontos de rotas antigas e ${d.fora_de_rota.toLocaleString("pt-BR")} fora de rota saíram.`, "ok");
    void carregar();
  }
  if (!s) return <p className="dica">Carregando a saúde do sistema…</p>;
  const maxMb = Math.max(1, ...s.tabelas.map((t) => t.mb));
  const tarefas = s.tarefas ?? [];
  const falhando = tarefas.filter((t) => t.falhas_24h > 0).length;
  return (
    <section className="dev-sec">
      <div className="dev-sec-cabeca">
        <h2><Activity size={18} aria-hidden /> Saúde do sistema</h2>
        <button className="botao-texto" onClick={() => void carregar()}><RefreshCw size={14} aria-hidden /> Atualizar</button>
      </div>
      <div className="dev-grade">
        <div className="dev-num"><strong>{s.banco_mb.toLocaleString("pt-BR")} MB</strong><span>Banco</span></div>
        <div className="dev-num"><strong>{s.pings_1h.toLocaleString("pt-BR")}</strong><span>Pings na última hora</span></div>
        <div className="dev-num"><strong>{s.pings_24h.toLocaleString("pt-BR")}</strong><span>Pings em 24 h</span></div>
        <div className="dev-num"><strong>{s.motoboys_online}</strong><span>Motoboys online</span></div>
        <div className="dev-num"><strong>{s.rotas_ativas}</strong><span>Rotas na rua</span></div>
        <div className="dev-num"><strong>{s.contas}</strong><span>Contas</span></div>
        <div className="dev-num"><strong>{s.empresas}</strong><span>Empresas</span></div>
        <div className={`dev-num${falhando ? " ruim" : ""}`}><strong>{falhando ? `${falhando} com falha` : "Tudo certo"}</strong><span>Tarefas automáticas</span></div>
      </div>

      <div className="dev-duas">
        <div className="bloco">
          <span className="rotulo"><Database size={12} aria-hidden /> Maiores tabelas</span>
          <ul className="dev-barras">{s.tabelas.map((t) => (
            <li key={t.nome}><span>{t.nome}</span><i><em style={{ width: `${(t.mb / maxMb) * 100}%` }} /></i><small>{t.mb.toLocaleString("pt-BR")} MB · {Math.max(0, t.linhas).toLocaleString("pt-BR")} linhas</small></li>
          ))}</ul>
          <div className="linha-botoes">
            <button className="botao-ouro" disabled={ocupado} onClick={afinar}><Activity size={14} aria-hidden /> {ocupado ? "Afinando…" : "Afinar GPS agora"}</button>
            <span className="dica">Tira pontos repetidos de rotas antigas e deixa um ponto a cada intervalo fora de rota (Ajustes → Rastreamento).</span>
          </div>
        </div>
        <div className="bloco">
          <span className="rotulo"><Timer size={12} aria-hidden /> Tarefas automáticas</span>
          {tarefas.length === 0 ? <p className="dica">O agendador não respondeu (ou não está instalado).</p> : (
            <table className="dev-tabela"><thead><tr><th>Tarefa</th><th>Quando</th><th>Última</th><th>Falhas 24 h</th></tr></thead>
              <tbody>{tarefas.map((t) => <tr key={t.nome} title={t.erro ?? undefined}><td>{t.ativa ? "" : "⏸ "}{t.nome.replace("pwex-", "")}</td><td>{t.quando}</td><td>{ha(t.ultima)}</td><td className={t.falhas_24h ? "erro" : ""}>{t.falhas_24h}</td></tr>)}</tbody>
            </table>
          )}
          {(s.migracoes ?? []).length > 0 && <>
            <span className="rotulo" style={{ marginTop: 10 }}>Últimas atualizações do banco</span>
            <ul className="dev-lista-simples">{s.migracoes!.map((m) => <li key={m.nome}><span>{m.nome.replace(/^\d+_/, "").replace(/_/g, " ").replace(".sql", "")}</span><small>{new Date(m.em).toLocaleString("pt-BR")}</small></li>)}</ul>
          </>}
        </div>
      </div>
    </section>
  );
}
