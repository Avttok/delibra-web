import type { Metadata } from "next";
import { TermosDeUso } from "@/features/site/Legal";
import { RodapeSite, TopoSite } from "@/features/site/Topo";

export const metadata: Metadata = { title: "Termos de uso · Delibra", description: "As regras de uso da Delibra para transportadoras, motoboys, clientes e lojas." };
export default function Pagina() {
  return <><TopoSite /><TermosDeUso /><RodapeSite /></>;
}
