import type { Metadata } from "next";
import { ClientMapHome } from "@/components/connected-client/home-map";

export const metadata: Metadata = { title: "Home" };

export default function CustomerMapHomePage() {
  return <ClientMapHome />;
}
