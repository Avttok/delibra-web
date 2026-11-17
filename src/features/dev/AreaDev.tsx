"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";
import { Activity, ArrowLeft, Building2, Database, Ghost, History, Megaphone, Radar, Settings2, ShieldCheck, ToggleRight, UserRound, Users } from "lucide-react";
import { ModoDev } from "./ModoDev";
import { useConta } from "@/features/conta/conta";

export type AreaDevId = "comando" | "empresas" | "modulos" | "permissoes" | "regras" | "ajustes" | "dados" | "auditoria" | "pessoas" | "novidades" | "sistema" | "conta";

export const AREAS_DEV: { titulo: string; areas: { id: AreaDevId; rotulo: string; icone: typeof Radar; dica: string }[] }[] = [
  { titulo: "Agora", areas: [
    { id: "comando", rotulo: "Comando ao vivo", icone: Radar, dica: "O sistema inteiro neste segundo, avisos e emergência" },
    { id: "sistema", rotulo: "Sistema", icone: Activity, dica: "Números, saúde, aparelhos, tarefas e limpeza" }] },
  { titulo: "Controle", areas: [
    { id: "regras", rotulo: "Regras do Fantasma", icone: Ghost, dica: "Quem vê o quê, quando e por quê" },
    { id: "modulos", rotulo: "Módulos", icone: ToggleRight, dica: "Cada parte do sistema: para todos, por empresa, por cargo" },
    { id: "permissoes", rotulo: "Permissões", icone: ShieldCheck, dica: "Pessoa × permissão, com o porquê de cada uma" },
    { id: "ajustes", rotulo: "Ajustes da plataforma", icone: Settings2, dica: "Ajustes, versão do app e integrações" }] },
  { titulo: "Negócio", areas: [
    { id: "empresas", rotulo: "Empresas", icone: Building2, dica: "Empresas, faturamento e pagamentos" },
    { id: "pessoas", rotulo: "Pessoas", icone: Users, dica: "Todas as contas do sistema" }] },
  { titulo: "Por dentro", areas: [
    { id: "dados", rotulo: "Explorador de dados", icone: Database, dica: "Qualquer tabela, só leitura" },
    { id: "auditoria", rotulo: "Auditoria", icone: History, dica: "Registro do Dev, exclusões e conversas" },
    { id: "novidades", rotulo: "Novidades", icone: Megaphone, dica: "O que mudou, por área" }] },
  { titulo: "Você", areas: [
    { id: "conta", rotulo: "Minha conta Dev", icone: UserRound, dica: "Invisível, suas regras e seu jeito de ver" }] },
];

export function areaDoCaminho(caminho: string | null): AreaDevId {
  const s = (caminho ?? "").split("/")[3] as AreaDevId | undefined;
  return AREAS_DEV.some((g) => g.areas.some((a) => a.id === s)) ? s! : "comando";
}

/** A terceira parte da Delibra: o console do Dev, com entrada, navegação e cara próprias. */
export function AreaDev({ children, nome }: { children: ReactNode; nome: string }) {
  const caminho = usePathname();
  const conta = useConta();
  const atual = areaDoCaminho(caminho);
  const info = AREAS_DEV.flatMap((g) => g.areas).find((a) => a.id === atual)!;
  if (!conta.dev) {
    return <main className="tela-login"><div className="caixa-login vidro"><p className="erro">Esta área é só do Dev.</p><Link className="botao-ouro" href="/gestor/inicio">Voltar</Link></div></main>;
  }
  return (
    <div className="dev-shell">
      <aside className="dev-trilho" aria-label="Delibra Dev">
        <Link href="/gestor/dev/comando" className="dev-marca">
          <Ghost size={22} aria-hidden />
          <span><strong>Delibra Dev</strong><small>{nome}</small></span>
        </Link>
        <nav className="dev-trilho-nav">
          {AREAS_DEV.map((g) => (
            <div key={g.titulo} className="dev-trilho-grupo">
              <span>{g.titulo}</span>
              {g.areas.map((a) => (
                <Link key={a.id} href={`/gestor/dev/${a.id}`} className={a.id === atual ? "ativo" : ""} aria-current={a.id === atual ? "page" : undefined} title={a.dica}>
                  <a.icone size={16} aria-hidden /> {a.rotulo}
                </Link>
              ))}
            </div>
          ))}
        </nav>
        <Link href="/gestor/inicio" className="dev-voltar"><ArrowLeft size={15} aria-hidden /> Voltar ao sistema</Link>
      </aside>
      <div className="dev-palco">
        <header className="dev-topo">
          <div>
            <h1><info.icone size={20} aria-hidden /> {info.rotulo}</h1>
            <p>{info.dica}</p>
          </div>
          <span className="espaco" />
          <ModoDev />
          <Link href="/gestor/configuracoes" className="botao-icone" title="Todos os ajustes" aria-label="Todos os ajustes"><Settings2 size={17} aria-hidden /></Link>
        </header>
        <main className="dev-corpo">{children}</main>
      </div>
    </div>
  );
}
