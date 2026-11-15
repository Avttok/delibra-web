import Link from "next/link";
import type { ReactNode } from "react";

/**
 * Termos de uso e política de privacidade da Delibra.
 * Ao mudar o texto de forma relevante, mude também a versão em Console Dev → Ajustes → Plataforma → "Versão dos termos":
 * todos aceitam de novo ao entrar. A data abaixo é só a exibida.
 */
export const DATA_DOS_TERMOS = "15 de novembro de 2026";

function Pagina({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <main className="legal">
      <h1>{titulo}</h1>
      <p className="legal-data">Atualizado em {DATA_DOS_TERMOS}</p>
      {children}
      <p className="legal-contato">Dúvidas ou pedidos sobre estes documentos: <Link href="/suporte">Central de ajuda</Link>.</p>
    </main>
  );
}

export function TermosDeUso() {
  return (
    <Pagina titulo="Termos de uso">
      <p>Estes termos valem para quem usa a Delibra: transportadoras e seus gestores e supervisores, motoboys, clientes que pedem coletas e entregas, e lojas que usam a nossa API. Ao criar a conta ou continuar usando, você concorda com eles e com a <Link href="/privacidade">política de privacidade</Link>.</p>

      <h2>1. O que é a Delibra</h2>
      <p>A Delibra é um sistema para transportadoras organizarem coletas e entregas: pedidos, rotas, acompanhamento por GPS, pagamento dos motoboys, faturas e conversas. Cada transportadora usa a Delibra com a própria marca e define as próprias regras, preços e processos.</p>
      <p>A Delibra fornece o sistema. Quem presta o serviço de entrega é a transportadora. Preço, prazo, pagamento do motoboy, cobrança do cliente, responsabilidade pela carga e atendimento são combinados entre a transportadora, o cliente e o motoboy.</p>

      <h2>2. Contas</h2>
      <ul>
        <li>Cada pessoa usa a própria conta e cuida da própria senha. O que for feito com a sua conta conta como feito por você.</li>
        <li>Os dados do cadastro precisam ser verdadeiros e ficar atualizados.</li>
        <li>A transportadora pode criar, bloquear e excluir as contas da equipe e dos clientes dela.</li>
        <li>A Delibra pode bloquear contas usadas para fraude, abuso ou contra a lei.</li>
      </ul>

      <h2>3. Motoboys</h2>
      <ul>
        <li>Enquanto você está <strong>online</strong> ou <strong>em corrida</strong>, o app envia a sua localização, mesmo com a tela desligada ou o app em segundo plano. É assim que as rotas chegam até você e que a transportadora e quem recebe acompanham a entrega. Ao ficar offline, o envio para.</li>
        <li>Fotos, assinaturas e nomes registrados nas paradas servem de comprovante da coleta e da entrega.</li>
        <li>O jogo do app não pode ser usado com o veículo em movimento. Nunca mexa no celular dirigindo.</li>
        <li>O botão de emergência avisa a transportadora com a sua localização. Ele não substitui ligar para 190 ou 192.</li>
      </ul>

      <h2>4. Clientes e lojas</h2>
      <ul>
        <li>O pedido precisa trazer endereços, contatos e itens corretos. Não é permitido enviar itens proibidos por lei ou recusados pela transportadora.</li>
        <li>Quem usa a API cuida da própria chave e não a compartilha. A chave pode ser cancelada a qualquer momento pelo gestor da transportadora.</li>
        <li>O link de acompanhamento mostra a posição do motoboy durante a entrega. Compartilhe só com quem vai receber.</li>
      </ul>

      <h2>5. Pagamentos</h2>
      <p>Pagamentos com PIX, cartão ou boleto passam por provedores parceiros (como Mercado Pago e Asaas), que seguem as próprias regras. A Delibra não guarda número de cartão. Notas fiscais são emitidas por emissores parceiros em nome de quem presta o serviço.</p>

      <h2>6. O que não é permitido</h2>
      <ul>
        <li>Tentar acessar dados de outras empresas ou contas, burlar limites ou derrubar o sistema.</li>
        <li>Usar a Delibra para enganar, perseguir ou expor pessoas.</li>
        <li>Copiar ou revender o sistema sem autorização.</li>
      </ul>

      <h2>7. Disponibilidade</h2>
      <p>Trabalhamos para que a Delibra fique no ar o tempo todo, mas pode haver paradas para manutenção ou por falhas de internet, do celular ou de serviços de terceiros (mapas, GPS, provedores de pagamento). A localização depende do GPS e da internet do aparelho e pode ter imprecisões.</p>

      <h2>8. Responsabilidade</h2>
      <p>A Delibra responde pelo funcionamento do sistema nos limites da lei. Não responde pelo serviço de entrega em si, pelas combinações entre transportadora, cliente e motoboy, nem por danos causados por uso indevido das contas.</p>

      <h2>9. Mudanças</h2>
      <p>Podemos atualizar estes termos. Quando a mudança for relevante, pedimos que você aceite de novo ao entrar.</p>

      <h2>10. Lei e foro</h2>
      <p>Valem as leis do Brasil, inclusive o Código de Defesa do Consumidor quando se aplicar. Fica eleito o foro do domicílio do consumidor, ou, nos demais casos, o da sede da Delibra.</p>
    </Pagina>
  );
}

export function PoliticaPrivacidade() {
  return (
    <Pagina titulo="Política de privacidade">
      <p>Esta política explica quais dados a Delibra usa, para quê, com quem compartilha e como você exerce os seus direitos pela Lei Geral de Proteção de Dados (Lei 13.709/2018).</p>

      <h2>1. Quem cuida dos seus dados</h2>
      <p>A transportadora que você usa decide como os dados da operação dela são usados (é a <strong>controladora</strong>). A Delibra guarda e processa esses dados para fazer o sistema funcionar (é a <strong>operadora</strong>). Para os dados das próprias transportadoras e de quem visita o nosso site, a Delibra é a controladora.</p>

      <h2>2. Quais dados</h2>
      <ul>
        <li><strong>Cadastro:</strong> nome, e-mail, telefone, foto, documento (CPF ou CNPJ), endereço e empresa.</li>
        <li><strong>Localização do motoboy:</strong> posição, velocidade, precisão e bateria, enquanto ele está online ou em corrida, inclusive com o app em segundo plano.</li>
        <li><strong>Pedidos e entregas:</strong> endereços, contatos de coleta e entrega, itens, horários, fotos, assinaturas e nomes de quem recebeu, avaliações.</li>
        <li><strong>Conversas:</strong> mensagens, fotos e áudios do chat.</li>
        <li><strong>Pagamentos:</strong> valores, faturas, holerites e chaves PIX. Dados de cartão ficam só com o provedor de pagamento.</li>
        <li><strong>Uso do app:</strong> versão, modelo do aparelho, registros de acesso e relatórios de erro (para corrigir travamentos).</li>
      </ul>

      <h2>3. Para quê</h2>
      <ul>
        <li>Oferecer as rotas aos motoboys certos, acompanhar entregas e mostrar o percurso feito (execução do contrato).</li>
        <li>Comprovar coletas e entregas, calcular preços, pagamentos e faturas (execução do contrato e obrigações legais e fiscais).</li>
        <li>Segurança: botão de emergência, registro de quem mudou o quê, prevenção de fraude (legítimo interesse e proteção da vida).</li>
        <li>Melhorar o sistema e corrigir erros (legítimo interesse).</li>
        <li>Mandar avisos sobre os seus pedidos por e-mail, WhatsApp ou notificação (execução do contrato; você pode desligar os que não forem essenciais).</li>
      </ul>
      <p>Não vendemos dados pessoais e não usamos os seus dados para publicidade de terceiros.</p>

      <h2>4. Com quem compartilhamos</h2>
      <ul>
        <li>Com a transportadora e a equipe dela, e com o cliente e quem recebe a entrega, no limite do que cada um precisa ver.</li>
        <li>Com fornecedores que fazem o sistema funcionar: hospedagem e banco de dados (Vercel, Supabase), notificações (Google Firebase), mapas e rotas (OpenStreetMap, OSRM, Valhalla), pagamentos (Mercado Pago, Asaas), notas fiscais (Focus NFe e similares), e-mail e WhatsApp, quando a transportadora liga esses serviços.</li>
        <li>Com lojas conectadas pela API, só os dados dos pedidos delas.</li>
        <li>Com autoridades, quando a lei exigir.</li>
      </ul>
      <p>Alguns desses fornecedores guardam dados fora do Brasil, com as garantias exigidas pela LGPD.</p>

      <h2>5. Por quanto tempo</h2>
      <p>Guardamos os dados enquanto a conta existir e pelo tempo que a lei exigir (por exemplo, dados fiscais). O histórico de localização e as conversas seguem os prazos definidos pela transportadora e pela plataforma. Relatórios de erro do app ficam 30 dias. Ao excluir uma conta, a transportadora escolhe manter o histórico das entregas ou apagar tudo.</p>

      <h2>6. Seus direitos</h2>
      <p>Você pode pedir para confirmar se tratamos os seus dados, acessar, corrigir, levar para outro serviço, apagar o que não for obrigatório guardar, saber com quem compartilhamos e revogar consentimentos. Peça à transportadora que você usa ou fale conosco pela <Link href="/suporte">Central de ajuda</Link>. Você também pode reclamar à Autoridade Nacional de Proteção de Dados (ANPD).</p>

      <h2>7. Segurança</h2>
      <p>Os dados trafegam com criptografia, cada empresa só enxerga os próprios dados, as senhas não ficam guardadas em texto e há verificação em dois passos. Nenhum sistema é totalmente imune; se houver um incidente que traga risco, avisamos você e a ANPD.</p>

      <h2>8. Crianças</h2>
      <p>A Delibra não é feita para menores de 18 anos.</p>

      <h2>9. Mudanças</h2>
      <p>Quando esta política mudar de forma relevante, pedimos que você aceite de novo ao entrar.</p>
    </Pagina>
  );
}
