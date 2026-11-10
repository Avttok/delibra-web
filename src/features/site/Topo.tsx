import Link from "next/link";
import { Logo } from "@/features/marca/Logo";

/** Topo das páginas públicas (início, app do motoboy, ajuda). */
export function TopoSite({ atual }: { atual?: "inicio" | "app" | "ajuda" }) {
  return (
    <header className="lp-topo">
      <Link href="/" className="lp-marca" aria-label="Delibra, início"><Logo /></Link>
      <nav className="lp-nav" aria-label="Páginas">
        <Link href="/#como" className={atual === "inicio" ? "ativo" : undefined}>Como funciona</Link>
        <Link href="/app" className={atual === "app" ? "ativo" : undefined}>App do motoboy</Link>
        <Link href="/suporte" className={atual === "ajuda" ? "ativo" : undefined}>Ajuda</Link>
      </nav>
      <Link href="/entrar" className="lp-entrar">Entrar</Link>
    </header>
  );
}

export function RodapeSite() {
  return (
    <footer className="lp-rodape">
      <Logo />
      <nav aria-label="Rodapé">
        <Link href="/entrar">Entrar</Link>
        <Link href="/entrar?criar=1">Criar conta da empresa</Link>
        <Link href="/app">Baixar o app do motoboy</Link>
        <Link href="/suporte">Central de ajuda</Link>
      </nav>
      <p>Um projeto de irmão para irmão.</p>
    </footer>
  );
}
