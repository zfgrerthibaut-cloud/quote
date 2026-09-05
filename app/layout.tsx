import type { Metadata } from 'next';
import { Archivo, IBM_Plex_Mono } from 'next/font/google';
import './globals.css';
import { Providers } from './providers';

const archivo = Archivo({ variable: '--font-archivo', subsets: ['latin'] });
const plexMono = IBM_Plex_Mono({ variable: '--font-plex-mono', subsets: ['latin'], weight: ['400', '500', '600'] });

export const metadata: Metadata = {
  metadataBase: new URL('https://forkpare-bsc.momokhitam201.chatgpt.site'),
  title: 'ForkPare — permissionless paired launches on BSC',
  description: 'Launch a fixed-supply token against a compatible BEP-20 quote asset on BNB Smart Chain.',
  openGraph: {
    title: 'ForkPare — permissionless paired launches on BSC',
    description: 'Launch a fixed-supply token against a compatible BEP-20 quote asset on BNB Smart Chain.',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'ForkPare — Permissionless paired launches on BSC' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'ForkPare — permissionless paired launches on BSC',
    description: 'Launch a fixed-supply token against a compatible BEP-20 quote asset on BNB Smart Chain.',
    images: ['/og.png'],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body className={`${archivo.variable} ${plexMono.variable}`}><Providers>{children}</Providers></body></html>;
}
