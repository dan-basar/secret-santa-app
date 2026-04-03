import type { AppProps } from 'next/app';
import Head from 'next/head';
import '@/styles/globals.css';

export default function App({ Component, pageProps }: AppProps) {
  return (
    <>
      <Head>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer />
      </Head>
      <Component {...pageProps} />
    </>
  );
}
