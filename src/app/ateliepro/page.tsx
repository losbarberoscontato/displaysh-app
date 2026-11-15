import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import { ArrowRight, CalendarDays, Check, Scissors, UsersRound } from "lucide-react";
import { getPublishedProductIdentity } from "@/lib/product-identity-server";
import { productIdentityStyle } from "@/lib/product-identity";
import styles from "./page.module.css";

export const metadata: Metadata = {
  title: { absolute: "AteliePro — gestão para ateliês de costura" },
  description: "Organize clientes, costureiras, serviços e agenda do seu ateliê em um só lugar.",
  icons: { icon: [{ url: "/ateliepro/mark.png", type: "image/png" }] },
};

export default async function AtelieProPage() {
  const identity = await getPublishedProductIdentity("ateliepro");
  const brandName = identity?.brand.name ?? "AteliePro";

  return (
    <main className={styles.page} style={productIdentityStyle(identity)}>
      <header className={styles.header}>
        <Link href="/ateliepro" className={styles.brand} aria-label={`${brandName} — início`}>
          <Image src={identity?.brand.logoUrl ?? "/ateliepro/mark.png"} alt="" width={52} height={52} priority />
          <span><strong>{brandName}</strong><small>GESTÃO PARA ATELIÊS DE COSTURA</small></span>
        </Link>
        <Link href="/ateliepro/entrar?modo=login" className={styles.login}>Entrar</Link>
      </header>

      <section className={styles.hero}>
        <div className={styles.copy}>
          <span className={styles.eyebrow}>COSTURA · CRIAÇÃO · CUIDADO</span>
          <h1>Seu ateliê.<br /><em>Feito para fluir.</em></h1>
          <p>Cuide da agenda, dos clientes, da equipe e dos serviços de costura em um só lugar. Mais tempo para criar e atender bem.</p>
          <div className={styles.actions}>
            <Link href="/ateliepro/entrar?modo=cadastro" className={styles.cta}>Criar meu ateliê <ArrowRight size={18} /></Link>
            <small>14 dias grátis · depois R$ 57,00 por mês</small>
          </div>
          <div className={styles.serviceNote}><Scissors size={17} /><span>Ajustes, consertos, criações, modelagem, alta costura e alfaiataria.</span></div>
        </div>

        <div className={styles.preview} aria-label="Prévia ilustrativa da agenda do AteliePro">
          <div className={styles.previewHeader}><span className={styles.previewIcon}><CalendarDays size={17} /></span><span><strong>Ateliê Aurora</strong><small>Agenda de atendimentos</small></span><i>HOJE</i></div>
          <div className={styles.previewDate}>Terça-feira <span>30 de setembro</span></div>
          <div className={styles.appointments}>
            <article><time>09:30</time><span><strong>Ajuste de vestido</strong><small>Marina · Costureira: Lúcia</small></span><b>Confirmado</b></article>
            <article><time>11:00</time><span><strong>Prova de alfaiataria</strong><small>Rafael · Costureira: Célia</small></span><b>Confirmado</b></article>
            <article><time>14:00</time><span><strong>Criação sob medida</strong><small>Beatriz · Costureira: Lúcia</small></span><b>Confirmado</b></article>
          </div>
          <div className={styles.previewFooter}><span><Check size={15} /> Rotina organizada</span><span><UsersRound size={15} /> Equipe conectada</span></div>
        </div>
      </section>

      <section className={styles.features} aria-label="Recursos do AteliePro">
        <span>UMA ROTINA MAIS LEVE</span>
        <p>Agenda · Clientes · Serviços · Equipe · Financeiro · WhatsApp</p>
      </section>

      <footer className={styles.footer}><Link href="/">Display SH</Link><span>© 2026 AteliePro · Display SH</span><a href="mailto:contato@displaysh.com">Fale com a gente</a></footer>
    </main>
  );
}
