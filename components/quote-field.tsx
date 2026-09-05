'use client';

import { useEffect, useRef } from 'react';

function seedFrom(value: string) {
  let seed = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    seed ^= value.charCodeAt(index);
    seed = Math.imul(seed, 16777619);
  }
  return Math.abs(seed);
}

export function QuoteField({ symbol = 'TOKEN', quote = 'QUOTE' }: { symbol?: string; quote?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext('2d');
    if (!context) return;

    let raf = 0;
    let lastDraw = 0;
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const baseSeed = seedFrom(symbol || 'TOKEN');
    const quoteSeed = seedFrom(quote || 'QUOTE');

    function resize() {
      const bounds = canvas!.getBoundingClientRect();
      const dpr = Math.min(window.devicePixelRatio || 1, 1.5);
      canvas!.width = Math.max(1, Math.floor(bounds.width * dpr));
      canvas!.height = Math.max(1, Math.floor(bounds.height * dpr));
      context!.setTransform(dpr, 0, 0, dpr, 0, 0);
    }

    function draw(time: number) {
      if (!context || !canvas) return;
      const width = canvas.clientWidth;
      const height = canvas.clientHeight;
      const motion = reducedMotion ? 0 : time / 22000;
      const count = width < 700 ? 14 : 22;
      context.clearRect(0, 0, width, height);

      for (let index = 0; index < count; index += 1) {
        const ratio = (index + 1) / (count + 1);
        const basePhase = ((baseSeed >> (index % 16)) & 15) / 15;
        const quotePhase = ((quoteSeed >> ((index + 7) % 16)) & 15) / 15;
        const driftA = Math.sin(motion * Math.PI * 2 + index * .41 + basePhase * 4) * 18;
        const driftB = Math.cos(motion * Math.PI * 2 + index * .34 + quotePhase * 5) * 18;

        context.beginPath();
        context.moveTo(-30, height * ratio + driftA);
        context.bezierCurveTo(width * .27, height * ratio - 70 + driftA, width * .46, height * .5 - 80 + index * 4, width * .53, height * .5 + index * 1.5);
        context.bezierCurveTo(width * .67, height * ratio + 48 - driftA, width * .84, height * ratio - 12, width + 30, height * ratio + driftA * .15);
        context.strokeStyle = `rgba(241, 234, 223, ${.045 + (index % 5) * .013})`;
        context.lineWidth = index % 6 === 0 ? 1.15 : .7;
        context.stroke();

        context.beginPath();
        context.moveTo(width + 30, height * ratio + driftB);
        context.bezierCurveTo(width * .78, height * ratio + 76 - driftB, width * .61, height * .5 + 64 - index * 3, width * .53, height * .5 + index * 1.5);
        context.bezierCurveTo(width * .4, height * ratio - 48 + driftB, width * .18, height * ratio + 12, -30, height * ratio + driftB * .15);
        context.strokeStyle = `rgba(211, 176, 109, ${.055 + (index % 5) * .014})`;
        context.lineWidth = index % 7 === 0 ? 1.2 : .7;
        context.stroke();
      }

      context.save();
      context.translate(width * .535, height * .5);
      context.rotate(.22);
      context.fillStyle = 'rgba(9, 8, 6, .9)';
      context.fillRect(-5, -height * .32, 10, height * .64);
      context.fillStyle = 'rgba(240, 82, 56, .86)';
      context.fillRect(-1, -height * .3, 2, height * .6);
      context.restore();
    }

    function animate(time: number) {
      if (time - lastDraw > 1000 / 24) {
        draw(time);
        lastDraw = time;
      }
      if (!reducedMotion) raf = requestAnimationFrame(animate);
    }

    const observer = new ResizeObserver(() => {
      resize();
      draw(0);
    });
    observer.observe(canvas);
    resize();
    if (reducedMotion) draw(0);
    else raf = requestAnimationFrame(animate);

    return () => {
      observer.disconnect();
      cancelAnimationFrame(raf);
    };
  }, [quote, symbol]);

  return <canvas className="quote-field-canvas" ref={canvasRef} aria-hidden="true" />;
}
