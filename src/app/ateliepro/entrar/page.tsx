import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowLeft } from "lucide-react";
import { DemoLogin } from "@/components/demo-login";
import { resolveSystemAuthDestination, resolveSystemAuthMode } from "@/lib/system-auth";
import { getPublishedProductIdentity } from "@/lib/product-identity-server";
import { productIdentityStyle } from "@/lib/product-identity";
import styles from "./login.module.css";

export const metadata: Metadata = {
  title: { absolute: "Entrar no AteliePro" },
  icons: { icon: [{ url: "/ateliepro/mark.png", type: "image/png" }] },
};

export default async function AtelieProLoginPage({ searchParams }: PageProps<"/ateliepro/entrar">) {
  const params = await searchParams;
  const identity = await getPublishedProductIdentity("ateliepro");
  const initialMode = resolveSystemAuthMode(params.modo);
  const nextPath = resolveSystemAuthDestination(params.next);

  return (
    <main className="system-login-page" style={productIdentityStyle(identity)}>
      <header className={`system-login-page__header ${styles.header}`}>
        <Link className={styles.logoLink} href="/ateliepro" aria-label="AteliePro — início">
          <Image className={styles.logo} src={identity?.brand.logoUrl ?? "/ateliepro/mark.png"} alt="AteliePro" width={80} height={80} priority />
          <span className={styles.brandName}>AteliePro</span>
        </Link>
        <Link className={`system-login-page__back ${styles.backLink}`} href="/ateliepro"><ArrowLeft size={17} /> Voltar ao AteliePro</Link>
      </header>
      <section className="system-login-page__main" aria-label="Acesso ao AteliePro">
        <div className="system-login-panel"><DemoLogin initialMode={initialMode} nextPath={nextPath} productKey="ateliepro" /></div>
      </section>
      <footer className="system-login-page__footer">
        <span>© AteliePro · Display SH</span>
        <span>Ao continuar, você concorda com os <Link href="/termos">Termos de Uso</Link> e a <Link href="/privacidade">Política de Privacidade</Link>.</span>
      </footer>
    </main>
  );
}
