import { Bike, CodeXml, FlaskConical, ShieldCheck, UserCog, UserRound } from "lucide-react";
import type { Papel } from "./conta";

/** Ícone e cor de cada cargo (mesmos do app). */
export const CARGO: Record<Papel, { rotulo: string; icone: typeof Bike; cor: string }> = {
  dev: { rotulo: "Dev", icone: CodeXml, cor: "var(--cor-dev)" },
  gestor: { rotulo: "Gestor", icone: ShieldCheck, cor: "var(--ouro)" },
  supervisor: { rotulo: "Supervisor", icone: UserCog, cor: "var(--ouro-claro)" },
  motoboy: { rotulo: "Motoboy", icone: Bike, cor: "var(--texto-2)" },
  cliente: { rotulo: "Cliente", icone: UserRound, cor: "var(--texto-2)" },
};
export const ORDEM_CARGOS: Papel[] = ["dev", "gestor", "supervisor", "motoboy", "cliente"];
/** O cargo de maior hierarquia (Dev > Gestor > Supervisor > Motoboy > Cliente). */
export const cargoPrincipal = (papeis: string[]): Papel | null => ORDEM_CARGOS.find((p) => papeis.includes(p)) ?? null;

/** O que o gestor pode liberar para cada supervisor (padrão entre parênteses). */
export const PERMISSOES_SUPERVISOR: { chave: string; rotulo: string; padrao: boolean }[] = [
  { chave: "pedidos", rotulo: "Revisar e aprovar pedidos", padrao: true },
  { chave: "rotas", rotulo: "Montar, mover e despachar rotas", padrao: true },
  { chave: "motoboys", rotulo: "Acompanhar e falar com os motoboys", padrao: true },
  { chave: "mapa", rotulo: "Ver o mapa ao vivo", padrao: true },
  { chave: "clientes", rotulo: "Ver e editar clientes", padrao: true },
  { chave: "cadastrar", rotulo: "Criar contas de motoboys e clientes", padrao: true },
  { chave: "chat", rotulo: "Criar grupos no chat", padrao: true },
  { chave: "ajustes", rotulo: "Mudar os ajustes da empresa", padrao: false },
  { chave: "financeiro", rotulo: "Ver holerites, faturas e valores", padrao: false },
  { chave: "apagar", rotulo: "Apagar pedidos, rotas e históricos", padrao: false },
];

/** Fichas dos cargos de alguém (Dev, Gestor, Motoboy) + modo teste. */
export function SelosCargo({ papeis, teste = false }: { papeis: string[]; teste?: boolean }) {
  return (
    <span className="selos-cargo">
      {ORDEM_CARGOS.filter((p) => papeis.includes(p)).map((p) => {
        const { rotulo, icone: Icone, cor } = CARGO[p];
        return <span key={p} className={`selo selo-cargo cargo-${p}`} style={{ color: cor }}><Icone size={11} aria-hidden /> {rotulo}</span>;
      })}
      {teste && <span className="selo selo-cargo" style={{ color: "#a78bfa" }}><FlaskConical size={11} aria-hidden /> Teste</span>}
    </span>
  );
}
