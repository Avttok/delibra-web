import { redirect } from "next/navigation";

/** "Financeiro" agora se chama Carteira. */
export default function Pagina() {
  redirect("/gestor/carteira");
}
