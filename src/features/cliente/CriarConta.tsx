"use client";

import { useEffect, useState, type FormEvent } from "react";
import { ArrowLeft, Building2, CheckCircle2, Package, Star, UserRound } from "lucide-react";
import { supabase } from "@/lib/supabase/client";
import { Logo } from "@/features/marca/Logo";
import { CampoEndereco } from "@/features/corridas/CampoEndereco";
import { MapaCorridas } from "@/features/corridas/MapaCorridas";

const ERROS: Record<string, string> = {
  email_invalido: "E-mail inválido.", senha_curta: "A senha precisa de pelo menos 8 caracteres.", nome_invalido: "Informe o nome da empresa.",
  documento_invalido: "CNPJ ou CPF inválido.", email_existe: "Já existe uma conta com esse e-mail. Entre com ela.",
  cadastro_desligado: "O cadastro pelo site está fechado. Fale com a empresa.", muitas_tentativas: "Muitas tentativas. Tente de novo mais tarde.",
  servidor_sem_chave: "O cadastro ainda não foi ligado pela empresa.",
};
const mascaraDoc = (v: string) => {
  const d = v.replace(/\D/g, "").slice(0, 14);
  if (d.length <= 11) return d.replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d)/, "$1.$2").replace(/(\d{3})(\d{1,2})$/, "$1-$2");
  return d.replace(/^(\d{2})(\d)/, "$1.$2").replace(/^(\d{2})\.(\d{3})(\d)/, "$1.$2.$3").replace(/\.(\d{3})(\d)/, ".$1/$2").replace(/(\d{4})(\d)/, "$1-$2");
};

/** Empresa (ou pessoa) cria a conta pelo site. Pode precisar da aprovação da empresa. */
export function CriarConta({ onVoltar, modo }: { onVoltar: () => void; modo: string }) {
  const [tipo, setTipo] = useState<"pj" | "pf">("pj");
  const [f, setF] = useState({ nome: "", documento: "", responsavel: "", telefone: "", email: "", senha: "", endereco: "", lat: null as number | null, lng: null as number | null, observacoes: "", site: "" });
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  // várias transportadoras: o cliente escolhe por cards (o link ?empresa= já vem escolhido)
  type EmpresaCard = { slug: string; nome: string; logo: string | null; cor: string | null; modo: string; nota: number | null; avaliacoes: number; entregas: number };
  const [empresas, setEmpresas] = useState<EmpresaCard[] | null>(null);
  const [escolhida, setEscolhida] = useState<string | null>(null);
  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get("empresa");
    if (q) { setEscolhida(q); setEmpresas([]); return; }
    void supabase().rpc("empresas_cadastro").then(({ data }) => {
      const l = (data as EmpresaCard[] | null) ?? [];
      setEmpresas(l);
      if (l.length === 1) setEscolhida(l[0].slug);
    });
  }, []);
  const [feito, setFeito] = useState<"pendente" | "aprovado" | null>(null);
  const set = (d: Partial<typeof f>) => setF((x) => ({ ...x, ...d }));
  const base = "";

  async function enviar(e: FormEvent) {
    e.preventDefault();
    setErro(null);
    if (f.senha.length < 8) return setErro(ERROS.senha_curta);
    setEnviando(true);
    try {
      const r = await fetch(`${base}/api/cadastro`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...f, documento: f.documento.replace(/\D/g, ""), empresa: escolhida ?? new URLSearchParams(window.location.search).get("empresa") }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) { setErro(ERROS[j.erro] ?? `Não deu certo (${j.erro ?? r.status}).`); setEnviando(false); return; }
      await supabase().auth.signInWithPassword({ email: f.email.trim().toLowerCase(), password: f.senha });
      setFeito(j.status === "aprovado" ? "aprovado" : "pendente");
    } catch {
      setErro("Sem conexão. Tente de novo.");
    }
    setEnviando(false);
  }

  if (feito) return (
    <main className="tela-login"><div className="caixa-login vidro entrar">
      <Logo grande />
      <p className="cadastro-ok"><CheckCircle2 size={28} aria-hidden /></p>
      <h2 className="display" style={{ textAlign: "center", margin: 0 }}>{feito === "aprovado" ? "Conta criada!" : "Recebemos o seu cadastro"}</h2>
      <p className="dica" style={{ textAlign: "center" }}>{feito === "aprovado" ? "Você já pode fazer pedidos." : "A empresa confere os dados e libera o acesso. Você entra com este e-mail e senha."}</p>
      <button type="button" className="botao-ouro" onClick={() => window.location.reload()}>Continuar</button>
    </div></main>
  );

  if (empresas && empresas.length > 1 && !escolhida) return (
    <main className="tela-login">
      <section className="escolher-empresa">
        <button type="button" className="botao-texto" style={{ alignSelf: "flex-start" }} onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Já tenho conta</button>
        <h1 className="display">Escolha quem vai fazer suas entregas</h1>
        <p className="dica">Você pode pedir a qualquer hora depois de criar a conta.</p>
        <div className="empresas-cards">
          {empresas.map((e) => (
            <button key={e.slug} type="button" className="empresa-card vidro" style={{ ["--cor-empresa" as string]: e.cor ?? "var(--ouro)" }} onClick={() => setEscolhida(e.slug)}>
              <span className="empresa-card-logo" style={{ backgroundImage: e.logo ? `url("${e.logo}")` : undefined }}>{!e.logo && e.nome.charAt(0)}</span>
              <strong>{e.nome}</strong>
              <span className="empresa-card-numeros">
                {e.nota != null ? <span><Star size={13} aria-hidden /> {e.nota.toLocaleString("pt-BR")} <small>({e.avaliacoes})</small></span> : <span className="dica">Sem avaliações ainda</span>}
                {e.entregas > 0 && <span><Package size={13} aria-hidden /> {e.entregas.toLocaleString("pt-BR")} entregas</span>}
              </span>
              <span className="dica">{e.modo === "instantaneo" ? "Conta liberada na hora" : "A empresa aprova seu cadastro"}</span>
            </button>
          ))}
        </div>
      </section>
    </main>
  );

  return (
    <main className="tela-login">
      <form className="caixa-login vidro entrar caixa-cadastro" onSubmit={enviar}>
        {empresas && empresas.length > 1 && escolhida && (
          <button type="button" className="botao-texto" style={{ alignSelf: "flex-start" }} onClick={() => setEscolhida(null)}>
            <Building2 size={15} aria-hidden /> {empresas.find((e) => e.slug === escolhida)?.nome} · trocar</button>
        )}
        <button type="button" className="botao-texto" style={{ alignSelf: "flex-start" }} onClick={onVoltar}><ArrowLeft size={15} aria-hidden /> Já tenho conta</button>
        <Logo />
        <h2 className="display" style={{ margin: 0 }}>Criar conta</h2>
        {modo === "aprovacao" && <p className="dica" style={{ margin: 0 }}>Depois de enviar, a empresa confere os dados e libera os pedidos.</p>}
        <div className="segmentado" style={{ gridTemplateColumns: "1fr 1fr" }}>
          <button type="button" className={tipo === "pj" ? "ativo" : ""} onClick={() => setTipo("pj")}><Building2 size={14} aria-hidden /> Empresa</button>
          <button type="button" className={tipo === "pf" ? "ativo" : ""} onClick={() => setTipo("pf")}><UserRound size={14} aria-hidden /> Pessoa</button>
        </div>
        <label className="campo"><span>{tipo === "pj" ? "Nome da empresa" : "Seu nome"}</span><input required value={f.nome} onChange={(e) => set({ nome: e.target.value })} /></label>
        <label className="campo"><span>{tipo === "pj" ? "CNPJ" : "CPF"}</span><input inputMode="numeric" value={f.documento} onChange={(e) => set({ documento: mascaraDoc(e.target.value) })} /></label>
        {tipo === "pj" && <label className="campo"><span>Seu nome (responsável)</span><input value={f.responsavel} onChange={(e) => set({ responsavel: e.target.value })} /></label>}
        <label className="campo"><span>Telefone / WhatsApp</span><input inputMode="tel" value={f.telefone} onChange={(e) => set({ telefone: e.target.value })} /></label>
        <label className="campo"><span>Endereço de coleta (opcional)</span>
          <CampoEndereco valor={f.endereco} onTexto={(t) => set({ endereco: t, lat: null, lng: null })} onEscolher={(x) => set({ endereco: x.descricao, lat: x.lat, lng: x.lng })} /></label>
        {f.lat != null && f.lng != null && (
          <div className="cliente-mapa" style={{ height: 200 }}>
            <MapaCorridas paradas={[{ chave: "coleta", lat: f.lat, lng: f.lng, tipo: "coleta", rotulo: "1" }]} enquadrar={`${f.lat},${f.lng}`}
              aoClicar={(lat, lng) => set({ lat, lng })} />
          </div>
        )}
        {f.lat != null && <p className="dica" style={{ margin: "-6px 0 0" }}>Confira o ponto no mapa. Se não for ali, toque no lugar certo.</p>}
        <label className="campo"><span>E-mail</span><input type="email" required autoComplete="email" value={f.email} onChange={(e) => set({ email: e.target.value })} /></label>
        <label className="campo"><span>Senha (mínimo 8)</span><input type="password" required autoComplete="new-password" value={f.senha} onChange={(e) => set({ senha: e.target.value })} /></label>
        <input className="armadilha" tabIndex={-1} autoComplete="off" aria-hidden value={f.site} onChange={(e) => set({ site: e.target.value })} />
        {erro && <p className="erro" style={{ margin: 0 }}>{erro}</p>}
        <button className="botao-ouro" disabled={enviando}>{enviando ? "Enviando…" : "Criar conta"}</button>
      </form>
    </main>
  );
}
