"use client";

import { IntegracoesDev } from "./Integracoes";

import { useCallback, useEffect, useState } from "react";
import { PagamentosDev } from "@/features/pagamentos/PagamentosDev";
import { Building2, MessagesSquare, Wallet, BatteryMedium, Bell, BellOff, Bike, CodeXml, Eraser, FlaskConical, History, LayoutDashboard, Rocket, ShieldCheck, Smartphone, Timer, ToggleRight, UserRound, Plug, Activity, Users } from "lucide-react";
import { ApagarTudo } from "./ApagarTudo";
import { AparelhosDev, ModulosDev, TarefasDev, type Aparelho, type Tarefa } from "./DevExtras";
import { VersaoApp } from "./VersaoApp";
import { ConversasDev, DevOculto, EmpresasDev, FaturamentoDev } from "./Plataforma";
import { SaudeDev, UsuariosDev } from "./UsuariosDev";
import { PermissoesDev } from "./PermissoesDev";
import { supabase } from "@/lib/supabase/client";
import { CabecaPagina } from "@/features/ui/CabecaPagina";
import { useConta, type Papel } from "@/features/conta/conta";
import { toast } from "@/features/ui/toast";
import { useEtapa } from "@/features/ui/useEtapa";

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

type Aba = "permissoes" | "empresas" | "usuarios" | "saude" | "faturamento" | "pagamentos" | "conversas" | "sistema" | "modulos" | "versao" | "aparelhos" | "tarefas" | "registro" | "apagar" | "integracoes";
const GRUPOS_DEV: { titulo: string; abas: { id: Aba; rotulo: string; icone: typeof Bike }[] }[] = [
  { titulo: "Agora", abas: [
    { id: "sistema", rotulo: "Visão geral", icone: LayoutDashboard }, { id: "saude", rotulo: "Saúde do sistema", icone: Activity },
    { id: "aparelhos", rotulo: "Aparelhos", icone: Smartphone }, { id: "tarefas", rotulo: "Tarefas automáticas", icone: Timer }] },
  { titulo: "Negócio", abas: [
    { id: "empresas", rotulo: "Empresas", icone: Building2 }, { id: "usuarios", rotulo: "Usuários", icone: Users },
    { id: "permissoes", rotulo: "Permissões dos gestores", icone: ShieldCheck },
    { id: "faturamento", rotulo: "Faturamento", icone: Wallet }, { id: "pagamentos", rotulo: "Pagamentos", icone: Wallet }] },
  { titulo: "Sistema", abas: [
    { id: "modulos", rotulo: "Módulos", icone: ToggleRight }, { id: "integracoes", rotulo: "Integrações", icone: Plug }, { id: "versao", rotulo: "Versão do app", icone: Rocket },
    { id: "conversas", rotulo: "Conversas", icone: MessagesSquare }, { id: "registro", rotulo: "Registro", icone: History }, { id: "apagar", rotulo: "Apagar", icone: Eraser }] },
];

function ha(iso: string | null) {
  if (!iso) return "—";
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? "agora" : s < 3600 ? `há ${Math.floor(s / 60)} min` : s < 86400 ? `há ${Math.floor(s / 3600)} h` : `há ${Math.floor(s / 86400)} d`;
}

/** Console do Dev: o sistema inteiro à vista, módulos liga/desliga e quem vê cada um. */
export function PainelDev() {
  const conta = useConta();
  const [aba, setAba] = useEtapa<Aba>("dev-aba", "sistema");
  const [oculto, setOculto] = useState(false);
  const lerOculto = useCallback(() => {
    void supabase().auth.getUser().then(({ data: u }) => supabase().from("perfis").select("dev_oculto").eq("id", u.user?.id ?? "").maybeSingle()
      .then(({ data }) => setOculto(Boolean(data?.dev_oculto))));
  }, []);
  useEffect(() => { lerOculto(); }, [lerOculto]);
  const [modulos, setModulos] = useState<ModuloLinha[]>([]);
  const [painel, setPainel] = useState<Painel | null>(null);
  const [erro, setErro] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    const sb = supabase();
    const [m, p] = await Promise.all([sb.from("modulos").select("*").order("ordem"), sb.rpc("painel_dev")]);
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

  if (!conta.dev) {
    return <main className="conteudo"><div className="formulario vidro"><p className="erro">Esta área é só do Dev.</p></div></main>;
  }

  return (
    <>
      <aside className="lateral entrar">
        <CabecaPagina icone={CodeXml} titulo="Console Dev" subtitulo="O sistema inteiro, sem filtro" />
        <nav className="dev-nav" aria-label="Áreas do Dev">
          {GRUPOS_DEV.map((g) => (
            <div key={g.titulo} className="dev-nav-grupo">
              <span>{g.titulo}</span>
              {g.abas.map((a) => (
                <button key={a.id} type="button" className={aba === a.id ? "ativo" : ""} aria-current={aba === a.id ? "page" : undefined} onClick={() => setAba(a.id)}>
                  <a.icone size={15} aria-hidden /> {a.rotulo}
                </button>
              ))}
            </div>
          ))}
        </nav>
        <button className="botao-texto" onClick={() => void carregar()}>Atualizar números</button>
        <p className="dica">Cada empresa cadastra a própria equipe. A conta do Dev só você mesmo altera.</p>
        {erro && <p className="erro">{erro}</p>}
      </aside>
      <main className="conteudo">
        <div className="formulario vidro entrar">
          {aba === "empresas" && <EmpresasDev />}
          {aba === "faturamento" && <FaturamentoDev />}
          {aba === "pagamentos" && <PagamentosDev />}
          {aba === "conversas" && <ConversasDev />}
          {aba === "usuarios" && <UsuariosDev />}
          {aba === "permissoes" && <PermissoesDev />}
          {aba === "saude" && <SaudeDev />}
          {aba === "modulos" && <ModulosDev modulos={modulos} onSalvar={salvar} />}
          {aba === "integracoes" && <IntegracoesDev />}
          {aba === "versao" && <VersaoApp />}
          {aba === "sistema" && <DevOculto oculto={oculto} onMudou={lerOculto} />}
          {aba === "sistema" && painel && (<>
            {CONTAGENS.map((g) => (
              <section key={g.titulo} style={{ display: "flex", flexDirection: "column", gap: 8 }}>
                <span className="rotulo">{g.titulo}</span>
                <div className="dev-grade">
                  {g.itens.map(([k, r, f]) => {
                    const v = Number(painel.contagens[k] ?? 0);
                    return <div key={k} className="dev-num"><strong>{f === "r$" ? v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" }) : f === "mb" ? `${v.toLocaleString("pt-BR")} MB` : v.toLocaleString("pt-BR")}</strong><span>{r}</span></div>;
                  })}
                </div>
              </section>
            ))}
          </>)}
          {aba === "aparelhos" && painel && <AparelhosDev aparelhos={painel.aparelhos as Aparelho[]} />}
          {aba === "apagar" && <ApagarTudo />}
          {aba === "tarefas" && painel && <TarefasDev tarefas={(painel.tarefas ?? []) as Tarefa[]} onMudou={() => void carregar()} />}
          {aba === "registro" && painel && (
            painel.exclusoes.length === 0 ? <p className="vazio">Nada apagado até agora.</p> : (
              <table className="dev-tabela">
                <thead><tr><th>O quê</th><th>Por</th><th>Quando</th><th>Motivo</th></tr></thead>
                <tbody>{painel.exclusoes.map((x, i) => (
                  <tr key={i}><td>{x.tipo === "conta" ? "Conta" : "Corrida"} {x.rotulo}</td><td>{x.por ?? "—"}</td><td>{new Date(x.quando).toLocaleString("pt-BR")}</td><td>{x.motivo ?? "—"}</td></tr>
                ))}</tbody>
              </table>
            )
          )}
          {!painel && !erro && !["versao", "apagar", "empresas", "faturamento", "pagamentos", "conversas", "usuarios", "saude", "permissoes", "modulos", "integracoes"].includes(aba) && <p className="dica">Carregando…</p>}
        </div>
      </main>
    </>
  );
}

