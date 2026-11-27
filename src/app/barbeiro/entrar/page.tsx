import type { Metadata } from "next";
import Link from "next/link";
import { Brand } from "@/components/brand";
import { BarberAuthForm } from "@/components/connected-barber/auth-form";
import { getBarberLoginOrganization } from "@/lib/barber-server";
import { getSelectedProductKey } from "@/lib/product-context";
import { productIdentityStyle } from "@/lib/product-identity";
import { getPublishedProductIdentity } from "@/lib/product-identity-server";
import { productLoginPath } from "@/lib/product-routes";

export const metadata: Metadata = { title: { absolute: "Acesso ao App da Equipe | Display SH" } };

export default async function BarberLoginPage({ searchParams }: { searchParams: Promise<{ next?: string; barbearia?: string; erro?: string; modo?: string }> }) {
  const params = await searchParams;
  const organization = await getBarberLoginOrganization(params.barbearia);
  const productKey = params.barbearia
    ? organization?.productKey ?? "los-barberos"
    : await getSelectedProductKey();
  const identity = await getPublishedProductIdentity(productKey);
  const brandName = identity?.brand.name ?? "Los Barberos";
  const homeHref = productLoginPath(productKey).replace(/\/entrar$/, "");
  return (
    <main className="system-login-page system-login-page--team" style={productIdentityStyle(identity)}>
      <header className="system-login-page__header">
        <Brand name={brandName} tagline={identity?.brand.tagline} mark={identity?.brand.mark} wordmarkUrl={identity?.brand.logoUrl} href={homeHref} />
      </header>

      <section className="system-login-page__main" aria-label={`Acesso ao ${identity?.vocabulary.teamApp ?? "App do Barbeiro"}`}>
        <div className="system-login-panel">
          <BarberAuthForm next={params.next} slug={params.barbearia} error={params.erro} mode={params.modo === "cadastro" ? "signup" : "signin"} productKey={productKey} identity={identity} organization={organization} />
        </div>
      </section>

      <footer className="system-login-page__footer">
        <span>© {brandName} · Display SH</span>
        <span>
          Ao continuar, você concorda com os <Link href="/termos">Termos de Uso</Link> e a <Link href="/privacidade">Política de Privacidade</Link>.
        </span>
      </footer>
    </main>
  );
}
