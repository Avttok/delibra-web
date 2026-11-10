"use client";

import { BotaoCompartilhar } from "@/features/chat/PaginaChat";
import { useCallback, useEffect, useRef, useState } from "react";
import { Bike, Building2, FlaskConical, History, Layers, Lock, PencilLine, Route, Save, Search, ShieldCheck, Trophy, UserPlus, UserRound, Users } from "lucide-react";
import { ConquistasMembro } from "./Conquistas";
import { combina } from "@/features/ui/busca";
import { VeiculoMembro } from "./VeiculoMembro";
import { RegrasDoAlvo } from "@/features/configuracoes/Excecoes";
import { SeletorIcone } from "@/features/ui/icones";
import { useEmpresas } from "@/features/corridas/dados";
import { RegistroMembro } from "./RegistroMembro";
import { PercursosMembro } from "./PercursosMembro";
import { BloquearConta, ExcluirConta, NovaConta, RedefinirSenha } from "./ContasEquipe";
import { useSessaoGestor } from "@/features/gestor/AreaGestor";
import { useConta } from "@/features/conta/conta";
import { PERMISSOES_SUPERVISOR, SelosCargo } from "@/features/conta/Cargos";
import { toast } from "@/features/ui/toast";
import { CodeXml, UserCog } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { COR_STATUS, ROTULO_STATUS, type StatusMotoboy } from "@/features/rastreamento/tipos";

interface Membro {
  id: string; email: string; nome: string; foto_url: string | null; papeis: string[];
  status: StatusMotoboy | null; modo_teste: boolean; repasse_pct: number | null;
  bloqueado?: boolean; ultimo_acesso?: string | null;
}

export function PainelEquipe() {
  const cfg = useConfiguracoes();
  const eu = useSessaoGestor()?.user.id;
  const [lista, setLista] = useState<Membro[]>([]);
  const [sel, setSel] = useState<string | null>(null);
  useEffect(() => { const q = new URLSearchParams(window.location.search).get("m"); if (q) setSel(q); }, []);
  const [nome, setNome] = useState("");
  const [gestor, setGestor] = useState(false);
  const [motoboy, setMotoboy] = useState(false);
  const [devPapel, setDevPapel] = useState(false);
  const [supervisor, setSupervisor] = useState(false);
  const [permissoes, setPermissoes] = useState<Record<string, boolean>>({});
  const conta = useConta();
  const [msg, setMsg] = useState<{ ok: boolean; t: string } | null>(null);
  const [aba, setAba] = useState<"registro" | "percursos" | "veiculo" | "medalhas" | "regras" | "editar">("registro");
  const [busca, setBusca] = useState("");
  const [filtro, setFiltro] = useState("todos");
  const { empresas } = useEmpresas();
  const [extra, setExtra] = useState<{ icone: string | null; empresa_id: string | null }>({ icone: null, empresa_id: null });
  const pleno = conta.papeis.includes("gestor") || conta.dev;
  const [criando, setCriando] = useState(false);
  const detalhe = useRef<HTMLDivElement>(null);

  const carregar = useCallback(async () => {
    const { data } = await supabase().rpc("listar_equipe");
    // contas de cliente aparecem no cadastro do cliente, não na equipe
    if (data) setLista((data as Membro[]).filter((m) => !(m.papeis.length === 1 && m.papeis[0] === "cliente")));
  }, []);
  useEffect(() => { carregar(); }, [carregar]);

  const m = lista.find((x) => x.id === sel);
  const fil = FILTROS_EQUIPE.find(([k]) => k === filtro)?.[2] ?? (() => true);
  // em corrida e disponíveis primeiro, offline por último
  const pesoStatus = (m: Membro) => (m.status === "em_corrida" ? 0 : m.status === "disponivel" ? 1 : 2);
  const visiveis = lista.filter((x) => fil(x) && combina(busca, x.nome, x.email)).sort((a, b) => pesoStatus(a) - pesoStatus(b));
  useEffect(() => {
    if (!m) return;
    setNome(m.nome); setGestor(m.papeis.includes("gestor")); setSupervisor(m.papeis.includes("supervisor")); setMotoboy(m.papeis.includes("motoboy")); setDevPapel(m.papeis.includes("dev"));
    setMsg(null);
    supabase().from("perfis").select("icone,empresa_id,permissoes").eq("id", m.id).maybeSingle()
      .then(({ data }) => {
        setExtra({ icone: (data?.icone as string | null) ?? null, empresa_id: (data?.empresa_id as string | null) ?? null });
        setPermissoes((data?.permissoes as Record<string, boolean> | null) ?? {});
      });
    if ((aba === "veiculo" || aba === "regras" || aba === "medalhas") && !m.papeis.includes("motoboy")) setAba("registro");
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sel]);

  async function salvar() {
    if (!m) return;
    const papeis = [devPapel && "dev", gestor && "gestor", supervisor && "supervisor", motoboy && "motoboy", m.papeis.includes("cliente") && "cliente"].filter(Boolean);
    const { error } = await supabase().rpc("editar_membro", {
      p_usuario: m.id, p_nome: nome, p_papeis: papeis, p_repasse: null,
    });
    if (error) return setMsg({ ok: false, t: error.message === "nao_remova_seu_proprio_acesso" ? "Você não pode tirar seu próprio acesso." : error.message === "percentual_invalido" ? "Repasse deve ficar entre 0 e 100%."
      : error.message === "conta_protegida" || error.message === "conta_do_dev_protegida" ? "A conta do Dev só ele mesmo altera." : error.message === "apenas_dev" ? "Só o Dev dá ou tira o cargo Dev."
      : error.message === "apenas_gestor" ? "Só o gestor da empresa dá ou tira os cargos Gestor e Supervisor." : error.message });
    if (supervisor && pleno) {
      const p2 = await supabase().rpc("definir_permissoes", { p_usuario: m.id, p_permissoes: permissoes });
      if (p2.error) return setMsg({ ok: false, t: p2.error.message });
    }
    setMsg(null);
    toast(`${nome || m.email} atualizado.`, "ok", { titulo: "Salvo" });
    carregar();
  }

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={Users} titulo="Equipe" subtitulo={lista.length === 1 ? "1 pessoa" : `${lista.length} pessoas`} />
        {conta.modulo("criar_contas") && <button className="botao-ouro" onClick={() => setCriando(true)}><UserPlus size={17} aria-hidden /> Nova conta</button>}
        {criando && (
          <NovaConta padraoRepasse={Number(cfg.repasse_motoboy_pct)} onFechar={() => setCriando(false)}
            onCriada={async (id) => { setCriando(false); await carregar(); setSel(id); setAba("editar"); }} />
        )}
        <label className="busca-mini"><Search size={14} aria-hidden /><input placeholder="Buscar por nome ou e-mail" value={busca} onChange={(e) => setBusca(e.target.value)} /></label>
        <div className="fichas-filtro">
          {FILTROS_EQUIPE.map(([k, r, f]) => (
            <button key={k} type="button" className={filtro === k ? "ativo" : ""} onClick={() => setFiltro(k)}>{r}{k !== "todos" && <small>{lista.filter(f).length}</small>}</button>
          ))}
        </div>
        {visiveis.length === 0 && <p className="vazio">Ninguém encontrado.</p>}
        {visiveis.map((x) => (
          <button key={x.id} className={`cartao-motoboy ${sel === x.id ? "selecionado" : ""}`} onClick={() => {
            setSel(x.id);
            // no celular o detalhe fica embaixo da lista: leva até ele
            if (window.matchMedia("(max-width: 860px)").matches) setTimeout(() => detalhe.current?.scrollIntoView({ behavior: "smooth", block: "start" }), 50);
          }}>
            <div className="linha">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              {x.foto_url ? <img src={x.foto_url} alt="" className="foto-mini" style={{ borderColor: "var(--ouro)" }} />
                : <span className="avatar grad" style={{ width: 26, height: 26, fontSize: 11 }}>{(x.nome || x.email).charAt(0).toUpperCase()}</span>}
              <strong>{x.nome || x.email}</strong>
            </div>
            <div className="selos">
              <SelosCargo papeis={x.papeis} teste={x.modo_teste} />
              {x.bloqueado && <span className="selo" style={{ color: "var(--vermelho)" }}><Lock size={11} /> Bloqueado</span>}
            </div>
            <div className="detalhes">
              <span>{x.email}</span>
              {x.status && <span style={{ color: COR_STATUS[x.status] }}>{ROTULO_STATUS[x.status]}</span>}
            </div>
          </button>
        ))}
      </aside>
      <main className="conteudo">
        <div className="formulario vidro entrar" ref={detalhe} style={{ maxWidth: 860 }}>
          {!m ? <p className="vazio">Selecione uma pessoa para ver o registro e editar.</p> : (
            <>
              <div className="membro-cabeca">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                {m.foto_url ? <img src={m.foto_url} alt="" className="avatar avatar-foto membro-avatar" />
                  : <span className="avatar grad membro-avatar">{(m.nome || m.email).charAt(0).toUpperCase()}</span>}
                <div style={{ minWidth: 0 }}>
                  <h2 className="display">{m.nome || m.email}</h2>
                  <p className="dica" style={{ margin: "2px 0 6px" }}>{m.email}</p>
                  <BotaoCompartilhar rotulo="Compartilhar" anexo={{ tipo: "pessoa", id: m.id, titulo: m.nome || m.email, sub: m.papeis.join(", ") }} />
                  <div className="selos">
                    <SelosCargo papeis={m.papeis} teste={m.modo_teste} />
                    {m.bloqueado && <span className="selo" style={{ color: "var(--vermelho)" }}><Lock size={11} /> Bloqueado</span>}
                    {m.status && <span className="selo" style={{ color: COR_STATUS[m.status] }}>{ROTULO_STATUS[m.status]}</span>}
                  </div>
                </div>
              </div>

              <div className="segmentado segmentado-rolavel">
                <button type="button" className={aba === "registro" ? "ativo" : ""} onClick={() => setAba("registro")}><History size={15} aria-hidden /> Registro</button>
                {m.papeis.includes("motoboy") && conta.modulo("trilhas_mapa") && <button type="button" className={aba === "percursos" ? "ativo" : ""} onClick={() => setAba("percursos")}><Route size={15} aria-hidden /> Percursos</button>}
                {m.papeis.includes("motoboy") && <button type="button" className={aba === "veiculo" ? "ativo" : ""} onClick={() => setAba("veiculo")}><Bike size={15} aria-hidden /> Veículo</button>}
                {m.papeis.includes("motoboy") && <button type="button" className={aba === "medalhas" ? "ativo" : ""} onClick={() => setAba("medalhas")}><Trophy size={15} aria-hidden /> Medalhas</button>}
                {m.papeis.includes("motoboy") && <button type="button" className={aba === "regras" ? "ativo" : ""} onClick={() => setAba("regras")}><Layers size={15} aria-hidden /> Regras</button>}
                <button type="button" className={aba === "editar" ? "ativo" : ""} onClick={() => setAba("editar")}><PencilLine size={15} aria-hidden /> Editar</button>
              </div>

              {aba === "registro" ? <RegistroMembro key={m.id} id={m.id} /> : aba === "percursos" ? <PercursosMembro key={m.id} id={m.id} teste={Boolean(m.modo_teste)} />
                : aba === "veiculo" ? <VeiculoMembro key={m.id} id={m.id} />
                : aba === "medalhas" ? <ConquistasMembro key={m.id} id={m.id} />
                : aba === "regras" ? <RegrasDoAlvo key={m.id} escopo="motoboy" alvo={m.id} nome={m.nome || m.email} />
                : (m.papeis.includes("dev") && !conta.dev) ? (
                <p className="dica" style={{ margin: 0 }}><CodeXml size={14} style={{ verticalAlign: -2 }} /> Conta Dev: só o Dev altera esta conta.</p>
              ) : (
                <>
                  <div className="linha-icone">
                    <SeletorIcone valor={extra.icone} padrao={UserRound} rotulo="Ícone no mapa (sem foto)" onMudar={async (v) => {
                      setExtra((x) => ({ ...x, icone: v }));
                      const { error } = await supabase().rpc("definir_icone", { p_tipo: "perfil", p_id: m.id, p_icone: v });
                      if (error) toast(error.message, "erro");
                    }} />
                    <label className="campo" style={{ flex: 1 }}><span>Nome de exibição</span><input value={nome} onChange={(e) => setNome(e.target.value)} /></label>
                  </div>
                  <span className="rotulo">Papéis</span>
                  {conta.dev && <label className="opcao"><span><CodeXml size={14} style={{ verticalAlign: -2 }} /> Dev (administra o sistema inteiro)</span><input type="checkbox" checked={devPapel} onChange={(e) => setDevPapel(e.target.checked)} /></label>}
                  {pleno && <label className="opcao"><span><ShieldCheck size={14} style={{ verticalAlign: -2 }} /> Gestor (dono da empresa: pode tudo)</span><input type="checkbox" checked={gestor} onChange={(e) => setGestor(e.target.checked)} /></label>}
                  {pleno && <label className="opcao"><span><UserCog size={14} style={{ verticalAlign: -2 }} /> Supervisor (líder de equipe: só o que você liberar)</span><input type="checkbox" checked={supervisor} onChange={(e) => setSupervisor(e.target.checked)} /></label>}
                  {supervisor && !gestor && pleno && (
                    <div className="permissoes-supervisor">
                      <span className="rotulo">O que este supervisor pode fazer</span>
                      {PERMISSOES_SUPERVISOR.map((x) => (
                        <label key={x.chave} className="opcao"><span>{x.rotulo}</span>
                          <input type="checkbox" role="switch" checked={permissoes[x.chave] ?? x.padrao} onChange={(e) => setPermissoes((p) => ({ ...p, [x.chave]: e.target.checked }))} /></label>
                      ))}
                    </div>
                  )}
                  <label className="opcao"><span><Bike size={14} style={{ verticalAlign: -2 }} /> Motoboy (usa o app e recebe corridas)</span><input type="checkbox" checked={motoboy} onChange={(e) => setMotoboy(e.target.checked)} /></label>
                  {gestor && motoboy && <p className="dica">Gestor + motoboy tem as ferramentas de administrador e o modo teste no app.</p>}
                  {(gestor || devPapel) && (
                    <label className="campo"><span><Building2 size={13} style={{ verticalAlign: -2 }} /> Também é cliente (entra no site do cliente como este cadastro)</span>
                      <select value={extra.empresa_id ?? ""} onChange={async (e) => {
                        const v = e.target.value || null;
                        const { error } = await supabase().rpc("vincular_cliente", { p_usuario: m.id, p_empresa: v });
                        if (error) return toast(error.message, "erro");
                        setExtra((x) => ({ ...x, empresa_id: v }));
                        toast(v ? `Agora ${nome || m.email} também é cliente de ${empresas.find((x) => x.id === v)?.nome ?? ""}.` : "Não é mais cliente.", "ok");
                        carregar();
                      }}>
                        <option value="">Não</option>{empresas.map((x) => <option key={x.id} value={x.id}>{x.nome}</option>)}
                      </select></label>
                  )}
                  {msg && <p className={msg.ok ? "sucesso" : "erro"}>{msg.t}</p>}
                  <div className="linha-botoes">
                    <RedefinirSenha id={m.id} nome={m.nome || m.email} email={m.email} />
                    <button className="botao-ouro" onClick={salvar}><Save size={16} /> Salvar</button>
                  </div>
                  {m.ultimo_acesso && <p className="dica" style={{ margin: 0 }}>Último acesso: {new Date(m.ultimo_acesso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })}</p>}
                  {m.id !== eu ? (
                    <section className="zona-perigo">
                      <span className="rotulo">Zona de perigo</span>
                      <BloquearConta id={m.id} nome={m.nome || m.email} bloqueado={Boolean(m.bloqueado)} onFeito={carregar} />
                      <ExcluirConta id={m.id} nome={m.nome || m.email} email={m.email} onExcluida={async () => { setSel(null); await carregar(); }} />
                    </section>
                  ) : <p className="dica" style={{ margin: 0 }}>Esta é a sua conta: para trocar nome e foto, use o menu da sua foto no topo.</p>}
                </>
              )}
            </>
          )}
        </div>
      </main>
    </>
  );
}

const online = (m: Membro) => m.papeis.includes("motoboy") && m.status != null && m.status !== "offline";
const FILTROS_EQUIPE: [string, string, (m: Membro) => boolean][] = [
  ["todos", "Todos", () => true], ["motoboys", "Motoboys", (m) => m.papeis.includes("motoboy")], ["online", "Online", online],
  ["offline", "Offline", (m) => m.papeis.includes("motoboy") && !online(m)], ["gestores", "Gestores", (m) => m.papeis.includes("gestor") || m.papeis.includes("dev") || m.papeis.includes("supervisor")],
  ["teste", "Teste", (m) => m.modo_teste], ["bloqueados", "Bloqueados", (m) => Boolean(m.bloqueado)],
];
