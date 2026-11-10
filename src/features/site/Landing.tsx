import Link from "next/link";
import { Bike, Building2, CalendarClock, Camera, FileText, MapPinned, PackageCheck, Radar, ReceiptText, Repeat, Route, Smartphone, Trophy, Wallet } from "lucide-react";
import { RodapeSite, TopoSite } from "./Topo";

/** Página de apresentação da Delibra (quem não entrou ainda vê esta). */
export function Landing() {
  return (
    <div className="lp">
      <TopoSite atual="inicio" />

      <section className="lp-hero">
        <div className="lp-hero-texto">
          <h1>Da coleta à entrega, cada pedido com rota no mapa.</h1>
          <p className="lp-lead">
            A Delibra busca e entrega para a sua empresa. Você pede pelo site, vê quanto custa
            e acompanha o motoboy até a última entrega.
          </p>
          <div className="lp-acoes">
            <Link href="/entrar?criar=1" className="lp-botao">Criar conta da empresa</Link>
            <Link href="/entrar" className="lp-botao lp-botao-vazio">Já tenho conta</Link>
          </div>
          <p className="lp-nota">Agilidade e segurança, do balcão ao destino.</p>
        </div>
        <MapaHero />
      </section>

      <section className="lp-secao" id="como">
        <h2>Como um pedido anda</h2>
        <ol className="lp-passos">
          <li>
            <span className="lp-num">1</span>
            <div><h3>Você pede</h3><p>Escolha agora ou agende, marque a coleta e as entregas e diga o que vai em cada uma. O valor fica no pedido.</p></div>
          </li>
          <li>
            <span className="lp-num">2</span>
            <div><h3>A Delibra monta a rota</h3><p>O pedido é revisado e entra numa rota, junto com outras entregas perto, quando dá para juntar.</p></div>
          </li>
          <li>
            <span className="lp-num">3</span>
            <div><h3>Um motoboy aceita</h3><p>A rota vai para os motoboys pelo app. Quem aceita sai para a coleta, e você acompanha no mapa.</p></div>
          </li>
          <li>
            <span className="lp-num">4</span>
            <div><h3>Entregue com comprovante</h3><p>Cada entrega fecha com o nome de quem recebeu e, se o pedido pedir, foto, assinatura ou código.</p></div>
          </li>
        </ol>
      </section>

      <section className="lp-secao lp-dupla">
        <div>
          <Building2 className="lp-icone-titulo" size={28} aria-hidden />
          <h2>Para a sua empresa</h2>
          <p className="lp-lead">Tudo o que você precisa para pedir, acompanhar e pagar, num lugar só.</p>
        </div>
        <ul className="lp-lista">
          <li><Repeat size={18} aria-hidden /><div><strong>Modelos de pedido</strong><span>Salve o pedido que se repete e refaça com um toque.</span></div></li>
          <li><PackageCheck size={18} aria-hidden /><div><strong>Itens por tipo</strong><span>Documentos, alimentos, pacotes: cada tipo pede só os campos que importam.</span></div></li>
          <li><CalendarClock size={18} aria-hidden /><div><strong>Agora ou agendado</strong><span>Peça para já ou marque o dia e a hora da coleta.</span></div></li>
          <li><MapPinned size={18} aria-hidden /><div><strong>Acompanhar no mapa</strong><span>Veja os pontos, o caminho e onde o motoboy está enquanto a rota anda.</span></div></li>
          <li><ReceiptText size={18} aria-hidden /><div><strong>Faturas</strong><span>No crédito, os pedidos entram na fatura do seu ciclo. Ou pague antes, por PIX ou cartão.</span></div></li>
          <li><FileText size={18} aria-hidden /><div><strong>Histórico</strong><span>Todos os pedidos, quem recebeu e quando, para consultar quando quiser.</span></div></li>
        </ul>
      </section>

      <section className="lp-secao lp-motoboy">
        <div className="lp-motoboy-texto">
          <Bike className="lp-icone-titulo" size={28} aria-hidden />
          <h2>Para quem entrega</h2>
          <p className="lp-lead">O app do motoboy recebe as rotas, guia até cada ponto e registra a entrega. O GPS manda a posição para a central durante a rota.</p>
          <ul className="lp-lista lp-lista-curta">
            <li><Radar size={18} aria-hidden /><div><strong>Fica online e recebe ofertas</strong><span>Com o tempo para aceitar e o valor da rota.</span></div></li>
            <li><Route size={18} aria-hidden /><div><strong>Rota passo a passo</strong><span>Coleta, entregas e o comprovante de cada uma.</span></div></li>
            <li><Wallet size={18} aria-hidden /><div><strong>Holerite</strong><span>As rotas e o valor de cada período.</span></div></li>
            <li><Trophy size={18} aria-hidden /><div><strong>Medalhas</strong><span>Conquistas por corridas, quilômetros e tempo de casa.</span></div></li>
          </ul>
          <Link href="/app" className="lp-botao"><Smartphone size={18} aria-hidden /> Baixar o app para Android</Link>
        </div>
        <div className="lp-celular" aria-hidden>
          <div className="lp-celular-tela">
            <span className="lp-celular-orbe"><span>ONLINE</span></span>
            <span className="lp-celular-linha" />
            <span className="lp-celular-linha curta" />
          </div>
        </div>
      </section>

      <section className="lp-secao lp-fim">
        <h2>Comece pelo cadastro da empresa</h2>
        <p className="lp-lead">Leva poucos minutos. Depois de aprovado, você já pode pedir.</p>
        <div className="lp-acoes">
          <Link href="/entrar?criar=1" className="lp-botao">Criar conta da empresa</Link>
          <Link href="/suporte" className="lp-botao lp-botao-vazio">Ver a central de ajuda</Link>
        </div>
      </section>

      <RodapeSite />
    </div>
  );
}

/** Um trecho de cidade estilizado: a rota se desenha da coleta às entregas (uma vez, ao abrir). */
function MapaHero() {
  return (
    <div className="lp-mapa" aria-hidden>
      <svg viewBox="0 0 520 440" role="presentation">
        <defs>
          <linearGradient id="lpOuro" x1="0" y1="0" x2="1" y2="1">
            <stop offset="0" stopColor="#f3d77e" /><stop offset=".55" stopColor="#d4af37" /><stop offset="1" stopColor="#8f7019" />
          </linearGradient>
        </defs>
        <g className="lp-ruas">
          <path d="M-10 70 L530 40" /><path d="M-10 170 L530 150" /><path d="M-10 290 L530 300" /><path d="M-10 390 L530 410" />
          <path d="M60 -10 L90 450" /><path d="M190 -10 L180 450" /><path d="M320 -10 L340 450" /><path d="M450 -10 L430 450" />
          <path d="M-10 240 Q 200 210 530 230" className="avenida" />
          <path d="M240 -10 Q 270 220 250 450" className="avenida" />
        </g>
        <path className="lp-rota" d="M92 300 L180 294 L186 165 L330 152 L338 300 L432 304 L440 160" />
        <g className="lp-pino coleta" transform="translate(92 300)"><circle r="15" /><text y="5">1</text></g>
        <g className="lp-pino" transform="translate(338 300)"><circle r="15" /><text y="5">2</text></g>
        <g className="lp-pino" transform="translate(440 160)"><circle r="15" /><text y="5">3</text></g>
        <g className="lp-moto"><circle r="9" /></g>
      </svg>
      <div className="lp-mapa-legenda">
        <span><i className="ponto coleta" /> Coleta</span>
        <span><i className="ponto" /> Entregas</span>
        <span><i className="linha" /> Caminho da rota</span>
      </div>
    </div>
  );
}
