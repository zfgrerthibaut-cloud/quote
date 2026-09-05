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

export function PairWeave({ symbol = 'SPOT', quote = 'WBNB' }: { symbol?: string; quote?: string }) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const context = canvas.getContext('2d');
    if (!context) return;

    let frame = 0;
    let raf = 0;
    let lastDraw = 0;
    const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const tokenSeed = seedFrom(symbol || 'TOKEN');
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
      context.clearRect(0, 0, width, height);
      const motion = reducedMotion ? 0 : time / 19000;
      const lines = width < 700 ? 12 : 18;

      for (let index = 0; index < lines; index += 1) {
        const ratio = (index + 1) / (lines + 1);
        const baseY = ratio * height;
        const tokenPhase = ((tokenSeed >> (index % 16)) & 15) / 15;
        const quotePhase = ((quoteSeed >> ((index + 5) % 16)) & 15) / 15;
        const tokenDrift = Math.sin(motion * Math.PI * 2 + tokenPhase * 5.4 + index * .32) * (7 + tokenPhase * 13);
        const quoteDrift = Math.cos(motion * Math.PI * 2 + quotePhase * 4.8 + index * .27) * (7 + quotePhase * 13);

        context.beginPath();
        context.moveTo(-20, baseY + tokenDrift * .25);
        context.bezierCurveTo(
          width * .2,
          baseY - 30 + tokenDrift,
          width * .38,
          baseY + 36 - tokenDrift,
          width * .5,
          baseY + tokenDrift * .15,
        );
        context.bezierCurveTo(
          width * .64,
          baseY - 30 - tokenDrift,
          width * .82,
          baseY + 18 + tokenDrift,
          width + 20,
          baseY - tokenDrift * .18,
        );
        context.strokeStyle = `rgba(232, 239, 233, ${0.06 + (index % 4) * .018})`;
        context.lineWidth = index % 6 === 0 ? 1.15 : .7;
        context.stroke();

        context.beginPath();
        context.moveTo(width + 20, baseY + quoteDrift * .22);
        context.bezierCurveTo(
          width * .8,
          baseY + 33 - quoteDrift,
          width * .63,
          baseY - 36 + quoteDrift,
          width * .5,
          baseY - quoteDrift * .15,
        );
        context.bezierCurveTo(
          width * .36,
          baseY + 29 + quoteDrift,
          width * .18,
          baseY - 17 - quoteDrift,
          -20,
          baseY + quoteDrift * .2,
        );
        context.strokeStyle = `rgba(89, 217, 168, ${0.075 + (index % 5) * .018})`;
        context.lineWidth = index % 7 === 0 ? 1.2 : .75;
        context.stroke();
      }

      context.beginPath();
      context.moveTo(width * .5, height * .08);
      context.lineTo(width * .5, height * .92);
      context.strokeStyle = 'rgba(119, 141, 255, .16)';
      context.lineWidth = 1;
      context.stroke();
    }

    function animate(time: number) {
      if (time - lastDraw > 1000 / 24) {
        draw(time);
        lastDraw = time;
      }
      frame += 1;
      if (!reducedMotion) raf = requestAnimationFrame(animate);
    }

    const observer = new ResizeObserver(() => {
      resize();
      draw(frame);
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

  return <canvas className="pair-weave" ref={canvasRef} aria-hidden="true" />;
}
