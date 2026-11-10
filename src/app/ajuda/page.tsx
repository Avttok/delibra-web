import type { Metadata } from "next";
import Link from "next/link";
import { Logo } from "@/features/marca/Logo";
import { CentralAjuda } from "@/features/ajuda/Ajuda";
import "@/features/ajuda/ajuda.css";

export const metadata: Metadata = { title: "Ajuda · Delibra", description: "Como usar o app do motoboy e o painel do gestor da Delibra." };

/** Central de ajuda do motoboy e do gestor. A do cliente fica no site do cliente. */
export default function PaginaAjuda() {
  const topo = (
    <header className="lp-topo">
      <Link href="/" className="lp-marca" aria-label="Delibra, painel"><Logo /></Link>
      <Link href="/" className="lp-entrar lp-voltar">Abrir o painel</Link>
    </header>
  );
  const rodape = (
    <footer className="lp-rodape">
      <Logo />
      <nav aria-label="Rodapé"><Link href="/">Painel do gestor</Link></nav>
      <p>Um projeto de irmão para irmão.</p>
    </footer>
  );
  return <CentralAjuda publicos={["motoboy", "gestor"]} topo={topo} rodape={rodape}
    lead="Como usar o app do motoboy e o painel do gestor. Escolha para quem é a dúvida." />;
}
