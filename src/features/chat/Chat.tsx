"use client";

import { PerfilPublico } from "@/features/conta/PerfilPublico";

import { CartaoChatRico } from "./CartaoChat";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CodeXml, ArrowLeft, Bell, BellOff, Building2, ClipboardList, ImagePlus, MapPin, MessageCircle, MessagesSquare, Plus, Route, Search, Send, Trash2, UserRound, Users, X,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

/** Anexo de uma mensagem: foto ou um cartão de algo do sistema. */
export interface Anexo {
  tipo: "foto" | "pedido" | "rota" | "cliente" | "pessoa" | "local";
  id?: string; titulo?: string; sub?: string; caminho?: string; lat?: number; lng?: number;
}
interface Conversa {
  id: string; tipo: "geral" | "direta" | "grupo"; nome: string | null; foto: string | null; outro: string | null; membros: number; oculto?: boolean;
  ultima_em: string; ultima_previa: string | null; ultima_minha: boolean; nao_lidas: number; silenciada: boolean;
}
interface Mensagem { id: string; conversa_id: string; autor_id: string | null; texto: string | null; anexo: Anexo | null; criada_em: string; apagada_em: string | null }
interface Contato { id: string; nome: string; foto: string | null; papeis: string[]; status: string | null; empresa: string | null }

const hora = (iso: string) => {
  const d = new Date(iso), hoje = new Date();
  return d.toDateString() === hoje.toDateString() ? d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit" }) + " " + d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
};
const ICONE_ANEXO = { pedido: ClipboardList, rota: Route, cliente: Building2, pessoa: UserRound, local: MapPin, foto: ImagePlus } as const;

/** Foto, ou a inicial; grupo = ícone de pessoas; Dev oculto = o ícone </>. */
function Avatar({ nome, foto, tamanho = 36, grupo, oculto }: { nome: string; foto?: string | null; tamanho?: number; grupo?: boolean; oculto?: boolean }) {
  return (
    <span className={`chat-avatar${oculto ? " chat-avatar-dev" : ""}`} style={{ width: tamanho, height: tamanho, backgroundImage: foto && !oculto ? `url("${foto}")` : undefined }}>
      {(!foto || oculto) && (oculto ? <CodeXml size={tamanho * 0.5} aria-hidden /> : grupo ? <Users size={tamanho * 0.45} aria-hidden /> : nome.trim().charAt(0).toUpperCase())}
    </span>
  );
}

/** Foto do chat (bucket privado): link assinado por 1 h. */
function FotoChat({ caminho }: { caminho: string }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => { supabase().storage.from("chat").createSignedUrl(caminho, 3600).then(({ data }) => setUrl(data?.signedUrl ?? null)); }, [caminho]);
  if (!url) return <span className="chat-foto carregando" />;
  // eslint-disable-next-line @next/next/no-img-element
  return <a href={url} target="_blank" rel="noreferrer"><img className="chat-foto" src={url} alt="Foto" /></a>;
}

/**
 * Chat da Delibra: conversa geral da equipe, mensagens diretas e grupos, com fotos e cartões
 * (pedido, rota, cliente, pessoa, local). `linkDe` diz para onde cada cartão leva neste site.
 * `anexoPendente` vem de "Compartilhar no chat": escolha a conversa e ele é enviado.
 */
export function Chat({ meuId, gestor, linkDe, anexoPendente, onAnexoEnviado }: {
  meuId: string; gestor: boolean;
  linkDe?: (a: Anexo) => string | null;
  anexoPendente?: Anexo | null; onAnexoEnviado?: () => void;
}) {
  const [conversas, setConversas] = useState<Conversa[] | null>(null);
  const [aberta, setAberta] = useState<string | null>(null);
  const [mensagens, setMensagens] = useState<Mensagem[]>([]);
  const [nomes, setNomes] = useState<Record<string, { nome: string; foto: string | null; papeis?: string[]; empresa?: string | null; oculto?: boolean }>>({});
  const [texto, setTexto] = useState("");
  const [enviando, setEnviando] = useState(false);
  const [novo, setNovo] = useState<"direta" | "grupo" | null>(null);
  const [contatos, setContatos] = useState<Contato[]>([]);
  const [buscaC, setBuscaC] = useState("");
  const [grupoNome, setGrupoNome] = useState("");
  const [grupoSel, setGrupoSel] = useState<Set<string>>(new Set());
  const [erro, setErro] = useState<string | null>(null);
  const [perfil, setPerfil] = useState<string | null>(null);
  const fim = useRef<HTMLDivElement>(null);
  const arquivo = useRef<HTMLInputElement>(null);

  const carregarConversas = useCallback(async () => {
    const { data, error } = await supabase().rpc("chat_conversas");
    if (error) { setErro(error.message.includes("chat_conversas") ? "O chat ainda não foi instalado no banco (migração 20261110000016)." : error.message); setConversas([]); return; }
    setConversas((data ?? []) as Conversa[]);
  }, []);
  useEffect(() => { void carregarConversas(); }, [carregarConversas]);
  useEffect(() => {
    supabase().rpc("chat_contatos").then(({ data }) => {
      const l = (data ?? []) as Contato[];
      setContatos(l);
      setNomes((n) => ({ ...n, ...Object.fromEntries(l.map((c) => [c.id, { nome: c.nome, foto: c.foto, papeis: c.papeis, empresa: c.empresa }])) }));
    });
  }, []);

  const carregarMensagens = useCallback(async (id: string) => {
    const { data } = await supabase().from("chat_mensagens").select("*").eq("conversa_id", id).order("criada_em", { ascending: false }).limit(200);
    setMensagens(((data ?? []) as Mensagem[]).reverse());
    void supabase().rpc("chat_marcar_lida", { p_conversa: id }).then(() => carregarConversas());
    // nome, foto e cargos de quem escreveu (os selos ao lado do nome)
    const { data: au } = await supabase().rpc("chat_autores", { p_conversa: id });
    if (Array.isArray(au)) setNomes((n) => ({ ...n, ...Object.fromEntries((au as { id: string; nome: string; foto: string | null; papeis: string[]; empresa: string | null; oculto?: boolean }[]).map((p) => [p.id, { nome: p.nome, foto: p.foto, papeis: p.papeis, empresa: p.empresa, oculto: p.oculto }])) }));
  }, [carregarConversas]);
  useEffect(() => { if (aberta) void carregarMensagens(aberta); else setMensagens([]); }, [aberta, carregarMensagens]);
  useEffect(() => { fim.current?.scrollIntoView({ block: "end" }); }, [mensagens.length]);

  // ao vivo: mensagens novas (as regras do banco só entregam as das conversas que eu vejo)
  useEffect(() => {
    const sb = supabase();
    const canal = sb.channel(`chat-${meuId}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "chat_mensagens" }, (p) => {
        const m = p.new as Mensagem;
        if (!m?.id) return;
        if (m.conversa_id === aberta) {
          setMensagens((l) => (l.some((x) => x.id === m.id) ? l.map((x) => (x.id === m.id ? m : x)) : [...l, m]));
          void sb.rpc("chat_marcar_lida", { p_conversa: m.conversa_id });
        }
        void carregarConversas();
      })
      .subscribe();
    const t = setInterval(() => void carregarConversas(), 30_000);
    return () => { sb.removeChannel(canal); clearInterval(t); };
  }, [meuId, aberta, carregarConversas]);

  async function enviar(anexo?: Anexo | null, conversa = aberta) {
    if (!conversa) return;
    const t = texto.trim();
    if (!t && !anexo) return;
    setEnviando(true);
    const { error } = await supabase().rpc("chat_enviar", { p_conversa: conversa, p_texto: anexo ? (t || null) : t, p_anexo: anexo ?? null });
    setEnviando(false);
    if (error) return toast(error.message, "erro");
    setTexto("");
    if (conversa === aberta) void carregarMensagens(conversa);
    void carregarConversas();
  }

  async function mandarFoto(f: File) {
    if (!aberta) return;
    if (f.size > 8 * 1024 * 1024) return toast("A foto passa de 8 MB.", "aviso");
    const ext = (f.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "");
    const caminho = `${aberta}/${crypto.randomUUID()}.${ext}`;
    setEnviando(true);
    const { error } = await supabase().storage.from("chat").upload(caminho, f, { contentType: f.type || "image/jpeg" });
    setEnviando(false);
    if (error) return toast(error.message, "erro");
    await enviar({ tipo: "foto", caminho });
  }

  async function abrirDireta(id: string) {
    const { data, error } = await supabase().rpc("chat_abrir_direta", { p_usuario: id });
    if (error) return toast(error.message, "erro");
    setNovo(null); setBuscaC("");
    await carregarConversas();
    setAberta(data as string);
  }
  async function criarGrupo() {
    const { data, error } = await supabase().rpc("chat_criar_grupo", { p_nome: grupoNome, p_membros: [...grupoSel] });
    if (error) return toast(error.message, "erro");
    setNovo(null); setGrupoNome(""); setGrupoSel(new Set());
    await carregarConversas();
    setAberta(data as string);
  }
  async function silenciar(c: Conversa) {
    await supabase().rpc("chat_silenciar", { p_conversa: c.id, p_silenciar: !c.silenciada });
    toast(c.silenciada ? "Avisos ligados." : "Conversa silenciada.", "ok");
    void carregarConversas();
  }
  async function apagar(m: Mensagem) {
    if (!confirm("Apagar esta mensagem?")) return;
    const { error } = await supabase().rpc("chat_apagar_mensagem", { p_mensagem: m.id });
    if (error) return toast(error.message.includes("sem_permissao") ? "Só dá para apagar a sua, logo depois de mandar." : error.message, "erro");
    void carregarMensagens(m.conversa_id);
  }

  const atual = conversas?.find((c) => c.id === aberta) ?? null;
  const nomeConversa = (c: Conversa) => c.nome ?? (c.tipo === "geral" ? "Equipe" : "Conversa");
  const termoC = buscaC.trim().toLowerCase();
  const contatosFiltrados = useMemo(() => contatos.filter((c) => !termoC || `${c.nome} ${c.empresa ?? ""}`.toLowerCase().includes(termoC)), [contatos, termoC]);
  const papel = (c: Contato) => (c.papeis.includes("dev") ? "Dev" : c.papeis.includes("gestor") ? "Gestor" : c.papeis.includes("supervisor") ? "Supervisor" : c.papeis.includes("motoboy") ? "Motoboy" : c.empresa ? `Cliente · ${c.empresa}` : "Cliente");

  const cartao = (a: Anexo) => {
    if (a.tipo === "foto" && a.caminho) return <FotoChat caminho={a.caminho} />;
    const I = ICONE_ANEXO[a.tipo] ?? ClipboardList;
    const href = a.tipo === "local" && a.lat != null ? `https://www.openstreetmap.org/?mlat=${a.lat}&mlon=${a.lng}#map=17/${a.lat}/${a.lng}` : linkDe?.(a) ?? null;
    const corpo = <><span className="chat-cartao-icone"><I size={16} aria-hidden /></span><span><strong>{a.titulo ?? a.tipo}</strong>{a.sub && <small>{a.sub}</small>}</span></>;
    const simples = href ? <a className="chat-cartao" href={href} target={a.tipo === "local" ? "_blank" : undefined} rel="noreferrer">{corpo}</a> : <span className="chat-cartao">{corpo}</span>;
    return <CartaoChatRico tipo={a.tipo} id={(a as Anexo & { id?: string }).id} simples={simples} />;
  };

  return (
    <div className={`chat ${aberta ? "com-conversa" : ""}`}>
      <section className="chat-lista">
        <div className="chat-lista-topo">
          <h2 className="display" style={{ margin: 0 }}><MessagesSquare size={20} aria-hidden /> Chat</h2>
          <span className="espaco" />
          <button type="button" className="botao-texto" onClick={() => setNovo(novo === "direta" ? null : "direta")}><Plus size={15} aria-hidden /> Conversa</button>
          {gestor && <button type="button" className="botao-texto" onClick={() => setNovo(novo === "grupo" ? null : "grupo")}><Users size={15} aria-hidden /> Grupo</button>}
        </div>
        {anexoPendente && (
          <div className="chat-pendente">
            <span>Escolha a conversa para mandar:</span>{cartao(anexoPendente)}
            <button type="button" className="icone" aria-label="Cancelar" onClick={onAnexoEnviado}><X size={14} /></button>
          </div>
        )}
        {erro && <p className="erro">{erro}</p>}
        {novo && (
          <div className="chat-novo">
            {novo === "grupo" && <input placeholder="Nome do grupo" value={grupoNome} onChange={(e) => setGrupoNome(e.target.value)} maxLength={60} />}
            <label className="config-busca"><Search size={15} aria-hidden /><input placeholder="Buscar pessoa…" value={buscaC} onChange={(e) => setBuscaC(e.target.value)} autoFocus /></label>
            <div className="chat-contatos">
              {contatosFiltrados.map((c) => (
                <button key={c.id} type="button" className={`chat-contato ${grupoSel.has(c.id) ? "ativo" : ""}`}
                  onClick={() => (novo === "direta" ? void abrirDireta(c.id) : setGrupoSel((s) => { const n = new Set(s); if (n.has(c.id)) n.delete(c.id); else n.add(c.id); return n; }))}>
                  <Avatar nome={c.nome} foto={c.foto} tamanho={30} />
                  <span><strong>{c.nome}</strong><small>{papel(c)}{c.status && c.status !== "offline" ? ` · ${c.status === "em_corrida" ? "em corrida" : "disponível"}` : ""}</small></span>
                </button>
              ))}
              {contatosFiltrados.length === 0 && <p className="dica">Ninguém encontrado.</p>}
            </div>
            {novo === "grupo" && <button type="button" className="botao-ouro" disabled={!grupoNome.trim() || grupoSel.size === 0} onClick={criarGrupo}>Criar grupo com {grupoSel.size}</button>}
          </div>
        )}
        {conversas == null ? <p className="dica">Carregando…</p> : conversas.length === 0 && !novo ? <p className="vazio">Nenhuma conversa ainda. Toque em Conversa para começar.</p> : (
          <div className="chat-conversas">
            {conversas.map((c) => (
              <button key={c.id} type="button" className={`chat-conversa ${c.id === aberta ? "ativa" : ""}`}
                onClick={() => { if (anexoPendente) { void enviar(anexoPendente, c.id).then(() => { onAnexoEnviado?.(); setAberta(c.id); }); } else setAberta(c.id); }}>
                <Avatar nome={nomeConversa(c)} foto={c.foto} grupo={c.tipo !== "direta"} oculto={c.oculto} />
                <span className="chat-conversa-texto">
                  <strong>{nomeConversa(c)}{c.silenciada && <BellOff size={12} aria-label="Silenciada" />}</strong>
                  <small>{c.ultima_minha ? "Você: " : ""}{c.ultima_previa ?? (c.tipo === "geral" ? "Conversa com toda a equipe" : "Sem mensagens")}</small>
                </span>
                <span className="chat-conversa-lado"><small>{hora(c.ultima_em)}</small>{c.nao_lidas > 0 && <b>{c.nao_lidas}</b>}</span>
              </button>
            ))}
          </div>
        )}
      </section>

      <section className="chat-conversa-aberta">
        {!atual ? (
          <div className="chat-vazio"><MessageCircle size={40} aria-hidden /><p>Escolha uma conversa ou comece uma nova.</p></div>
        ) : (
          <>
            <header className="chat-cabeca">
              <button type="button" className="icone chat-voltar" aria-label="Voltar" onClick={() => setAberta(null)}><ArrowLeft size={18} /></button>
              {atual.tipo === "direta" && atual.outro
                ? <button type="button" className="botao-limpo" onClick={() => setPerfil(atual.outro)} title="Ver perfil"><Avatar nome={nomeConversa(atual)} foto={atual.foto} oculto={atual.oculto} /></button>
                : <Avatar nome={nomeConversa(atual)} foto={atual.foto} grupo={atual.tipo !== "direta"} oculto={atual.oculto} />}
              <span><strong>{nomeConversa(atual)}</strong><small>{atual.tipo === "geral" ? "Toda a equipe" : atual.tipo === "grupo" ? `${atual.membros} pessoas` : "Mensagem direta"}{atual.tipo === "direta" && atual.outro && <SelosCargo papeis={nomes[atual.outro]?.papeis} empresa={nomes[atual.outro]?.empresa} />}</small></span>
              <span className="espaco" />
              <button type="button" className="icone" onClick={() => silenciar(atual)} aria-label={atual.silenciada ? "Ligar avisos" : "Silenciar"}>
                {atual.silenciada ? <BellOff size={17} /> : <Bell size={17} />}
              </button>
            </header>
            <div className="chat-mensagens">
              {mensagens.map((m, i) => {
                const minha = m.autor_id === meuId;
                const autor = m.autor_id ? nomes[m.autor_id] : null;
                const emGrupo = !minha && atual.tipo !== "direta";
                const mostrarAutor = emGrupo && mensagens[i - 1]?.autor_id !== m.autor_id;
                return (
                  <div key={m.id} className={`chat-msg ${minha ? "minha" : ""} ${emGrupo ? "com-avatar" : ""}`}>
                    {mostrarAutor && <button type="button" className="chat-autor botao-limpo" onClick={() => m.autor_id && setPerfil(m.autor_id)} title="Ver perfil">{autor?.nome ?? "Alguém"}<SelosCargo papeis={autor?.papeis} empresa={autor?.empresa} /></button>}
                    <div className="chat-linha-msg">
                    {emGrupo && (mostrarAutor ? <button type="button" className="botao-limpo" onClick={() => m.autor_id && setPerfil(m.autor_id)} aria-label={`Perfil de ${autor?.nome ?? "alguém"}`}>
                      <Avatar nome={autor?.nome ?? "?"} foto={autor?.foto} tamanho={28} oculto={autor?.oculto} /></button> : <span className="chat-avatar-vazio" />)}
                    <div className="chat-balao">
                      {m.apagada_em ? <em className="dica">Mensagem apagada</em> : <>
                        {m.anexo && cartao(m.anexo)}
                        {m.texto && <p>{m.texto}</p>}
                      </>}
                      <span className="chat-hora">{hora(m.criada_em)}
                        {!m.apagada_em && (minha || gestor) && <button type="button" className="chat-apagar" aria-label="Apagar" onClick={() => apagar(m)}><Trash2 size={11} /></button>}
                      </span>
                    </div>
                    </div>
                  </div>
                );
              })}
              {mensagens.length === 0 && <p className="dica" style={{ textAlign: "center" }}>Nenhuma mensagem ainda.</p>}
              <div ref={fim} />
            </div>
            <form className="chat-escrever" onSubmit={(e) => { e.preventDefault(); void enviar(); }}>
              <input ref={arquivo} type="file" accept="image/*" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) void mandarFoto(f); e.target.value = ""; }} />
              <button type="button" className="icone" aria-label="Mandar foto" onClick={() => arquivo.current?.click()} disabled={enviando}><ImagePlus size={18} /></button>
              <textarea rows={1} placeholder="Escreva uma mensagem…" value={texto} maxLength={4000} onChange={(e) => setTexto(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void enviar(); } }} />
              <button type="submit" className="botao-ouro chat-enviar" disabled={enviando || !texto.trim()} aria-label="Enviar"><Send size={17} /></button>
            </form>
          </>
        )}
      </section>
      {perfil && <PerfilPublico id={perfil} onFechar={() => setPerfil(null)} />}
    </div>
  );
}

/** Abre o chat com um cartão pronto para mandar (pedido, rota, cliente…). */
export function linkCompartilhar(base: string, a: Anexo) {
  return `${base}?anexo=${encodeURIComponent(JSON.stringify(a))}`;
}


/** Selos de cargo ao lado do nome (Dev, Gestor, Motoboy, Cliente). */
export function SelosCargo({ papeis, empresa }: { papeis?: string[]; empresa?: string | null }) {
  if (!papeis?.length) return null;
  // só o cargo de maior hierarquia
  const ordem: [string, string][] = [["dev", "Dev"], ["gestor", "Gestor"], ["supervisor", "Supervisor"], ["motoboy", "Motoboy"], ["cliente", "Cliente"]];
  const principal = ordem.find(([k]) => papeis.includes(k));
  if (!principal) return null;
  const [k, r] = principal;
  return (
    <span className="chat-selos">
      <span className={`chat-selo ${k}`} title={k === "cliente" && empresa ? `Cliente · ${empresa}` : r}>{r}</span>
    </span>
  );
}
