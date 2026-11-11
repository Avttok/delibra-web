import type { Metadata } from "next";
import { Comecar } from "@/features/site/Comecar";

export const metadata: Metadata = { title: "Delibra · O sistema da sua empresa de entregas", description: "Pedidos, rotas, motoboys com GPS ao vivo e pagamentos, num lugar só. Comece o teste grátis." };

export default function PaginaComecar() {
  return <Comecar />;
}
