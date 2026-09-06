import type { Metadata } from 'next';
import { Anybody, IBM_Plex_Mono, Manrope, Noto_Sans_SC } from 'next/font/google';
import './globals.css';
import { SiteFooter } from '@/components/site-footer';
import { SiteHeader } from '@/components/site-header';
import { Providers } from './providers';

const manrope = Manrope({ variable: '--font-manrope', subsets: ['latin'] });
const anybody = Anybody({ variable: '--font-anybody', subsets: ['latin'] });
const plexMono = IBM_Plex_Mono({ variable: '--font-plex-mono', subsets: ['latin'], weight: ['400', '500', '600'] });
const notoSansSc = Noto_Sans_SC({ variable: '--font-noto-sc', subsets: ['latin'], weight: ['400', '500', '600'] });

export const metadata: Metadata = {
  metadataBase: new URL('https://forkpare-bsc.momokhitam201.chatgpt.site'),
  title: 'QUOTE',
  description: 'Create a token against any eligible BEP-20. Direct market or bonding curve on BNB Chain.',
  openGraph: {
    title: 'QUOTE',
    description: 'Any eligible token can be the quote. Direct or bonding-curve markets on BNB Chain.',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'QUOTE — BNB Chain token launchpad' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'QUOTE',
    description: 'Any eligible token can be the quote. Direct or bonding-curve markets on BNB Chain.',
    images: ['/og.png'],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${anybody.variable} ${manrope.variable} ${plexMono.variable} ${notoSansSc.variable}`}>
        <Providers><SiteHeader />{children}<SiteFooter /></Providers>
      </body>
    </html>
  );
}
