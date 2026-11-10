"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { BatteryFull, Bell, Download, LocateFixed, ShieldCheck, Smartphone } from "lucide-react";
import { RodapeSite, TopoSite } from "./Topo";

const REPO = "Avttok/delibra-app";
interface Versao { build: number; url: string; tamanho: number; data: string }

/** Download do APK do motoboy: sempre a versão publicada mais nova, com o passo a passo da instalação. */
export function DownloadApp() {
  const [v, setV] = useState<Versao | null>(null);
  const [falhou, setFalhou] = useState(false);
  useEffect(() => {
    fetch(`https://api.github.com/repos/${REPO}/releases?per_page=10`)
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((l: { tag_name: string; draft: boolean; published_at: string; assets: { name: string; browser_download_url: string; size: number }[] }[]) => {
        const r = l.find((x) => !x.draft && x.tag_name.startsWith("build-") && x.assets.some((a) => a.name.endsWith(".apk")));
        if (!r) return setFalhou(true);
        const a = r.assets.find((x) => x.name.endsWith(".apk"))!;
        setV({ build: Number(r.tag_name.replace("build-", "")), url: a.browser_download_url, tamanho: a.size, data: r.published_at });
      })
      .catch(() => setFalhou(true));
  }, []);
  const mb = v ? (v.tamanho / 1048576).toLocaleString("pt-BR", { maximumFractionDigits: 1 }) : null;

  return (
    <div className="lp">
      <TopoSite atual="app" />
      <section className="lp-secao lp-baixar">
        <div>
          <Smartphone className="lp-icone-titulo" size={30} aria-hidden />
          <h1>App do motoboy</h1>
          <p className="lp-lead">Para quem entrega pela Delibra. Funciona em celulares Android 8 ou mais novos.</p>
          <div className="lp-acoes">
            {v ? <a className="lp-botao" href={v.url}><Download size={18} aria-hidden /> Baixar o app ({mb} MB)</a>
              : falhou ? <a className="lp-botao" href={`https://github.com/${REPO}/releases`}><Download size={18} aria-hidden /> Ver as versões para baixar</a>
              : <span className="lp-botao lp-botao-vazio" aria-busy="true">Procurando a versão mais nova…</span>}
          </div>
          {v && <p className="lp-nota">Versão publicada em {new Date(v.data).toLocaleDateString("pt-BR")}. O app avisa sozinho quando sair uma nova.</p>}
          <p className="lp-nota">Não tem Android? O app é só para Android por enquanto.</p>
        </div>
        <div className="lp-qr" aria-hidden>
          <Download size={40} />
          <span>Abra esta página no celular para baixar direto nele.</span>
        </div>
      </section>

      <section className="lp-secao">
        <h2>Instalando, passo a passo</h2>
        <ol className="lp-passos">
          <li><span className="lp-num">1</span><div><h3>Baixe o arquivo</h3><p>Toque em <strong>Baixar o app</strong> pelo celular. Se o Chrome perguntar se quer manter o arquivo, toque em <strong>Baixar mesmo assim</strong>: o app não vem da Play Store, por isso o aviso.</p></div></li>
          <li><span className="lp-num">2</span><div><h3>Abra o arquivo baixado</h3><p>Toque na notificação do download ou abra <strong>Arquivos → Downloads</strong> e toque em <strong>Delibra-motoboy…apk</strong>.</p></div></li>
          <li><span className="lp-num">3</span><div><h3>Libere a instalação</h3><p>Na primeira vez, o Android pede para permitir <strong>Instalar apps desconhecidos</strong> para o navegador ou o gerenciador de arquivos. Toque em <strong>Configurações</strong>, ligue a opção e volte.</p></div></li>
          <li><span className="lp-num">4</span><div><h3>Instale e abra</h3><p>Toque em <strong>Instalar</strong>. Se o Play Protect avisar, toque em <strong>Mais detalhes → Instalar mesmo assim</strong>. Depois, toque em <strong>Abrir</strong>.</p></div></li>
          <li><span className="lp-num">5</span><div><h3>Entre com a sua conta</h3><p>Use o e-mail e a senha que a Delibra criou para você. Ainda não tem? Peça ao gestor.</p></div></li>
          <li><span className="lp-num">6</span><div><h3>Dê as permissões</h3><p>O app mostra cada uma e por que precisa. Sem elas, as rotas não chegam ou a localização para.</p></div></li>
        </ol>
      </section>

      <section className="lp-secao">
        <h2>As permissões e por que o app precisa delas</h2>
        <ul className="lp-lista lp-lista-grade">
          <li><LocateFixed size={18} aria-hidden /><div><strong>Localização “o tempo todo”</strong><span>Para mandar a posição durante a rota mesmo com a tela apagada. Escolha <em>Permitir o tempo todo</em> e <em>Localização precisa</em>.</span></div></li>
          <li><Bell size={18} aria-hidden /><div><strong>Notificações</strong><span>A oferta de rota chega como chamada, com som, mesmo com o celular bloqueado.</span></div></li>
          <li><BatteryFull size={18} aria-hidden /><div><strong>Bateria sem restrição</strong><span>Alguns celulares fecham apps em segundo plano. Em <em>Bateria → Sem restrições</em> o app não é desligado no meio da rota.</span></div></li>
          <li><ShieldCheck size={18} aria-hidden /><div><strong>Instalar apps desconhecidos</strong><span>Só para o próprio app conseguir se atualizar quando sair uma versão nova.</span></div></li>
        </ul>
      </section>

      <section className="lp-secao">
        <h2>Problemas comuns</h2>
        <div className="lp-faq">
          <details><summary>“App não instalado” ou “conflito com pacote”</summary><p>Já existe uma versão instalada de outra origem. Desinstale o Delibra antigo e instale de novo por aqui. Sua conta continua a mesma.</p></details>
          <details><summary>A localização para quando apago a tela</summary><p>Confira se a localização está como <em>Permitir o tempo todo</em> e a bateria como <em>Sem restrições</em>. Em celulares Xiaomi, Samsung e Motorola, também desligue a otimização de bateria para o Delibra.</p></details>
          <details><summary>Não recebo as ofertas</summary><p>Fique online (segure o botão até o anel encher), mantenha as notificações ligadas e confira o raio de distância no app. Corridas fora do seu raio não chegam, a não ser as urgentes.</p></details>
          <details><summary>Apareceu “Atualize para continuar”</summary><p>A central pediu uma versão específica do app. Toque em <strong>Atualizar agora</strong>: ele baixa e instala sozinho.</p></details>
          <details><summary>Esqueci a senha</summary><p>Peça ao gestor da Delibra para criar uma nova senha para você.</p></details>
        </div>
        <p className="lp-nota">Quer saber mais sobre o dia a dia no app? Veja a <a href={"/ajuda?p=motoboy"}>ajuda do motoboy</a>.</p>
      </section>
      <RodapeSite />
    </div>
  );
}
