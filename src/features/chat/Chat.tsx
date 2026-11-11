"use client";

import { PerfilPublico } from "@/features/conta/PerfilPublico";

import { CartaoChatRico } from "./CartaoChat";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  CodeXml, ArrowLeft, Archive, Bell, BellOff, Building2, CheckCheck, ClipboardList, Download, ImagePlus, MapPin, MessageCircle, MessagesSquare, Mic, Pencil, Plus, Reply,
  Route, Search, Send, Shield, Square, Trash2, UserMinus, UserPlus, UserRound, Users, X,
} from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { toast } from "@/features/ui/toast";

/** Anexo de uma mensagem: foto ou um cartão de algo do sistema. */
export interface Anexo {
  tipo: "foto" | "pedido" | "rota" | "cliente" | "pessoa" | "local" | "audio";
  id?: string; titulo?: string; sub?: string; caminho?: string; lat?: number; lng?: number; path?: string; duracao?: number; expirado?: boolean;
}
interface Conversa {
  id: string; tipo: "geral" | "direta" | "grupo" | "corrida" | "empresa"; nome: string | null; arquivada?: boolean; corrida_id?: string | null; foto: string | null; outro: string | null; membros: number; oculto?: boolean;
  ultima_em: string; ultima_previa: string | null; ultima_minha: boolean; nao_lidas: number; silenciada: boolean;
}
interface Mensagem {
  id: string; conversa_id: string; autor_id: string | null; texto: string | null; anexo: Anexo | null; criada_em: string; apagada_em: string | null;
  resposta_a?: string | null; editada_em?: string | null; reacoes?: Record<string, string[]>; automatica?: boolean;
}
interface Membro { id: string; nome: string; foto: string | null; admin: boolean; papeis: string[]; lida_em: string }
const EMOJIS = ["👍", "❤️", "😂", "😮", "🙏", "✅"];
interface Contato { id: string; nome: string; foto: string | null; papeis: string[]; status: string | null; empresa: string | null }

const hora = (iso: string) => {
  const d = new Date(iso), hoje = new Date();
  return d.toDateString() === hoje.toDateString() ? d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit" }) + " " + d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
};
const ICONE_ANEXO = { pedido: ClipboardList, rota: Route, cliente: Building2, pessoa: UserRound, local: MapPin, foto: ImagePlus, audio: Mic } as const;

/** Áudio do chat: toca do Storage (link assinado). */
function AudioChat({ a }: { a: Anexo }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    if (!a.path || a.expirado) return;
    void supabase().storage.from("chat").createSignedUrl(a.path, 3600).then(({ data }) => setUrl(data?.signedUrl ?? null));
  }, [a.path, a.expirado]);
  if (a.expirado) return <span className="dica"><Mic size={12} aria-hidden /> Áudio que já não fica guardado</span>;
  return <span className="chat-audio"><Mic size={14} aria-hidden />{url ? <audio controls preload="none" src={url} /> : <span className="dica">Carregando…</span>}{a.duracao ? <small>{Math.round(a.duracao)}s</small> : null}</span>;
}

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
  const [respondendo, setRespondendo] = useState<Mensagem | null>(null);
  const [editando, setEditando] = useState<Mensagem | null>(null);
  const [menuMsg, setMenuMsg] = useState<string | null>(null);
  const [membros, setMembros] = useState<Membro[]>([]);
  const [verMembros, setVerMembros] = useState(false);
  const [buscaMsg, setBuscaMsg] = useState<string | null>(null);
  const [gravando, setGravando] = useState<{ rec: MediaRecorder; inicio: number } | null>(null);
  const [agoraG, setAgoraG] = useState(0);
  const [cfgChat, setCfgChat] = useState<{ audio: boolean; max: number; editarMin: number }>({ audio: true, max: 60, editarMin: 15 });
  useEffect(() => {
    void supabase().rpc("ajustes").then(({ data }) => {
      const a = (data ?? {}) as Record<string, unknown>;
      setCfgChat({ audio: a.chat_audio_ligado !== false, max: Number(a.dev_chat_audio_max_s ?? 60) || 60, editarMin: Number(a.chat_editar_min ?? 15) });
    });
  }, []);

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
    void supabase().rpc("chat_membros_de", { p_conversa: id }).then(({ data: mb }) => setMembros((mb ?? []) as Membro[]));
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
    if (editando && !anexo) {
      const { error } = await supabase().rpc("chat_editar", { p_mensagem: editando.id, p_texto: t });
      setEnviando(false);
      if (error) return toast(error.message.includes("tempo_de_editar") ? "O tempo para editar essa mensagem passou." : error.message, "erro");
      setEditando(null); setTexto(""); void carregarMensagens(conversa); return;
    }
    const { error } = await supabase().rpc("chat_enviar", { p_conversa: conversa, p_texto: anexo ? (t || null) : t, p_anexo: anexo ?? null, p_resposta_a: respondendo?.id ?? null });
    setEnviando(false);
    if (error) return toast(error.message.includes("conversa_arquivada") ? "Esta conversa terminou com a corrida: fica só para ler." : error.message.includes("audio") ? "Áudio desligado ou longo demais." : error.message, "erro");
    setTexto(""); setRespondendo(null);
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

  async function reagir(m: Mensagem, e: string) {
    setMenuMsg(null);
    const { data, error } = await supabase().rpc("chat_reagir", { p_mensagem: m.id, p_emoji: e });
    if (error) return toast("Não deu para reagir agora.", "erro");
    setMensagens((l) => l.map((x) => (x.id === m.id ? { ...x, reacoes: (data ?? {}) as Record<string, string[]> } : x)));
  }
  async function gravar() {
    if (gravando) {
      gravando.rec.stop(); return;
    }
    if (!aberta || typeof MediaRecorder === "undefined") return toast("Este navegador não grava áudio.", "aviso");
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const rec = new MediaRecorder(stream);
      const partes: Blob[] = [];
      const inicio = Date.now();
      const conversa = aberta;
      rec.ondataavailable = (e) => { if (e.data.size) partes.push(e.data); };
      rec.onstop = async () => {
        stream.getTracks().forEach((t) => t.stop());
        setGravando(null);
        const duracao = (Date.now() - inicio) / 1000;
        if (duracao < 1) return;
        const blob = new Blob(partes, { type: rec.mimeType || "audio/webm" });
        const path = `${conversa}/${crypto.randomUUID()}.${(rec.mimeType || "audio/webm").includes("mp4") ? "m4a" : "webm"}`;
        setEnviando(true);
        const { error } = await supabase().storage.from("chat").upload(path, blob, { contentType: blob.type });
        setEnviando(false);
        if (error) return toast("Não deu para mandar o áudio.", "erro");
        await enviar({ tipo: "audio", path, duracao: Math.min(duracao, cfgChat.max) }, conversa);
      };
      rec.start();
      setGravando({ rec, inicio });
      // para sozinho no tempo máximo do Dev
      setTimeout(() => { if (rec.state === "recording") rec.stop(); }, cfgChat.max * 1000);
    } catch { toast("Libere o microfone para gravar.", "aviso"); }
  }
  useEffect(() => { if (!gravando) return; const t = setInterval(() => setAgoraG(Date.now()), 250); return () => clearInterval(t); }, [gravando]);
  async function grupo(acao: string, usuario?: string, nome?: string) {
    if (!aberta) return;
    const { data, error } = await supabase().rpc("chat_grupo", { p_conversa: aberta, p_acao: acao, p_usuario: usuario ?? null, p_nome: nome ?? null });
    if (error) return toast(error.message.includes("sem_permissao") ? "Só quem administra o grupo faz isso." : error.message, "erro");
    if (acao === "sair" || acao === "apagar") { setAberta(null); setVerMembros(false); void carregarConversas(); return; }
    setMembros((data ?? []) as Membro[]); void carregarConversas();
  }
  async function exportar() {
    if (!aberta) return;
    const { data, error } = await supabase().rpc("chat_exportar", { p_conversa: aberta });
    if (error) return toast("Só gestores exportam conversas.", "erro");
    const d = data as { conversa: string; mensagens: { quando: string; autor: string; texto: string | null; anexo: string | null; apagada: boolean }[] };
    const linhas = d.mensagens.map((m) => `[${new Date(m.quando).toLocaleString("pt-BR")}] ${m.autor}: ${m.apagada ? "(apagada)" : m.texto ?? `(${m.anexo ?? "anexo"})`}`);
    const url = URL.createObjectURL(new Blob([`Conversa: ${d.conversa}\n\n${linhas.join("\n")}\n`], { type: "text/plain;charset=utf-8" }));
    const a = document.createElement("a"); a.href = url; a.download = `conversa-${d.conversa.replace(/[^\w-]+/g, "-")}.txt`; a.click(); URL.revokeObjectURL(url);
  }
  async function abrirCaixa() {
    const { data, error } = await supabase().rpc("chat_caixa_empresa", { p_empresa: null });
    if (error) return toast("A conversa com a empresa está desligada.", "aviso");
    await carregarConversas(); setAberta(data as string);
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
    if (a.tipo === "audio") return <AudioChat a={a} />;
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
          {!gestor && <button type="button" className="botao-texto" onClick={abrirCaixa}><Building2 size={15} aria-hidden /> Falar com a empresa</button>}
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
                  <strong>{nomeConversa(c)}{c.silenciada && <BellOff size={12} aria-label="Silenciada" />}
                    {c.tipo === "corrida" && <span className="selo chat-selo">{c.arquivada ? <><Archive size={10} aria-hidden /> HISTÓRICO</> : <><Route size={10} aria-hidden /> CORRIDA</>}</span>}
                    {c.tipo === "empresa" && <span className="selo chat-selo"><Building2 size={10} aria-hidden /> EMPRESA</span>}</strong>
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
              <span><strong>{nomeConversa(atual)}</strong><small>{atual.tipo === "geral" ? "Toda a equipe" : atual.tipo === "grupo" || atual.tipo === "corrida" ? `${atual.membros} pessoas` : atual.tipo === "empresa" ? "Atendimento da empresa" : "Mensagem direta"}{atual.tipo === "direta" && atual.outro && <SelosCargo papeis={nomes[atual.outro]?.papeis} empresa={nomes[atual.outro]?.empresa} />}</small></span>
              <span className="espaco" />
              <button type="button" className="icone" onClick={() => setBuscaMsg(buscaMsg == null ? "" : null)} aria-label="Buscar na conversa"><Search size={17} /></button>
              {atual.tipo !== "geral" && <button type="button" className="icone" onClick={() => setVerMembros(!verMembros)} aria-label="Membros"><Users size={17} /></button>}
              {gestor && <button type="button" className="icone" onClick={exportar} aria-label="Exportar conversa"><Download size={17} /></button>}
              <button type="button" className="icone" onClick={() => silenciar(atual)} aria-label={atual.silenciada ? "Ligar avisos" : "Silenciar"}>
                {atual.silenciada ? <BellOff size={17} /> : <Bell size={17} />}
              </button>
            </header>
            {buscaMsg != null && (
              <label className="config-busca chat-busca"><Search size={15} aria-hidden /><input autoFocus placeholder="Buscar nesta conversa…" value={buscaMsg} onChange={(e) => setBuscaMsg(e.target.value)} /></label>
            )}
            {verMembros && (
              <div className="chat-membros">
                <div className="chat-membros-topo"><strong><Users size={14} aria-hidden /> {membros.length} pessoas</strong><span className="espaco" />
                  {(atual.tipo === "grupo" || atual.tipo === "corrida") && gestor && <button type="button" className="botao-texto" onClick={() => { const n = prompt("Novo nome do grupo", atual.nome ?? ""); if (n != null) void grupo("renomear", undefined, n); }}><Pencil size={13} aria-hidden /> Renomear</button>}
                  {atual.tipo === "grupo" && <button type="button" className="botao-texto" onClick={() => { if (confirm("Sair deste grupo?")) void grupo("sair"); }}><UserMinus size={13} aria-hidden /> Sair</button>}
                </div>
                {membros.map((mb) => (
                  <div key={mb.id} className="chat-membro">
                    <Avatar nome={mb.nome} foto={mb.foto} tamanho={28} />
                    <span><strong>{mb.nome}</strong>{mb.admin && <span className="selo chat-selo"><Shield size={10} aria-hidden /> ADMIN</span>}<SelosCargo papeis={mb.papeis} /></span>
                    <span className="espaco" />
                    {gestor && (atual.tipo === "grupo" || atual.tipo === "corrida") && mb.id !== meuId && <>
                      <button type="button" className="icone" aria-label={mb.admin ? "Tirar admin" : "Fazer admin"} onClick={() => grupo("admin", mb.id)}><Shield size={14} /></button>
                      <button type="button" className="icone" aria-label="Tirar do grupo" onClick={() => { if (confirm(`Tirar ${mb.nome} do grupo?`)) void grupo("remover", mb.id); }}><UserMinus size={14} /></button>
                    </>}
                  </div>
                ))}
                {gestor && (atual.tipo === "grupo" || atual.tipo === "corrida") && (
                  <select className="chat-add" value="" onChange={(e) => { if (e.target.value) void grupo("adicionar", e.target.value); }} aria-label="Adicionar pessoa">
                    <option value="">+ Adicionar pessoa…</option>
                    {contatos.filter((c) => !membros.some((m) => m.id === c.id)).map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
                  </select>
                )}
              </div>
            )}
            <div className="chat-mensagens">
              {mensagens.filter((m) => !buscaMsg?.trim() || (m.texto ?? "").toLowerCase().includes(buscaMsg.trim().toLowerCase())).map((m, i, lista) => {
                const minha = m.autor_id === meuId;
                const autor = m.autor_id ? nomes[m.autor_id] : null;
                const emGrupo = !minha && atual.tipo !== "direta";
                const mostrarAutor = emGrupo && lista[i - 1]?.autor_id !== m.autor_id;
                const citada = m.resposta_a ? mensagens.find((x) => x.id === m.resposta_a) : null;
                // visto: todos os outros abriram a conversa depois desta mensagem
                const outros = membros.filter((mb) => mb.id !== meuId);
                const vista = minha && outros.length > 0 && outros.every((mb) => new Date(mb.lida_em) >= new Date(m.criada_em));
                const podeEditar = minha && !m.apagada_em && !m.anexo && Date.now() - new Date(m.criada_em).getTime() < cfgChat.editarMin * 60_000 && !atual.arquivada;
                return (
                  <div key={m.id} className={`chat-msg ${minha ? "minha" : ""} ${emGrupo ? "com-avatar" : ""}`}>
                    {mostrarAutor && <button type="button" className="chat-autor botao-limpo" onClick={() => m.autor_id && setPerfil(m.autor_id)} title="Ver perfil">{autor?.nome ?? "Alguém"}<SelosCargo papeis={autor?.papeis} empresa={autor?.empresa} /></button>}
                    <div className="chat-linha-msg">
                    {emGrupo && (mostrarAutor ? <button type="button" className="botao-limpo" onClick={() => m.autor_id && setPerfil(m.autor_id)} aria-label={`Perfil de ${autor?.nome ?? "alguém"}`}>
                      <Avatar nome={autor?.nome ?? "?"} foto={autor?.foto} tamanho={28} oculto={autor?.oculto} /></button> : <span className="chat-avatar-vazio" />)}
                    <div className={`chat-balao${m.automatica ? " automatica" : ""}`} onClick={() => !m.apagada_em && setMenuMsg(menuMsg === m.id ? null : m.id)}>
                      {m.automatica && <span className="chat-auto">Resposta automática</span>}
                      {citada && <span className="chat-citacao"><Reply size={11} aria-hidden /> <strong>{citada.autor_id ? nomes[citada.autor_id]?.nome ?? "Alguém" : "Empresa"}</strong> {citada.apagada_em ? "Mensagem apagada" : citada.texto ?? "Anexo"}</span>}
                      {m.apagada_em ? <em className="dica">Mensagem apagada</em> : <>
                        {m.anexo && cartao(m.anexo)}
                        {m.texto && <p>{m.texto}</p>}
                      </>}
                      <span className="chat-hora">{m.editada_em && !m.apagada_em ? "editada · " : ""}{hora(m.criada_em)}
                        {minha && !m.apagada_em && <CheckCheck size={13} className={vista ? "chat-visto" : "chat-nao-visto"} aria-label={vista ? "Vista" : "Enviada"} />}
                      </span>
                      {m.reacoes && Object.keys(m.reacoes).length > 0 && (
                        <span className="chat-reacoes">{Object.entries(m.reacoes).map(([e, q]) => (
                          <button key={e} type="button" className={`chat-reacao${q.includes(meuId) ? " minha" : ""}`} onClick={(ev) => { ev.stopPropagation(); void reagir(m, e); }}>{e} {q.length}</button>
                        ))}</span>
                      )}
                      {menuMsg === m.id && (
                        <span className="chat-acoes" onClick={(ev) => ev.stopPropagation()}>
                          {!atual.arquivada && EMOJIS.map((e) => <button key={e} type="button" className="chat-emoji" onClick={() => reagir(m, e)} aria-label={`Reagir ${e}`}>{e}</button>)}
                          {!atual.arquivada && <button type="button" className="icone" aria-label="Responder" onClick={() => { setRespondendo(m); setEditando(null); setMenuMsg(null); }}><Reply size={14} /></button>}
                          {podeEditar && <button type="button" className="icone" aria-label="Editar" onClick={() => { setEditando(m); setRespondendo(null); setTexto(m.texto ?? ""); setMenuMsg(null); }}><Pencil size={14} /></button>}
                          {(minha || gestor) && <button type="button" className="icone" aria-label="Apagar" onClick={() => { setMenuMsg(null); void apagar(m); }}><Trash2 size={14} /></button>}
                        </span>
                      )}
                    </div>
                    </div>
                  </div>
                );
              })}
              {mensagens.length === 0 && <p className="dica" style={{ textAlign: "center" }}>Nenhuma mensagem ainda.</p>}
              <div ref={fim} />
            </div>
            {atual.arquivada ? (
              <p className="chat-arquivada"><Archive size={14} aria-hidden /> A corrida terminou: esta conversa fica no histórico, só para ler.</p>
            ) : <>
            {(respondendo || editando) && (
              <div className="chat-respondendo">
                {respondendo ? <Reply size={14} aria-hidden /> : <Pencil size={14} aria-hidden />}
                <span>{respondendo ? <>Respondendo <strong>{respondendo.autor_id ? nomes[respondendo.autor_id]?.nome ?? "" : ""}</strong>: {respondendo.texto ?? "anexo"}</> : "Editando a mensagem"}</span>
                <button type="button" className="icone" aria-label="Cancelar" onClick={() => { setRespondendo(null); if (editando) { setEditando(null); setTexto(""); } }}><X size={14} /></button>
              </div>
            )}
            <form className="chat-escrever" onSubmit={(e) => { e.preventDefault(); void enviar(); }}>
              <input ref={arquivo} type="file" accept="image/*" hidden onChange={(e) => { const f = e.target.files?.[0]; if (f) void mandarFoto(f); e.target.value = ""; }} />
              <button type="button" className="icone" aria-label="Mandar foto" onClick={() => arquivo.current?.click()} disabled={enviando}><ImagePlus size={18} /></button>
              <textarea rows={1} placeholder="Escreva uma mensagem…" value={texto} maxLength={4000} onChange={(e) => setTexto(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); void enviar(); } }} />
              {cfgChat.audio && !texto.trim() && !editando
                ? <button type="button" className={`botao-ouro chat-enviar${gravando ? " gravando" : ""}`} onClick={gravar} disabled={enviando} aria-label={gravando ? "Parar e mandar o áudio" : "Gravar áudio"}>
                    {gravando ? <><Square size={15} /> {Math.floor((agoraG - gravando.inicio) / 1000)}s</> : <Mic size={17} />}</button>
                : <button type="submit" className="botao-ouro chat-enviar" disabled={enviando || !texto.trim()} aria-label="Enviar"><Send size={17} /></button>}
            </form>
            </>}
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
