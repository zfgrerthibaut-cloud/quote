'use client';

import { useEffect, useState } from 'react';

export function LocaleToggle() {
  const [locale, setLocale] = useState<'en' | 'zh'>('en');

  useEffect(() => {
    document.documentElement.dataset.locale = locale;
    document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en';
    window.dispatchEvent(new CustomEvent('spot:locale', { detail: locale }));
  }, [locale]);

  return (
    <button className="locale-toggle" type="button" onClick={() => setLocale(locale === 'en' ? 'zh' : 'en')} aria-label={locale === 'en' ? '切换到中文' : 'Switch to English'}>
      {locale === 'en' ? '中' : 'EN'}
    </button>
  );
}
