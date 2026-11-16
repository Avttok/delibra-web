import type { Metadata } from "next";
import { headers } from "next/headers";
import { RodapeSite, TopoSite } from "@/features/site/Topo";

export const metadata: Metadata = { title: "API para lojas · Delibra", description: "Crie e acompanhe coletas e entregas direto do sistema da sua loja." };

const CRIAR = `{
  "referencia_externa": "PEDIDO-1042",
  "quando": "2026-11-20T14:00:00-03:00",
  "observacoes": "Portaria fecha às 18h",
  "pontos": [
    { "tipo": "coleta",  "endereco": "Rua das Flores, 100, Centro, Florianópolis - SC",
      "contato_nome": "Expedição", "contato_telefone": "48999990000" },
    { "tipo": "entrega", "endereco": "Av. Beira-Mar Norte, 2000, Florianópolis - SC",
      "lat": -27.5839, "lng": -48.5470,
      "contato_nome": "Ana Souza", "contato_telefone": "48988887777", "instrucoes": "Apto 302" }
  ],
  "itens": [ { "descricao": "Caixa média", "quantidade": 1, "peso_kg": 2.5, "entrega": 1 } ]
}`;

const ASSINATURA = `import crypto from "node:crypto";

// cabeçalho X-Delibra-Assinatura: "t=1763215200,v1=9f2c…"
function assinaturaValida(corpoCru, cabecalho, segredo) {
  const { t, v1 } = Object.fromEntries(cabecalho.split(",").map((p) => p.split("=")));
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false; // mais de 5 min: recusa
  const esperado = crypto.createHmac("sha256", segredo).update(\`\${t}.\${corpoCru}\`).digest("hex");
  return crypto.timingSafeEqual(Buffer.from(esperado), Buffer.from(v1 ?? ""));
}`;

export default async function Pagina() {
  const h = await headers();
  const base = `https://${h.get("x-forwarded-host") ?? h.get("host") ?? "delibra-web.vercel.app"}`;
  return (
    <>
      <TopoSite />
      <main className="legal">
        <h1>API para lojas</h1>
        <p className="legal-data">Versão v1</p>
        <p>Com a API, o sistema da sua loja cria coletas e entregas na transportadora e recebe o andamento de cada pedido, sem ninguém precisar digitar no site. Os pedidos seguem as mesmas regras, preços e horários que a transportadora definiu para a sua loja.</p>

        <h2>1. Pegue a sua chave</h2>
        <p>Peça ao gestor da transportadora. Ele gera a chave em Clientes → sua empresa → API. A chave começa com <code>dlb_</code>, aparece uma vez só e deve ficar no servidor da loja, nunca no site ou no app do seu cliente.</p>
        <pre>{`Authorization: Bearer dlb_…`}</pre>

        <h2>2. Criar um pedido</h2>
        <pre>{`POST ${base}/api/v1/pedidos
Content-Type: application/json`}</pre>
        <pre>{CRIAR}</pre>
        <ul>
          <li><strong>pontos</strong>: pelo menos uma coleta e uma entrega, na ordem. Envie <code>lat</code> e <code>lng</code> quando tiver; sem eles, procuramos o endereço no mapa.</li>
          <li><strong>quando</strong>: data e hora para agendar. Sem ele, o pedido é para agora (se a sua loja puder pedir na hora).</li>
          <li><strong>referencia_externa</strong>: o número do pedido na sua loja. Mandar de novo a mesma referência não cria outro pedido: devolve o que já existe (pode repetir sem medo se a conexão cair).</li>
          <li><strong>itens</strong>: <code>entrega</code> e <code>coleta</code> são a posição do ponto na lista, começando em 0.</li>
          <li>Outros campos: <code>urgente</code> (true/false), <code>tipo_pedido</code>, <code>observacoes</code>, <code>metodo</code> (pagamento, quando a loja paga antes).</li>
          <li><strong>extras</strong>: os campos próprios que a transportadora criou para o pedido (ex.: <code>{`{ "numero_da_nota": "123" }`}</code>). Os obrigatórios precisam vir; os que não existem são ignorados. Cada ponto também aceita <code>extras</code>.</li>
          <li><strong>veiculo</strong>: <code>moto</code>, <code>carro</code>, <code>bicicleta</code> ou <code>van</code>, quando a transportadora deixa a loja escolher. A rota só vai para quem tem esse veículo.</li>
        </ul>
        <p>Resposta <code>201</code> com o pedido (<code>id</code>, <code>numero</code>, <code>status</code>, <code>valor</code>, <code>extras</code>, <code>pontos</code> com as <code>respostas</code> que o motoboy deu em cada parada) e o link de acompanhamento em <code>rastreio</code>. Se a referência já existia, a resposta é <code>200</code> com <code>&quot;repetido&quot;: true</code>.</p>

        <h2>3. Consultar</h2>
        <pre>{`GET ${base}/api/v1/pedidos/{id}
GET ${base}/api/v1/pedidos/ref:PEDIDO-1042
GET ${base}/api/v1/pedidos?desde=2026-11-01T00:00:00-03:00&status=concluido&limite=50`}</pre>

        <h2>4. Cancelar</h2>
        <pre>{`POST ${base}/api/v1/pedidos/{id}/cancelar
{ "motivo": "Cliente desistiu" }`}</pre>
        <p>Vale a regra de cancelamento da transportadora (pedido já em rota pode não ser cancelável).</p>

        <h2>5. Status do pedido</h2>
        <table>
          <thead><tr><th>status</th><th>O que quer dizer</th></tr></thead>
          <tbody>
            <tr><td><code>recebido</code></td><td>Chegou na transportadora e aguarda revisão.</td></tr>
            <tr><td><code>aprovado</code></td><td>Aprovado, aguardando motoboy.</td></tr>
            <tr><td><code>roteirizado</code></td><td>Entrou numa rota montada.</td></tr>
            <tr><td><code>em_rota</code></td><td>O motoboy está a caminho.</td></tr>
            <tr><td><code>concluido</code></td><td>Todas as entregas feitas.</td></tr>
            <tr><td><code>cancelado</code> · <code>recusado</code></td><td>Não vai acontecer.</td></tr>
          </tbody>
        </table>

        <h2>6. Webhook: receba o andamento</h2>
        <p>O gestor cadastra o endereço (https) da sua loja e escolhe os eventos. A cada mudança de status, mandamos:</p>
        <pre>{`POST https://sua-loja.com.br/delibra/webhook
X-Delibra-Evento: pedido.em_rota
X-Delibra-Assinatura: t=1763215200,v1=…

{ "evento": "pedido.em_rota", "enviado_em": "…", "pedido": { "id": "…", "numero": 1042, "status": "em_rota", "referencia_externa": "PEDIDO-1042", … } }`}</pre>
        <p>Responda com qualquer código <code>2xx</code> em até 10 segundos. Sem resposta ou com erro, tentamos de novo a cada minuto, até 5 vezes. Confira a assinatura com o segredo do webhook antes de confiar no conteúdo:</p>
        <pre>{ASSINATURA}</pre>

        <h2>7. Erros</h2>
        <table>
          <thead><tr><th>Código</th><th>Quando</th></tr></thead>
          <tbody>
            <tr><td><code>401</code> chave_invalida</td><td>Chave errada, ausente ou cancelada.</td></tr>
            <tr><td><code>403</code> api_desligada · empresa_sem_acesso</td><td>API desligada para a transportadora ou loja sem conta de cliente.</td></tr>
            <tr><td><code>404</code> pedido_inexistente</td><td>O pedido não é da sua loja ou não existe.</td></tr>
            <tr><td><code>429</code> limite_excedido</td><td>Chamadas demais no mesmo minuto (o limite é da transportadora; o padrão é 120 por minuto). Espere o minuto virar.</td></tr>
            <tr><td><code>422</code> pedido_invalido e outros</td><td>Faltou algo no pedido ou uma regra da transportadora barrou (ex.: só agendado). O campo <code>mensagem</code> explica.</td></tr>
          </tbody>
        </table>
        <p>Toda resposta de erro vem como <code>{`{ "erro": "codigo", "mensagem": "texto em português" }`}</code>.</p>
      </main>
      <RodapeSite />
    </>
  );
}
