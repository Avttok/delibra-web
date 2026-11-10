import { redirect } from "next/navigation";

/** "Empresas" agora se chama Clientes (pessoa física ou jurídica). */
export default function Pagina() {
  redirect("/gestor/clientes");
}
