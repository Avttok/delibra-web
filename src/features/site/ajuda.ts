/**
 * Central de ajuda do site do cliente: só o que é do cliente. A ajuda do motoboy e do gestor fica no site do gestor.
 * Cada artigo tem um id estável (/ajuda?p=…&a=… abre direto).
 */
export type Publico = "cliente" | "motoboy" | "gestor";

export interface Artigo {
  id: string;
  titulo: string;
  /** Parágrafos; linhas que começam com "1. ", "2. "… viram passos numerados. */
  texto: string[];
}
export interface Secao { titulo: string; artigos: Artigo[] }

export const PUBLICOS: { k: Publico; nome: string; resumo: string }[] = [
  { k: "cliente", nome: "Clientes", resumo: "Empresas e pessoas que pedem coletas e entregas pelo site." },
  { k: "motoboy", nome: "Motoboys", resumo: "Quem entrega pela Delibra, usando o app no celular." },
  { k: "gestor", nome: "Gestores", resumo: "Quem administra pedidos, rotas, equipe e finanças pelo painel ou pelo app." },
];


export const AJUDA: Partial<Record<Publico, Secao[]>> = {
  cliente: [
    {
      titulo: "Primeiros passos",
      artigos: [
        { id: "criar-conta", titulo: "Criar a conta da empresa", texto: [
          "1. Toque em Criar conta da empresa, no início do site.",
          "2. Escolha empresa (CNPJ) ou pessoa (CPF) e preencha os dados de contato.",
          "3. Se quiser, informe o endereço de coleta padrão e confira o ponto no mapa.",
          "4. Crie a senha e envie.",
          "Dependendo da configuração da Delibra, a conta é liberada na hora ou fica em análise. Enquanto estiver em análise, o site mostra o aviso ao entrar.",
        ] },
        { id: "entrar", titulo: "Entrar e trocar a senha", texto: [
          "Entre com o e-mail e a senha da conta. Marque Permanecer conectado para não precisar entrar de novo neste navegador.",
          "Para trocar a senha, abra Minha conta e use Trocar senha.",
        ] },
      ],
    },
    {
      titulo: "Pedidos",
      artigos: [
        { id: "novo-pedido", titulo: "Fazer um pedido", texto: [
          "1. Abra Novo pedido.",
          "2. Em Quando, escolha Agora ou Agendar (com dia e hora). Ligue Urgente só quando precisar de prioridade.",
          "3. Escolha o tipo de pedido (por exemplo, entrega padrão, documentos ou alimentos).",
          "4. Em Endereços, preencha a coleta e as entregas. Escolha o endereço da lista ou use Marcar no mapa. Contato e referências ajudam o motoboy a achar o lugar.",
          "5. Diga o que vai em cada entrega. Cada tipo de item pede só os campos que importam (peso, medidas, valor declarado).",
          "6. Confira a distância, o tempo e o valor e toque em Fazer pedido.",
          "Use as setas ou arraste pelos pontinhos para mudar a ordem dos endereços. O mapa mostra o caminho entre eles.",
        ] },
        { id: "modelos", titulo: "Modelos de pedido", texto: [
          "Pedido que se repete? Depois de preencher, toque em Salvar como modelo.",
          "Nas próximas vezes, toque no modelo em Meus modelos: tudo é preenchido e você pode mudar o que quiser antes de enviar.",
          "O modelo lembra se o pedido é para agora ou agendado. Se for agendado, guarda a hora e escolhe sozinho o próximo dia possível.",
        ] },
        { id: "objetos", titulo: "Meus objetos", texto: [
          "Manda sempre o mesmo produto? No item do pedido, toque no ícone de salvar e dê um nome (ex.: Caixa de remédios).",
          "O objeto guarda o tipo, a descrição, a quantidade, o peso, as medidas e o valor declarado. Nos próximos pedidos ele aparece em Meus objetos: um toque e o item entra no pedido.",
          "Para apagar um objeto, toque no X ao lado do nome.",
        ] },
        { id: "confirmacoes", titulo: "Confirmações em cada coleta e entrega", texto: [
          "Em cada endereço você escolhe como o motoboy confirma que passou por lá: foto, nome de quem entregou ou recebeu, assinatura na tela ou um código de 4 dígitos.",
          "O código aparece no seu pedido. Passe só para quem vai entregar ou receber naquele endereço.",
          "As opções que aparecem fixas já são pedidas pela Delibra em toda entrega. Se alguma opção não aparece, ela não está liberada na sua conta.",
        ] },
        { id: "horario-ponto", titulo: "Horário de cada endereço", texto: [
          "Se um endereço só atende em certo horário, informe em Atende das … às …. O motoboy e a Delibra veem esse horário na rota.",
        ] },
        { id: "ida-e-volta", titulo: "Ida e volta", texto: [
          "Precisa que o motoboy volte ao início, por exemplo para devolver um canhoto assinado ou uma maquininha? Toque em Ida e volta: uma entrega no primeiro endereço entra no fim do pedido.",
        ] },
        { id: "valor", titulo: "Como o valor é calculado", texto: [
          "O valor segue as regras combinadas com a Delibra: distância, pontos de entrega, volumes, peso, horário e urgência, entre outras.",
          "Em algumas contas o valor aparece depois que a Delibra confere o pedido. Enquanto isso, o pedido mostra Revisando no lugar do valor.",
        ] },
        { id: "acompanhar", titulo: "Acompanhar um pedido", texto: [
          "Em Pedidos, toque no pedido para ver o mapa, os pontos e a situação de cada entrega.",
          "Toque numa coleta ou entrega da lista para o mapa centralizar nela.",
          "Quando a rota está em andamento, o mapa mostra onde o motoboy está (se a sua conta tiver o acompanhamento ao vivo).",
          "Se o pedido usar código de entrega, ele aparece no pedido: passe só para quem vai receber.",
        ] },
        { id: "cancelar", titulo: "Cancelar um pedido", texto: [
          "Enquanto nenhum motoboy pegou a rota, abra o pedido e use Cancelar. Depois disso, fale com a Delibra.",
        ] },
      ],
    },
    {
      titulo: "Pagamento e faturas",
      artigos: [
        { id: "credito-prepago", titulo: "Crédito ou pagamento antecipado", texto: [
          "No crédito, os pedidos concluídos entram na fatura do seu ciclo (por exemplo, semanal ou mensal). Em Faturas você vê cada fatura e os pedidos dela.",
          "No pagamento antecipado, o pedido só sai depois que o pagamento for confirmado. Escolha PIX ou cartão ao fazer o pedido.",
        ] },
      ],
    },
  ],
};
