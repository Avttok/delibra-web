"use client";

import { useCallback, useEffect, useState, type ReactNode } from "react";
import type { Session } from "@supabase/supabase-js";
import { Eye, FlaskConical, Heart, Hourglass, LogOut } from "lucide-react";
import { sair, supabase } from "@/lib/supabase/client";
import { LoginForm } from "@/features/auth/LoginForm";
import { Logo } from "@/features/marca/Logo";
import { definirMarcaEmpresa, ehPw, useMarcaEmpresa } from "@/features/marca/marcaEmpresa";
import { BotaoTema } from "@/features/tema/BotaoTema";
import { Toasts } from "@/features/ui/toast";
import { CriarConta } from "./CriarConta";

interface Acesso {
  tipo: "cliente" | "gestor" | "cadastro" | "nenhum";
  nome?: string; empresa_id?: string | null; empresa_nome?: string | null; teste?: boolean; gestor?: boolean;
  status?: "pendente" | "aprovado" | "recusado"; motivo?: string | null;
  clientes?: { id: string; nome: string; teste: boolean }[];
}
type Estado = { fase: "carregando" } | { fase: "anonimo" } | { fase: "logado"; a: Acesso };

/**
 * Área do cliente: entra, pede, acompanha e vê as faturas.
 * Gestor/Dev entram também e escolhem de qual cliente querem ver o site (para testar tudo).
 */
export function AreaCliente({ children }: { children: ReactNode }) {
  const marca = useMarcaEmpresa();
  const [estado, setEstado] = useState<Estado>({ fase: "carregando" });
  const [cadastrando, setCadastrando] = useState(false);
  // /entrar?criar=1 abre direto o cadastro da empresa
  useEffect(() => {
    const q = new URLSearchParams(window.location.search);
    if (q.get("criar") === "1") setCadastrando(true);
    // link da empresa (?empresa=slug): a tela de entrar já abre com o ícone e o nome dela
    const slug = q.get("empresa");
    if (slug) void supabase().rpc("marca_publica", { p_slug: slug }).then(({ data }) => {
      const m = data as { nome: string; nome_app: string | null; logo: string | null; cor: string | null; logo_escala: number | null } | null;
      if (m) definirMarcaEmpresa({ nome: m.nome, nomeApp: m.nome_app, logo: m.logo, cor: m.cor, escala: m.logo_escala });
    });
  }, []);
  const [modoCadastro, setModoCadastro] = useState<string>("desligado");
  const [versao, setVersao] = useState(0); // recria o painel ao trocar de cliente

  const verificar = useCallback(async (s: Session | null) => {
    if (!s) return setEstado({ fase: "anonimo" });
    const [{ data }, perfil] = await Promise.all([supabase().rpc("meu_acesso_cliente"), supabase().rpc("meu_perfil")]);
    const org = (perfil.data as { organizacao?: { nome: string; nome_app?: string | null; logo?: string | null; cor?: string | null; logo_escala?: number | null; brilho_cor?: string | null; brilho?: number | null; fonte?: string | null } | null } | null)?.organizacao;
    if (org) definirMarcaEmpresa({ nome: org.nome, nomeApp: org.nome_app ?? null, logo: org.logo ?? null, cor: org.cor, escala: org.logo_escala, brilhoCor: org.brilho_cor, brilho: org.brilho, fonte: org.fonte });
    setEstado({ fase: "logado", a: (data as Acesso | null) ?? { tipo: "nenhum" } });
  }, []);

  useEffect(() => {
    const sb = supabase();
    sb.auth.getSession().then(({ data }) => verificar(data.session));
    const { data } = sb.auth.onAuthStateChange((ev, s) => { if (ev === "SIGNED_IN" || ev === "SIGNED_OUT") verificar(s); });
    // o cadastro pelo site está aberto? (pergunta ao servidor do gestor)
    fetch("/api/cadastro").then((r) => r.json()).then((j: { modo?: string }) => setModoCadastro(j.modo ?? "desligado")).catch(() => setModoCadastro("desligado"));
    return () => data.subscription.unsubscribe();
  }, [verificar]);

  async function escolherCliente(id: string) {
    await supabase().rpc("entrar_como_cliente", { p_empresa: id || null });
    const { data: s } = await supabase().auth.getSession();
    await verificar(s.session);
    setVersao((v) => v + 1);
  }

  if (estado.fase === "carregando") return <main className="tela-login"><p className="subtitulo">Carregando…</p></main>;
  if (estado.fase === "anonimo") {
    if (cadastrando) return <CriarConta modo={modoCadastro} onVoltar={() => setCadastrando(false)} />;
    return <LoginForm rodape={modoCadastro !== "desligado"
      ? <p className="dica" style={{ textAlign: "center", margin: 0 }}>Ainda não tem conta? <button type="button" className="link-cadastro" onClick={() => setCadastrando(true)}>Criar conta da empresa</button></p>
      : null} />;
  }

  const a = estado.a;
  const comoGestor = a.tipo === "gestor";
  if (a.tipo === "cadastro" || a.tipo === "nenhum" || (comoGestor && !a.empresa_id)) {
    return (
      <main className="tela-login">
        <div className="caixa-login vidro entrar">
          <Logo />
          {a.tipo === "cadastro" && a.status === "pendente" && <>
            <p className="cadastro-ok" style={{ color: "var(--ouro)" }}><Hourglass size={28} aria-hidden /></p>
            <p style={{ textAlign: "center", margin: 0 }}><strong>Cadastro em análise</strong></p>
            <p className="dica" style={{ textAlign: "center" }}>A empresa está conferindo os dados de {a.nome}. Assim que liberar, você já pode pedir por aqui.</p>
          </>}
          {a.tipo === "cadastro" && a.status === "recusado" && <p className="erro" style={{ textAlign: "center" }}>O cadastro não foi aprovado{a.motivo ? `: ${a.motivo}` : ""}. Fale com a empresa.</p>}
          {a.tipo === "nenhum" && <p className="erro" style={{ textAlign: "center" }}>Esta conta não tem acesso de cliente. Fale com a empresa.</p>}
          {comoGestor && <>
            <p style={{ textAlign: "center", margin: 0 }}><strong>Ver o site como um cliente</strong></p>
            <p className="dica" style={{ textAlign: "center", margin: 0 }}>Você é da equipe: escolha o cliente para testar o site como ele (pedidos de cliente de teste saem como teste).</p>
            <select value="" onChange={(e) => escolherCliente(e.target.value)}>
              <option value="">Escolha o cliente…</option>
              {(a.clientes ?? []).map((c) => <option key={c.id} value={c.id}>{c.teste ? "🧪 " : ""}{c.nome}</option>)}
            </select>
            <a className="botao-texto" href="/gestor/mapa">Voltar ao painel do gestor</a>
          </>}
          <button className="botao-texto" onClick={() => sair()}><LogOut size={15} aria-hidden /> Sair</button>
        </div>
      </main>
    );
  }

  return (
    <div className="cliente-area">
      <header className="topo vidro">
        <a href="/" aria-label="Delibra, início"><Logo /></a>
        <span className="espaco" />
        {a.teste && <span className="selo selo-teste"><FlaskConical size={12} aria-hidden /> Teste</span>}
        <span className="cliente-ola">Olá, <strong>{(a.nome ?? "").split(" ")[0]}</strong></span>
        <BotaoTema />
        <button className="botao-texto" onClick={() => sair()} title="Sair"><LogOut size={16} aria-hidden /> Sair</button>
      </header>
      {comoGestor && (
        <div className="faixa-como">
          <Eye size={14} aria-hidden /> Você está vendo o site como <strong>{a.empresa_nome}</strong>{a.teste ? " (teste)" : ""}.
          <select value={a.empresa_id ?? ""} onChange={(e) => escolherCliente(e.target.value)} aria-label="Trocar de cliente">
            {(a.clientes ?? []).map((c) => <option key={c.id} value={c.id}>{c.teste ? "🧪 " : ""}{c.nome}</option>)}
          </select>
          <button className="botao-texto" onClick={() => escolherCliente("")}>Sair do modo cliente</button>
        </div>
      )}
      <main className="cliente-corpo" key={versao}>{children}</main>
      {ehPw(marca) && <footer className="rodape">
        Um projeto de irmão para irmão! <Heart size={13} aria-label="com amor" className="coracao" fill="currentColor" />
      </footer>}
      <Toasts />
    </div>
  );
}
