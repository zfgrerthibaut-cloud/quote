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
        background: { type: ColorType.Solid, color: '#100918' },
        textColor: '#9e92a6',
        fontFamily: 'var(--font-plex-mono)',
        fontSize: 10,
        attributionLogo: false,
      },
      grid: { vertLines: { color: '#251634' }, horzLines: { color: '#251634' } },
      rightPriceScale: { borderColor: '#62566e' },
      timeScale: { borderColor: '#62566e', timeVisible: false },
      handleScroll: false,
      handleScale: false,
    });
    const series = chart.addSeries(LineSeries, {
      color: '#ff5a32',
      lineWidth: 3,
      crosshairMarkerBackgroundColor: '#c7d63c',
      crosshairMarkerBorderColor: '#100918',
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
