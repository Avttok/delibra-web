"use client";

import { IntegracoesDev } from "./Integracoes";

import { useCallback, useEffect, useState } from "react";
import { PagamentosDev } from "@/features/pagamentos/PagamentosDev";
import { Bike, ShieldCheck, UserRound } from "lucide-react";
import { ApagarTudo } from "./ApagarTudo";
import { AparelhosDev, ModulosDev, TarefasDev, type Aparelho, type Tarefa } from "./DevExtras";
import { VersaoApp } from "./VersaoApp";
import { ConversasDev, DevOculto, EmpresasDev, FaturamentoDev } from "./Plataforma";
import { SaudeDev, UsuariosDev } from "./UsuariosDev";
import { PermissoesDev } from "./PermissoesDev";
import { supabase } from "@/lib/supabase/client";
import { useConta, type Papel } from "@/features/conta/conta";
import { toast } from "@/features/ui/toast";
import { usePathname } from "next/navigation";
import { areaDoCaminho } from "./AreaDev";
import { ComandoDev } from "./Comando";
import { MatrizDev, RegrasDev } from "./Fantasma";
import { ExploradorDev, MinhaContaDev, NovidadesDev, RegistroDev } from "./Dados";
import Link from "next/link";

interface ModuloLinha { chave: string; nome: string; descricao: string | null; grupo: string; ligado: boolean; papeis: Papel[] | null; ordem: number }
interface Painel {
  contagens: Record<string, number>;
  aparelhos: { id: string; nome: string; versao_app: string | null; status: string; posicao_em: string | null; bateria: number | null; precisao_m: number | null; modo_economia: boolean; modo_teste: boolean; pings_24h?: number; push?: boolean }[];
  tarefas?: Tarefa[];
  exclusoes: { tipo: string; rotulo: string; motivo: string | null; por: string | null; quando: string }[];
}

const CONTAGENS: { titulo: string; itens: [string, string, ("n" | "r$" | "mb")?][] }[] = [
  { titulo: "Pessoas", itens: [["contas", "Contas"], ["motoboys", "Motoboys"], ["gestores", "Gestores"], ["clientes", "Clientes"], ["motoboys_online", "Online agora"], ["em_corrida", "Em corrida"]] },
  { titulo: "Operação", itens: [["pedidos", "Pedidos"], ["pedidos_abertos", "Pedidos abertos"], ["corridas_reais", "Rotas reais"], ["corridas_teste", "Rotas de teste"],
    ["corridas_ativas", "Rotas ativas"], ["no_quadro", "No quadro"], ["ofertas_pendentes", "Ofertas pendentes"]] },
  { titulo: "Dinheiro (30 dias, real)", itens: [["faturado_30d", "Faturado", "r$"], ["motoboys_30d", "Motoboys", "r$"], ["dev_30d", "Dev", "r$"], ["faturas", "Faturas"], ["holerites", "Holerites"]] },
  { titulo: "Dados", itens: [["pings_24h", "Pings (24 h)"], ["pings_total", "Pings no banco"], ["trechos_ruas", "Trechos pelas ruas"], ["mensagens_chat", "Mensagens no chat"],
    ["excecoes", "Exceções"], ["configuracoes_mudadas", "Ajustes salvos"], ["corridas_apagadas", "Rotas apagadas"], ["contas_excluidas", "Contas excluídas"], ["tamanho_banco_mb", "Banco", "mb"]] },
];
const PAPEIS_MODULO: { p: Papel; rotulo: string; icone: typeof Bike }[] = [
  { p: "gestor", rotulo: "Gestores", icone: ShieldCheck }, { p: "motoboy", rotulo: "Motoboys", icone: Bike }, { p: "cliente", rotulo: "Clientes", icone: UserRound },
];

/** Delibra Dev: cada área do console. A navegação fica no AreaDev; aqui só o conteúdo. */
export function PainelDev() {
  const conta = useConta();
  const area = areaDoCaminho(usePathname());
  const [oculto, setOculto] = useState(false);
  const lerOculto = useCallback(() => {
    void supabase().auth.getUser().then(({ data: u }) => supabase().from("perfis").select("dev_oculto").eq("id", u.user?.id ?? "").maybeSingle()
      .then(({ data }) => setOculto(Boolean(data?.dev_oculto))));
  }, []);
  useEffect(() => { lerOculto(); }, [lerOculto]);
  const [modulos, setModulos] = useState<ModuloLinha[]>([]);
  const [painel, setPainel] = useState<Painel | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [sub, setSub] = useState<Record<string, string>>({});
  const aba = (a: string, padrao: string) => sub[a] ?? padrao;
  const Sub = ({ a, opcoes }: { a: string; opcoes: [string, string][] }) => (
    <div className="filtro dev-sub">{opcoes.map(([k, r]) => <button key={k} className={aba(a, opcoes[0][0]) === k ? "ativo" : ""} onClick={() => setSub({ ...sub, [a]: k })}>{r}</button>)}</div>
  );

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [m, p] = await Promise.all([sb.from("modulos").select("*").order("grupo").order("ordem"), sb.rpc("painel_dev")]);
    if (m.error || p.error) return setErro((m.error ?? p.error)!.message);
    setModulos(m.data as ModuloLinha[]);
    setPainel(p.data as Painel);
  }, []);
  useEffect(() => { if (conta.dev) carregar(); }, [conta.dev, carregar]);

  async function salvar(m: ModuloLinha, ligado: boolean, papeis: Papel[] | null) {
    setModulos((l) => l.map((x) => (x.chave === m.chave ? { ...x, ligado, papeis } : x)));
    const { error } = await supabase().rpc("definir_modulo", { p_chave: m.chave, p_ligado: ligado, p_papeis: papeis && papeis.length ? papeis : null });
    if (error) { toast(error.message, "erro"); carregar(); return; }
    toast(`${m.nome}: ${ligado ? "ligado" : "desligado"}${papeis?.length ? ` · só ${papeis.map((p) => PAPEIS_MODULO.find((x) => x.p === p)?.rotulo.toLowerCase()).join(", ")}` : ""}`, "ok");
    conta.recarregar();
  }
  if (!conta.dev) return null;

  return (
    <div className="dev-area">
      {erro && <p className="erro">{erro}</p>}
      {area === "comando" && <ComandoDev />}
      {area === "sistema" && (<>
        <Sub a="sistema" opcoes={[["numeros", "Números"], ["saude", "Saúde"], ["aparelhos", "Aparelhos"], ["tarefas", "Tarefas automáticas"], ["apagar", "Apagar"]]} />
        {aba("sistema", "numeros") === "numeros" && (painel ? CONTAGENS.map((g) => (
          <section key={g.titulo} style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <span className="rotulo">{g.titulo}</span>
            <div className="dev-grade">{g.itens.map(([k, r, f]) => {
              const v = Number(painel.contagens[k] ?? 0);
              return <div key={k} className="dev-num"><strong>{f === "r$" ? v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" }) : f === "mb" ? `${v.toLocaleString("pt-BR")} MB` : v.toLocaleString("pt-BR")}</strong><span>{r}</span></div>;
            })}</div>
          </section>
        )) : <p className="dica">Carregando…</p>)}
        {aba("sistema", "numeros") === "saude" && <SaudeDev />}
        {aba("sistema", "numeros") === "aparelhos" && painel && <AparelhosDev aparelhos={painel.aparelhos as Aparelho[]} />}
        {aba("sistema", "numeros") === "tarefas" && painel && <TarefasDev tarefas={(painel.tarefas ?? []) as Tarefa[]} onMudou={() => void carregar()} />}
        {aba("sistema", "numeros") === "apagar" && <ApagarTudo />}
      </>)}
      {area === "regras" && <RegrasDev />}
      {area === "modulos" && <ModulosDev modulos={modulos} onSalvar={salvar} />}
      {area === "permissoes" && (<>
        <Sub a="perm" opcoes={[["matriz", "Pessoa × permissão"], ["gestores", "O que os gestores podem"]]} />
        {aba("perm", "matriz") === "matriz" ? <MatrizDev /> : <PermissoesDev />}
      </>)}
      {area === "ajustes" && (<>
        <Sub a="ajustes" opcoes={[["versao", "Versão do app"], ["integracoes", "Integrações"], ["sistema", "Todos os ajustes"]]} />
        {aba("ajustes", "versao") === "versao" && <VersaoApp />}
        {aba("ajustes", "versao") === "integracoes" && <IntegracoesDev />}
        {aba("ajustes", "versao") === "sistema" && (
          <div className="explicar-dev vidro-sutil">
            <p>Os ajustes de todo o sistema (e os só do Dev) ficam na tela de Ajustes. Com uma empresa em foco, o que você salva vale só para ela.</p>
            <Link className="botao-ouro" href="/gestor/configuracoes">Abrir os Ajustes</Link>
            <p className="dica">Para mudar um ajuste só para uma pessoa, um cliente ou um cargo, use as Regras do Fantasma.</p>
          </div>
        )}
      </>)}
      {area === "empresas" && (<>
        <Sub a="emp" opcoes={[["empresas", "Empresas"], ["faturamento", "Faturamento"], ["pagamentos", "Pagamentos"]]} />
        {aba("emp", "empresas") === "empresas" && <EmpresasDev />}
        {aba("emp", "empresas") === "faturamento" && <FaturamentoDev />}
        {aba("emp", "empresas") === "pagamentos" && <PagamentosDev />}
      </>)}
      {area === "pessoas" && <UsuariosDev />}
      {area === "dados" && <ExploradorDev />}
      {area === "auditoria" && (<>
        <Sub a="aud" opcoes={[["dev", "Registro do Dev"], ["exclusoes", "Exclusões"], ["conversas", "Conversas"]]} />
        {aba("aud", "dev") === "dev" && <RegistroDev />}
        {aba("aud", "dev") === "conversas" && <ConversasDev />}
        {aba("aud", "dev") === "exclusoes" && (painel && painel.exclusoes.length ? (
          <table className="dev-tabela">
            <thead><tr><th>O quê</th><th>Por</th><th>Quando</th><th>Motivo</th></tr></thead>
            <tbody>{painel.exclusoes.map((x, i) => (
              <tr key={i}><td>{x.tipo === "conta" ? "Conta" : "Corrida"} {x.rotulo}</td><td>{x.por ?? "—"}</td><td>{new Date(x.quando).toLocaleString("pt-BR")}</td><td>{x.motivo ?? "—"}</td></tr>
            ))}</tbody>
          </table>) : <p className="vazio">Nada apagado até agora.</p>)}
      </>)}
      {area === "novidades" && <NovidadesDev />}
      {area === "conta" && <MinhaContaDev oculto={oculto} onMudou={lerOculto} />}
    </div>
  );
}
