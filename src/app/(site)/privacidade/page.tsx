import type { Metadata } from "next";
import { PoliticaPrivacidade } from "@/features/site/Legal";
import { RodapeSite, TopoSite } from "@/features/site/Topo";

export const metadata: Metadata = { title: "Política de privacidade · Delibra", description: "Quais dados a Delibra usa, para quê e como exercer os seus direitos pela LGPD." };
export default function Pagina() {
  return <><TopoSite /><PoliticaPrivacidade /><RodapeSite /></>;
}
