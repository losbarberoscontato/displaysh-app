import { redirect } from "next/navigation";

export default function AtelieProManagerEntry() {
  redirect("/ateliepro/entrar?modo=login&next=%2Fgestor");
}
