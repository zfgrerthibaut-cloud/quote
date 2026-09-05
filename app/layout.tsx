import type { Metadata } from 'next';
import { Archivo, Bodoni_Moda, IBM_Plex_Mono, Instrument_Sans, Noto_Sans_SC } from 'next/font/google';
import './globals.css';
import { SiteFooter } from '@/components/site-footer';
import { SiteHeader } from '@/components/site-header';
import { Providers } from './providers';

const archivo = Archivo({ variable: '--font-archivo', subsets: ['latin'] });
const bodoni = Bodoni_Moda({ variable: '--font-bodoni', subsets: ['latin'], weight: ['500', '600'] });
const plexMono = IBM_Plex_Mono({ variable: '--font-plex-mono', subsets: ['latin'], weight: ['400', '500', '600'] });
const instrument = Instrument_Sans({ variable: '--font-instrument', subsets: ['latin'] });
const notoSansSc = Noto_Sans_SC({ variable: '--font-noto-sc', subsets: ['latin'], weight: ['400', '500', '600'] });

export const metadata: Metadata = {
  metadataBase: new URL('https://forkpare-bsc.momokhitam201.chatgpt.site'),
  title: 'QUOTE',
  description: 'Launch your token. Quote it in any compatible BEP-20 on BNB Chain.',
  openGraph: {
    title: 'QUOTE',
    description: 'Launch your token. Quote it in any compatible BEP-20 on BNB Chain.',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'QUOTE — BNB Chain token launchpad' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'QUOTE',
    description: 'Launch your token. Quote it in any compatible BEP-20 on BNB Chain.',
    images: ['/og.png'],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${archivo.variable} ${bodoni.variable} ${plexMono.variable} ${instrument.variable} ${notoSansSc.variable}`}>
        <Providers><SiteHeader />{children}<SiteFooter /></Providers>
      </body>
    </html>
  );
}
