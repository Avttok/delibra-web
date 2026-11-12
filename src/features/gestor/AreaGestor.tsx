"use client";

import { usePermissoes } from "@/features/conta/permissoes";

import Link from "next/link";
import { ChamadosPendentes } from "@/features/penalidades/Chamados";
import { EmergenciasAbertas } from "@/features/penalidades/Emergencias";
import { ExigirDoisPassos } from "@/features/conta/DoisPassos";
import { usePathname, useRouter } from "next/navigation";
import { useConfiguracoes } from "@/features/configuracoes/useConfiguracoes";
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { Building2, ChevronDown, ClipboardList, Heart, LayoutDashboard, List, Map, Route, Settings2, Store, Users, Wallet, MessagesSquare } from "lucide-react";
import { sair as sairDaConta, supabase } from "@/lib/supabase/client";
import { contas } from "@/lib/supabase/contas";
import { LoginForm } from "@/features/auth/LoginForm";
import { Logo } from "@/features/marca/Logo";
import { definirMarcaEmpresa, ehPw, useMarcaEmpresa } from "@/features/marca/marcaEmpresa";
import { useEstabelecimentos } from "@/lib/mapa/estabelecimentos";
import { ProvedorTeste } from "@/features/teste/modoTeste";
import { MenuPerfil } from "./MenuPerfil";
import { ModoDev } from "@/features/dev/ModoDev";
import { Tour, type PassoTour } from "@/features/ui/Tour";
import { ProvedorConta, type ContextoConta, type CorTema, type Papel } from "@/features/conta/conta";
import { Toasts, toast } from "@/features/ui/toast";
import { definirPreferenciaRota } from "@/features/geo";

type Acesso = "carregando" | "anonimo" | "negado" | "gestor";

const ContextoSessao = createContext<Session | null>(null);
export const useSessaoGestor = () => useContext(ContextoSessao);

const ABAS = [
  { href: "/gestor/inicio", rotulo: "Hoje", icone: LayoutDashboard },
  { href: "/gestor/mapa", rotulo: "Mapa", icone: Map },
  { href: "/gestor/pedidos", rotulo: "Operação", icone: ClipboardList, tambem: ["/gestor/corridas"] },
  { href: "/gestor/clientes", rotulo: "Pessoas", icone: Users, tambem: ["/gestor/equipe"] },
  { href: "/gestor/chat", rotulo: "Chat", icone: MessagesSquare },
  { href: "/gestor/carteira", rotulo: "Carteira", icone: Wallet },
  { href: "/gestor/configuracoes", rotulo: "Ajustes", icone: Settings2 },
];

/** Protege as páginas do gestor e desenha o cabeçalho com o menu. */
export function AreaGestor({ children }: { children: ReactNode }) {
  const perm = usePermissoes();
  const [sessao, setSessao] = useState<Session | null>(null);
  const [nome, setNome] = useState("");
  const [foto, setFoto] = useState<string | null>(null);
  const [acesso, setAcesso] = useState<Acesso>("carregando");
  const [teste, setTeste] = useState(false);
  const [papeis, setPapeis] = useState<Papel[]>([]);
  const [corTema, setCorTema] = useState<CorTema>("ouro");
  const [modulos, setModulos] = useState<Record<string, boolean>>({});
  const [versaoPerfil, setVersaoPerfil] = useState(0);
  const [estabelecimentos, setEstabelecimentos] = useEstabelecimentos();
  const caminho = usePathname();
  // celular: lista sobre o mapa, mostrando ou escondida
  const [gaveta, setGaveta] = useState<"mostrando" | "oculta">("mostrando");
  const telaDeMapa = caminho?.startsWith("/gestor/mapa") || caminho?.startsWith("/gestor/corridas");
  const roteador = useRouter();
  const cfgG = useConfiguracoes();
  useEffect(() => { try { localStorage.setItem("pwex_lembrar_pagina", cfgG.lembrar_pagina === false ? "0" : "1"); } catch { /* sem armazenamento */ } }, [cfgG.lembrar_pagina]);
  // volta para a última tela aberta (Ajustes → lembrar_pagina); depois guarda cada tela nova
  useEffect(() => {
    if (!caminho?.startsWith("/gestor/")) return;
    try {
      if (!sessionStorage.getItem("pwex_restaurou")) {
        sessionStorage.setItem("pwex_restaurou", "1");
        const ultima = localStorage.getItem("pwex_ultima_tela");
        const ligado = localStorage.getItem("pwex_lembrar_pagina") !== "0";
        if (ligado && ultima && ultima !== caminho && caminho === "/gestor/mapa" && !window.location.search) { roteador.replace(ultima); return; }
      }
      localStorage.setItem("pwex_ultima_tela", caminho);
    } catch { /* sem armazenamento */ }
  }, [caminho, roteador]);

  // provedor/perfil das rotas (Ajustes → Navegação): vale para todos os mapas do site
  useEffect(() => {
    if (!sessao) return;
    void supabase().from("configuracoes").select("chave,valor").in("chave", ["rota_provedor", "rota_perfil"]).then(({ data }) => {
      const c = Object.fromEntries((data ?? []).map((r: { chave: string; valor: unknown }) => [r.chave, r.valor]));
      definirPreferenciaRota(c.rota_provedor, c.rota_perfil);
    });
  }, [sessao]);

  const [permSup, setPermSup] = useState<Record<string, boolean> | null>(null);
  const [empresa, setEmpresa] = useState<string | null>(null);
  const [bloqueio, setBloqueio] = useState<{ status: string; motivo: string | null } | null>(null);
  useEffect(() => {
    const sb = supabase();
    async function verificar(s: Session | null) {
      setSessao(s);
      if (!s) return setAcesso("anonimo");
      const [{ data }, perfil] = await Promise.all([
        sb.rpc("is_gestor"),
        sb.rpc("meu_perfil"),
      ]);
      const d = perfil.data as { nome?: string; foto_url?: string | null; modo_teste?: boolean; papeis?: Papel[]; dev?: boolean; cor_tema?: CorTema; modulos?: Record<string, boolean>;
        supervisor?: boolean; permissoes?: Record<string, boolean>; organizacao?: { id: string; nome: string; status?: string; suspensa_motivo?: string | null; nome_app?: string | null; nome_topo?: string | null; logo?: string | null; cor?: string | null; logo_escala?: number | null; brilho_cor?: string | null; brilho?: number | null; fonte?: string | null } | null } | null;
      setPermSup(d?.supervisor && !d?.dev && !(d?.papeis ?? []).includes("gestor") ? (d?.permissoes ?? {}) : null);
      setEmpresa(d?.organizacao?.nome ?? null);
      // empresa suspensa ou cancelada pelo Dev: a equipe fica sem acesso
      setBloqueio(!d?.dev && d?.organizacao && ["suspensa", "cancelada"].includes(d.organizacao.status ?? "") ? { status: d.organizacao.status!, motivo: d.organizacao.suspensa_motivo ?? null } : null);
      definirMarcaEmpresa(d?.organizacao ? { nome: d.organizacao.nome, nomeApp: d.organizacao.nome_app ?? null, nomeTopo: d.organizacao.nome_topo ?? null, nomes: (d.organizacao as { nomes?: Record<string, string> }).nomes ?? null, logo: d.organizacao.logo ?? null, cor: d.organizacao.cor, escala: d.organizacao.logo_escala, brilhoCor: d.organizacao.brilho_cor, brilho: d.organizacao.brilho, fonte: d.organizacao.fonte } : null);
      setTeste(Boolean(d?.modo_teste));
      setPapeis(d?.papeis ?? []);
      setCorTema(d?.dev && d?.cor_tema === "vermelho" ? "vermelho" : "ouro");
      setModulos(d?.modulos ?? {});
      setNome(d?.nome ?? "");
      setFoto(d?.foto_url ?? null);
      if (s.user.email) contas.atualizarPerfil(s.user.email, d?.nome ?? null, d?.foto_url ?? null);
      // conta só de cliente: vai para a área de pedidos
      if (data !== true && (d?.papeis ?? []).includes("cliente")) { window.location.replace("/entrar"); return; }
      setAcesso(data === true ? "gestor" : "negado");
    }
    sb.auth.getSession().then(({ data }) => verificar(data.session));
    const { data } = sb.auth.onAuthStateChange((evento, s) => {
      if (evento === "SIGNED_IN" || evento === "SIGNED_OUT") verificar(s);
    });
    return () => data.subscription.unsubscribe();
  }, [versaoPerfil]);

  // nome e foto mudados pelo app aparecem aqui na hora (é a mesma conta)
  useEffect(() => {
    const id = sessao?.user.id;
    if (!id) return;
    const sb = supabase();
    const canal = sb.channel(`meu-perfil-${id}`)
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "perfis", filter: `id=eq.${id}` }, (payload) => {
        const n = payload.new as { nome?: string; foto_url?: string | null; modo_teste?: boolean; cor_tema?: CorTema; papeis?: Papel[] };
        if (n.nome) setNome(n.nome);
        setFoto(n.foto_url ?? null);
        if (typeof n.modo_teste === "boolean") setTeste(n.modo_teste);
        if (n.papeis) setPapeis(n.papeis);
        if (n.cor_tema) setCorTema(n.papeis && !n.papeis.includes("dev") ? "ouro" : n.cor_tema);
      })
      .subscribe();
    return () => { sb.removeChannel(canal); };
  }, [sessao?.user.id]);

  const sair = () => sairDaConta();

  const definirTeste = useCallback(async (ligado: boolean) => {
    const { error } = await supabase().rpc("definir_modo_teste", { p_ligado: ligado });
    if (error) {
      return error.message.includes("conclua_a_corrida_antes")
        ? "Termine a corrida em andamento no app antes de trocar o modo."
        : error.message.includes("apenas_gestor") ? "Só gestores podem usar o modo teste."
        : error.message.includes("modulo_desligado") ? "O modo teste está desligado pelo Dev." : error.message;
    }
    setTeste(ligado);
    toast(ligado ? "Tudo violeta: só corridas e ganhos de teste." : "De volta ao normal: tudo vale de verdade.", "info", { titulo: ligado ? "Modo teste ligado" : "Modo teste desligado" });
    return null;
  }, []);
  const dev = papeis.includes("dev");
  const marca = useMarcaEmpresa();

  // corrida em andamento cujo motoboy não manda posição há 30 min: avisa o gestor (uma vez por corrida)
  useEffect(() => {
    if (acesso !== "gestor") return;
    const avisadas = new Set<string>();
    async function conferir() {
      const sb = supabase();
      const { data: cs } = await sb.from("corridas").select("id,numero,teste,motoboy_id").in("status", ["aceita", "em_andamento"]).not("motoboy_id", "is", null);
      if (!cs?.length) return;
      const ids = [...new Set(cs.map((c) => c.motoboy_id as string))];
      const [{ data: ms }, { data: ps }] = await Promise.all([
        sb.from("motoboys").select("id,posicao_em").in("id", ids),
        sb.from("perfis").select("id,nome").in("id", ids),
      ]);
      const limite = Date.now() - 30 * 60_000;
      for (const c of cs) {
        const m = ms?.find((x) => x.id === c.motoboy_id);
        const t = m?.posicao_em ? new Date(m.posicao_em).getTime() : 0;
        if (t < limite && !avisadas.has(c.id)) {
          avisadas.add(c.id);
          const nome = ps?.find((x) => x.id === c.motoboy_id)?.nome ?? "O motoboy";
          const min = t ? Math.round((Date.now() - t) / 60_000) : null;
          toast(`${nome} está na corrida ${c.teste ? "T" : "#"}${c.numero} e mandou a localização pela última vez ${min ? `há ${min} min` : "há muito tempo"}.`, "aviso", { titulo: "Motoboy sem sinal" });
        } else if (t >= limite) avisadas.delete(c.id);
      }
    }
    conferir();
    const t = setInterval(conferir, 60_000);
    return () => clearInterval(t);
  }, [acesso]);
  // pedidos esperando revisão: contador na aba e aviso quando chega um novo
  const [paraRevisar, setParaRevisar] = useState(0);
  useEffect(() => {
    if (acesso !== "gestor") return;
    const sb = supabase();
    const contar = () => sb.from("pedidos").select("id", { count: "exact", head: true }).eq("status", "recebido").eq("teste", teste)
      .then(({ count }) => setParaRevisar(count ?? 0));
    void contar();
    const canal = sb.channel(`pedidos-novos-${Math.random().toString(36).slice(2)}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "pedidos" }, (payload) => {
        const p = payload.new as { numero: number; teste: boolean; origem: string; status: string };
        if (p.teste === teste && p.origem === "cliente") {
          toast(p.status === "recebido" ? "Revise e aprove para virar rota." : "Já foi para o roteirizador.", "info", { titulo: `Pedido novo #${p.numero}` });
        }
        void contar();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "pedidos" }, () => void contar())
      .subscribe();
    return () => { sb.removeChannel(canal); };
  }, [acesso, teste]);
  // estabelecimentos desligados pelo Dev: some de todos os mapas
  useEffect(() => { if (!dev && modulos.estabelecimentos === false) setEstabelecimentos(false); }, [dev, modulos.estabelecimentos, setEstabelecimentos]);
  const contextoConta = useMemo<ContextoConta>(() => ({
    id: sessao?.user.id ?? "",
    papeis, dev, corTema, modulos,
    modulo: (m) => dev || modulos[m] !== false,
    definirCor: async (c) => {
      const { error } = await supabase().rpc("definir_cor_tema", { p_cor: c });
      if (error) return error.message.includes("apenas_dev") ? "Só o Dev pode usar o tema vermelho." : error.message;
      setCorTema(c);
      return null;
    },
    recarregar: () => setVersaoPerfil((v) => v + 1),
  }), [sessao?.user.id, papeis, dev, corTema, modulos]);
  const contextoTeste = useMemo(() => ({ teste, definir: definirTeste }), [teste, definirTeste]);

  if (acesso === "carregando") return <main className="tela-login"><p className="subtitulo">Carregando…</p></main>;
  if (acesso === "anonimo") return <LoginForm />;
  if (acesso === "negado")
    return (
      <main className="tela-login">
        <div className="caixa-login vidro">
          <p className="erro">Este usuário não tem acesso de gestor.</p>
          <button className="botao-ouro" onClick={sair}>Sair</button>
        </div>
      </main>
    );

  if (bloqueio)
    return (
      <main className="tela-login">
        <div className="caixa-login vidro">
          <p className="erro">{bloqueio.status === "cancelada" ? "O acesso desta empresa foi encerrado." : "O acesso desta empresa está suspenso."}</p>
          {bloqueio.motivo && <p className="dica">Motivo: {bloqueio.motivo}</p>}
          <p className="dica">Fale com o suporte da plataforma para reativar.</p>
          <button className="botao-ouro" onClick={sair}>Sair</button>
        </div>
      </main>
    );

  const exibido = nome || sessao?.user.email?.split("@")[0] || "Gestor";

  return (
    <ContextoSessao.Provider value={sessao}>
      <ProvedorConta valor={contextoConta}>
      <ProvedorTeste valor={contextoTeste}>
      <div className="painel">
        <Tour id="gestor" passos={TOUR_GESTOR} />
        <header className="topo vidro">
          <Link href="/gestor/mapa" aria-label="Delibra, início" className="topo-marca"><Logo />{empresa && !marca?.logo && !marca?.nomeApp && <span className="topo-empresa">{empresa}</span>}</Link>
          <nav className="abas">
            {ABAS.map((a) => (a.href === "/gestor/clientes" && permSup && permSup.clientes === false ? { ...a, href: "/gestor/equipe" } : a)).filter((a) => (a.href !== "/gestor/carteira" || (contextoConta.modulo("carteira") && perm.pode("ver_carteira"))) && (a.href !== "/gestor/chat" || contextoConta.modulo("chat"))
              // supervisor: só o que o gestor liberou
              && (!permSup || ((a.href !== "/gestor/carteira" || permSup.financeiro === true) && (a.href !== "/gestor/configuracoes" || permSup.ajustes === true)
                  && (a.href !== "/gestor/mapa" || permSup.mapa !== false)))).map(({ href, rotulo, icone: Icone }) => (
              <Link key={href} href={href} data-tour={href.replace("/gestor/", "aba-")} className={caminho?.startsWith(href) || ((ABAS.find((x) => x.href === href) as { tambem?: string[] } | undefined)?.tambem ?? []).some((t) => caminho?.startsWith(t)) ? "ativa" : ""}>
                <Icone size={17} aria-hidden /> {rotulo}
                {href === "/gestor/pedidos" && paraRevisar > 0 && <span className="aba-n" aria-label={`${paraRevisar} para revisar`}>{paraRevisar}</span>}
              </Link>
            ))}
          </nav>
          <span className="espaco" />
          {dev && <ModoDev />}
          <MenuPerfil
            id={sessao!.user.id}
            email={sessao?.user.email ?? ""}
            nome={exibido}
            foto={foto}
            onSair={sair}
            onPerfilSalvo={(n, f) => {
              setNome(n);
              setFoto(f);
              if (sessao?.user.email) contas.atualizarPerfil(sessao.user.email, n, f);
            }}
          />
        </header>
        <div className="painel-principal">
        <ExigirDoisPassos />
        {(["/gestor/pedidos", "/gestor/corridas"].some((t) => caminho?.startsWith(t)) || ["/gestor/clientes", "/gestor/equipe"].some((t) => caminho?.startsWith(t))) && (
          <nav className="sub-abas" aria-label="Seção">
            {(caminho?.startsWith("/gestor/pedidos") || caminho?.startsWith("/gestor/corridas")
              ? [["/gestor/pedidos", "Pedidos", ClipboardList], ["/gestor/corridas", "Rotas", Route]] as const
              : [["/gestor/clientes", "Clientes", Building2], ["/gestor/equipe", "Equipe", Users]] as const).filter(([h]) => !(h === "/gestor/clientes" && permSup && permSup.clientes === false)).map(([h, r, I]) => (
              <Link key={h} href={h} className={caminho?.startsWith(h) ? "ativa" : ""}><I size={15} aria-hidden /> {r}{h === "/gestor/pedidos" && paraRevisar > 0 && <span className="aba-n">{paraRevisar}</span>}</Link>
            ))}
          </nav>
        )}
        <EmergenciasAbertas />
        <ChamadosPendentes />
        <div className="corpo" data-gaveta={telaDeMapa ? gaveta : undefined}>
          {children}
          {telaDeMapa && (
            <div className="pilulas-mapa">
              <button className="pilula vidro so-celular" onClick={() => setGaveta((g) => (g === "mostrando" ? "oculta" : "mostrando"))}>
                {gaveta === "mostrando" ? <><ChevronDown size={16} aria-hidden /> Esconder lista</> : <><List size={16} aria-hidden /> Mostrar lista</>}
              </button>
              {contextoConta.modulo("estabelecimentos") && <button className={`pilula vidro ${estabelecimentos ? "ligada" : ""}`} onClick={() => setEstabelecimentos(!estabelecimentos)} aria-pressed={estabelecimentos}>
                <Store size={16} aria-hidden /> {estabelecimentos ? "Ocultar estabelecimentos" : "Mostrar estabelecimentos"}
              </button>}
            </div>
          )}
        </div>
        {ehPw(marca) && <footer className="rodape">
          Um projeto de irmão para irmão! <Heart size={13} aria-label="com amor" className="coracao" fill="currentColor" />
        </footer>}
        </div>
      </div>
      <Toasts />
      </ProvedorTeste>
      </ProvedorConta>
    </ContextoSessao.Provider>
  );
}

/** Tour do painel: na primeira vez abre sozinho; depois, no menu da foto → Ver o tour. */
const TOUR_GESTOR: PassoTour[] = [
  { titulo: "Bem-vindo ao painel da Delibra", texto: "Um passeio rápido pelas partes do painel. Dá para rever quando quiser, no menu da sua foto." },
  { alvo: '[data-tour="aba-mapa"]', titulo: "Mapa", texto: "Os motoboys ao vivo: quem está disponível, em corrida ou offline, com o percurso de cada um." },
  { alvo: '[data-tour="aba-pedidos"]', titulo: "Pedidos", texto: "Os pedidos dos clientes chegam aqui para revisar. O número mostra quantos esperam você. Ao aprovar, eles viram rota." },
  { alvo: '[data-tour="aba-corridas"]', titulo: "Rotas", texto: "As rotas montadas e as avulsas. Daqui você solta para os motoboys (quadro, melhor primeiro, cascata ou direto) e acompanha cada uma." },
  { alvo: '[data-tour="aba-clientes"]', titulo: "Clientes", texto: "Cadastros, preço e regras de cada cliente, e os cadastros feitos pelo site esperando aprovação." },
  { alvo: '[data-tour="aba-equipe"]', titulo: "Equipe", texto: "Contas dos motoboys e gestores: registro, percursos, veículo, medalhas e as regras de cada um." },
  { alvo: '[data-tour="aba-carteira"]', titulo: "Carteira", texto: "Quanto entrou, faturas dos clientes, folha dos motoboys, extrato e chaves PIX." },
  { alvo: '[data-tour="aba-configuracoes"]', titulo: "Configurações", texto: "As regras gerais do sistema. Cada uma pode ter exceção por tipo de pedido, cliente, motoboy ou pedido: são as peças do lego." },
  { alvo: ".botao-avatar", titulo: "Seu menu", texto: "Perfil, tema e cores, modo teste para treinar sem mexer no real, a central de ajuda e este tour." },
];
