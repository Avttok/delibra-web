"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { Bike, Check, LockKeyhole, MapPinned, MessagesSquare, Route, Wallet } from "lucide-react";
import { supabase } from "@/lib/supabase/client";

const RECURSOS = [
  { icone: Route, titulo: "Pedido vira rota sozinho", texto: "O cliente pede pelo site; o sistema junta as entregas perto e oferece ao motoboy certo." },
  { icone: MapPinned, titulo: "GPS ao vivo, de verdade", texto: "Cada motoboy no mapa, o caminho feito pelas ruas e o link de rastreio para quem recebe." },
  { icone: Bike, titulo: "App do motoboy", texto: "Corridas, comprovante com foto e assinatura, holerite e até sem internet." },
  { icone: Wallet, titulo: "Dinheiro organizado", texto: "PIX e cartão, faturas por cliente, divisão com o motoboy e a sua parte, tudo calculado." },
  { icone: MessagesSquare, titulo: "Conversa no lugar certo", texto: "Chat da equipe, com o cliente e um grupo para cada corrida." },
  { icone: LockKeyhole, titulo: "A marca é sua", texto: "Seu nome, seu logo e suas cores no app e no site que o cliente usa." },
];

/** Página de vendas da Delibra com o cadastro do teste grátis (o Dev abre e fecha). */
export function Comecar() {
  const [cad, setCad] = useState<{ aberto: boolean; dias: number } | null>(null);
  const [f, setF] = useState({ empresa: "", documento: "", nome: "", email: "", senha: "", site: "" });
  const [enviando, setEnviando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [pronto, setPronto] = useState(false);
  useEffect(() => { void supabase().rpc("cadastro_empresas_aberto").then(({ data }) => setCad((data as { aberto: boolean; dias: number }) ?? { aberto: false, dias: 0 })); }, []);
  const muda = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value });

  async function enviar(e: React.FormEvent) {
    e.preventDefault();
    setEnviando(true); setErro(null);
    const r = await fetch("/api/empresas/cadastro", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(f) });
    const j = (await r.json().catch(() => ({}))) as { ok?: boolean; erro?: string };
    setEnviando(false);
    if (!j.ok) return setErro(j.erro ?? "Não deu agora. Tente de novo.");
    await supabase().auth.signInWithPassword({ email: f.email.trim().toLowerCase(), password: f.senha }).catch(() => null);
    setPronto(true);
  }

  return (
    <main className="dlb">
      <header className="dlb-topo">
        <strong className="dlb-marca">Delibra</strong>
        <Link href="/entrar" className="dlb-link">Entrar</Link>
      </header>

      <section className="dlb-hero">
        <div className="dlb-hero-texto">
          <h1>A central da sua empresa de entregas.</h1>
          <p>Pedidos, rotas, motoboys com GPS ao vivo, pagamentos e conversa com o cliente, num lugar só. Feito para quem vive de coleta e entrega no Brasil.</p>
          <a href="#comecar" className="dlb-botao">{cad?.aberto ? `Começar ${cad.dias > 0 ? `${cad.dias} dias grátis` : "agora"}` : "Quero conhecer"}</a>
        </div>
        <svg className="dlb-rota" viewBox="0 0 420 320" role="img" aria-label="Uma rota saindo da coleta e passando por três entregas">
          <defs>
            <linearGradient id="dlbOuro" x1="0" x2="1"><stop offset="0" stopColor="#f3d27a" /><stop offset="1" stopColor="#b8901f" /></linearGradient>
          </defs>
          {Array.from({ length: 8 }, (_, i) => <line key={`h${i}`} x1="0" x2="420" y1={20 + i * 40} y2={20 + i * 40} className="dlb-rua" />)}
          {Array.from({ length: 11 }, (_, i) => <line key={`v${i}`} y1="0" y2="320" x1={10 + i * 40} x2={10 + i * 40} className="dlb-rua" />)}
          <path className="dlb-caminho" d="M50 260 L50 180 L130 180 L130 100 L250 100 L250 60 L370 60 L370 220 L290 220" />
          <circle cx="50" cy="260" r="11" className="dlb-coleta" />
          {[[130, 100], [370, 60], [290, 220]].map(([x, y], i) => <circle key={i} cx={x} cy={y} r="9" className="dlb-entrega" style={{ animationDelay: `${0.9 + i * 0.55}s` }} />)}
          <circle r="7" className="dlb-moto"><animateMotion dur="5.5s" repeatCount="indefinite" path="M50 260 L50 180 L130 180 L130 100 L250 100 L250 60 L370 60 L370 220 L290 220" /></circle>
        </svg>
      </section>

      <section className="dlb-recursos">
        {RECURSOS.map((r) => (
          <article key={r.titulo} className="dlb-recurso">
            <r.icone size={22} aria-hidden />
            <h2>{r.titulo}</h2>
            <p>{r.texto}</p>
          </article>
        ))}
      </section>

      <section id="comecar" className="dlb-cadastro">
        {pronto ? (
          <div className="dlb-pronto">
            <Check size={30} aria-hidden />
            <h2>Sua empresa está pronta.</h2>
            <p>Entre no painel para cadastrar a equipe, os clientes e as zonas de preço.</p>
            <Link href="/gestor/inicio" className="dlb-botao">Abrir o painel</Link>
          </div>
        ) : cad?.aberto ? (
          <form onSubmit={enviar} className="dlb-form">
            <h2>{cad.dias > 0 ? `Teste grátis por ${cad.dias} dias` : "Crie a conta da sua empresa"}</h2>
            <p className="dlb-dica">Sem cartão. Você entra no painel na hora.</p>
            <label>Nome da empresa<input required value={f.empresa} onChange={muda("empresa")} maxLength={80} autoComplete="organization" /></label>
            <label>CNPJ (opcional)<input value={f.documento} onChange={muda("documento")} inputMode="numeric" maxLength={18} /></label>
            <label>Seu nome<input required value={f.nome} onChange={muda("nome")} maxLength={80} autoComplete="name" /></label>
            <label>E-mail<input required type="email" value={f.email} onChange={muda("email")} autoComplete="email" /></label>
            <label>Senha<input required type="password" minLength={8} value={f.senha} onChange={muda("senha")} autoComplete="new-password" /></label>
            <input className="dlb-escondido" tabIndex={-1} autoComplete="off" value={f.site} onChange={muda("site")} aria-hidden />
            {erro && <p className="dlb-erro" role="alert">{erro}</p>}
            <button type="submit" className="dlb-botao" disabled={enviando}>{enviando ? "Criando…" : "Criar minha empresa"}</button>
          </form>
        ) : cad ? (
          <div className="dlb-pronto">
            <h2>Quer a Delibra na sua empresa?</h2>
            <p>Estamos abrindo aos poucos. Fale com a gente e montamos tudo com você.</p>
            <Link href="/suporte" className="dlb-botao">Falar com a gente</Link>
          </div>
        ) : null}
      </section>
      <footer className="dlb-rodape">Delibra · feito no Brasil para quem entrega</footer>
    </main>
  );
}
