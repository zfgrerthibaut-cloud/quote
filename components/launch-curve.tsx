'use client';

import { ColorType, createChart, LineSeries, type UTCTimestamp } from 'lightweight-charts';
import { useEffect, useRef } from 'react';

const curve = [
  0.000001, 0.00000115, 0.00000136, 0.0000017, 0.0000022, 0.000003, 0.0000044,
  0.0000068, 0.0000108, 0.0000175,
];

export function LaunchCurve() {
  const container = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!container.current) return;
    const chart = createChart(container.current, {
      autoSize: true,
      height: 300,
      layout: {
        background: { type: ColorType.Solid, color: '#f3f0e8' },
        textColor: '#696d67',
        fontFamily: 'var(--font-plex-mono)',
        fontSize: 10,
        attributionLogo: false,
      },
      grid: { vertLines: { color: '#ddd8cc' }, horzLines: { color: '#ddd8cc' } },
      rightPriceScale: { borderColor: '#111a18' },
      timeScale: { borderColor: '#111a18', timeVisible: false },
      handleScroll: false,
      handleScale: false,
    });
    const series = chart.addSeries(LineSeries, {
      color: '#111a18',
      lineWidth: 3,
      crosshairMarkerBackgroundColor: '#f3ba2f',
      crosshairMarkerBorderColor: '#111a18',
      priceFormat: { type: 'price', precision: 8, minMove: 0.00000001 },
    });
    series.setData(
      curve.map((value, index) => ({
        time: (1_700_000_000 + index * 86_400) as UTCTimestamp,
        value,
      })),
    );
    chart.timeScale().fitContent();
    return () => chart.remove();
  }, []);

  return <div className="curve-chart" ref={container} aria-label="Illustrative one-sided Pancake V3 launch curve" />;
}
